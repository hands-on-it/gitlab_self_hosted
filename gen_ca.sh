#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Root CA + Leaf (server/client) cert script
# Single file, no external openssl.cnf needed
#
# Outputs:
#   Root CA: rootCA.key rootCA.crt rootCA.srl (serial)
#   Leaf:    <KEYNAME>.key <KEYNAME>.csr <KEYNAME>.crt
# Optional:
#   <KEYNAME>.p12 (PKCS#12 bundle) if you choose to generate it
# ==========================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need openssl

umask 077

pause() { read -r -p "${1:-Enter to continue: }"; }

mkconf() {
  # Args:
  #  1) path
  #  2) C
  #  3) ST
  #  4) L
  #  5) O
  #  6) OU
  #  7) CN
  #  8) EMAIL (optional)
  #  9) ALT_NAMES block (optional; for leaf)
  # 10) MODE "ca" or "leaf"
  local path="$1" C="$2" ST="$3" L="$4" O="$5" OU="$6" CN="$7" EMAIL="$8" ALT_NAMES="${9:-}" MODE="${10:-leaf}"

  local EMAIL_LINE=""
  [[ -n "$EMAIL" ]] && EMAIL_LINE=$'\n'"emailAddress = ${EMAIL}"

  if [[ "$MODE" == "ca" ]]; then
    cat > "$path" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
C  = ${C}
ST = ${ST}
L  = ${L}
O  = ${O}
OU = ${OU}
CN = ${CN}${EMAIL_LINE}

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
  else
    cat > "$path" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
C  = ${C}
ST = ${ST}
L  = ${L}
O  = ${O}
OU = ${OU}
CN = ${CN}${EMAIL_LINE}

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
${ALT_NAMES}
EOF
  fi
}

gen_root_ca() {
  echo "=== Root CA generation ==="
  read -r -p "Root CA key file (default rootCA.key): " CA_KEY
  CA_KEY="${CA_KEY:-rootCA.key}"

  read -r -p "Root CA cert file (default rootCA.crt): " CA_CRT
  CA_CRT="${CA_CRT:-rootCA.crt}"

  read -r -p "Root CA serial file (default rootCA.srl): " CA_SRL
  CA_SRL="${CA_SRL:-rootCA.srl}"

  read -r -p "Root CA CN (default My Root CA): " CA_CN
  CA_CN="${CA_CN:-My Root CA}"

  read -r -p "Root CA validity days (default 3650): " CA_DAYS
  CA_DAYS="${CA_DAYS:-3650}"

  read -r -p "Root CA RSA key bits (default 4096): " CA_BITS
  CA_BITS="${CA_BITS:-4096}"

  read -r -p "Country (C) (default US): " C
  C="${C:-US}"
  read -r -p "State/Region (ST) (default Washington D.C.): " ST
  ST="${ST:-Washington D.C.}"
  read -r -p "City/Locality (L) (default Washington): " L
  L="${L:-Washington}"
  read -r -p "Organization (O) (default Internet CI Ltd): " O
  O="${O:-Internet CI Ltd}"
  read -r -p "Org Unit (OU) (default Sec): " OU
  OU="${OU:-Sec}"
  read -r -p "Email (optional): " EMAIL
  EMAIL="${EMAIL:-}"

  echo
  echo "Will generate Root CA:"
  echo "  Key:   $CA_KEY"
  echo "  Cert:  $CA_CRT"
  echo "  Serial:$CA_SRL"
  echo "  CN:    $CA_CN"
  echo "  Days:  $CA_DAYS"
  echo "  Bits:  $CA_BITS"
  pause
  read -r  -p "Enter pass phrase for rootCA: " CA_PASSPHRASE
  CA_PASSPHRASE="${CA_PASSPHRASE:-test}"

  # Key
  openssl genpkey -aes256  -pass pass:"$CA_PASSPHRASE" -algorithm RSA -pkeyopt "rsa_keygen_bits:${CA_BITS}" -out "$CA_KEY"
  echo "OK: generated $CA_KEY"

  # Config
  local CA_CONF
  CA_CONF="$(mktemp)"
  trap 'rm -f "${CA_CONF:-}"' EXIT

  mkconf "$CA_CONF" "$C" "$ST" "$L" "$O" "$OU" "$CA_CN" "$EMAIL" "" "ca"

  echo
  echo "---- Root CA OpenSSL config ----"
  cat "$CA_CONF"
  echo "--------------------------------"
  pause

  # Self-signed CA cert
  openssl req -new -x509 -days "$CA_DAYS" -sha256 \
    -key "$CA_KEY" \
    -out "$CA_CRT" \
    -config "$CA_CONF"

  echo "OK: generated $CA_CRT"

  # Ensure serial exists (used later for signing leafs)
  if [[ ! -f "$CA_SRL" ]]; then
    openssl rand -hex 16 > "$CA_SRL"
    echo "OK: created serial $CA_SRL"
  fi

  echo
  echo "---- Root CA verify ----"
  openssl x509 -in "$CA_CRT" -noout -subject -issuer -dates
  openssl x509 -in "$CA_CRT" -noout -text | sed -n '/X509v3 Basic Constraints:/,/X509v3/p'
  echo "------------------------"
}

gen_leaf() {
  echo "=== Leaf certificate generation (signed by Root CA) ==="

  read -r -p "Root CA key (default rootCA.key): " CA_KEY
  CA_KEY="${CA_KEY:-rootCA.key}"
  read -r -p "Root CA cert (default rootCA.crt): " CA_CRT
  CA_CRT="${CA_CRT:-rootCA.crt}"
  read -r -p "Root CA serial (default rootCA.srl): " CA_SRL
  CA_SRL="${CA_SRL:-rootCA.srl}"

  [[ -f "$CA_KEY" ]] || { echo "Missing CA key: $CA_KEY" >&2; exit 1; }
  [[ -f "$CA_CRT" ]] || { echo "Missing CA cert: $CA_CRT" >&2; exit 1; }
  [[ -f "$CA_SRL" ]] || { echo "Missing CA serial: $CA_SRL (create it with Root CA generation)" >&2; exit 1; }

  read -r -p "Key name (output prefix, e.g. mqtt): " KEYNAME
  : "${KEYNAME:?Key name must not be empty}"

  read -r -p "Common Name (CN, e.g. mqtt.internal): " CN
  : "${CN:?CN must not be empty}"

  read -r -p "DNS.1 (optional, Enter = CN): " DNS1
  DNS1="${DNS1:-$CN}"

  read -r -p "DNS.2 (optional, Enter = empty): " DNS2
  DNS2="${DNS2:-}"

  read -r -p "ALT IP (optional, e.g. 192.168.1.69): " ALTIP
  ALTIP="${ALTIP:-}"

  read -r -p "Leaf validity days (default 200): " DAYS
  DAYS="${DAYS:-200}"

  read -r -p "Leaf RSA key bits (default 3072): " KEYBITS
  KEYBITS="${KEYBITS:-3072}"

  read -r -p "Country (C) (default US): " C
  C="${C:-US}"
  read -r -p "State/Region (ST) (default Washington D.C.): " ST
  ST="${ST:-Washington D.C.}"
  read -r -p "City/Locality (L) (default Washingtono): " L
  L="${L:-Washingtono}"
  read -r -p "Organization (O) (default Internet CI Ltd): " O
  O="${O:-Internet CI Ltd}"
  read -r -p "Org Unit (OU) (default Sec): " OU
  OU="${OU:-Sec}"
  read -r -p "Email (optional): " EMAIL
  EMAIL="${EMAIL:-}"

  # Build alt_names dynamically
  ALT_NAMES="DNS.1 = ${DNS1}"
  [[ -n "$DNS2" ]] && ALT_NAMES+=$'\n'"DNS.2 = ${DNS2}"
  [[ -n "$ALTIP" ]] && ALT_NAMES+=$'\n'"IP.1  = ${ALTIP}"

  echo
  echo "Will generate Leaf:"
  echo "  Prefix: $KEYNAME"
  echo "  CN:     $CN"
  echo "  DNS.1:  $DNS1"
  echo "  DNS.2:  ${DNS2:-<none>}"
  echo "  IP.1:   ${ALTIP:-<none>}"
  echo "  Days:   $DAYS"
  echo "  Bits:   $KEYBITS"
  echo "  CA:     $CA_CRT"
  pause

  read -r  -p "Enter pass phrase for rootCA: " CA_PASSPHRASE
  CA_PASSPHRASE="${CA_PASSPHRASE:-test}"
  # Key
  openssl genpkey -aes256  -pass pass:"$CA_PASSPHRASE" -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEYBITS}" -out "${KEYNAME}.key"
  echo "OK: generated ${KEYNAME}.key"

  # Config
  local LEAF_CONF
  LEAF_CONF="$(mktemp)"
  trap 'rm -f "$LEAF_CONF"' RETURN

  mkconf "$LEAF_CONF" "$C" "$ST" "$L" "$O" "$OU" "$CN" "$EMAIL" "$ALT_NAMES" "leaf"

  echo
  echo "---- Leaf OpenSSL config ----"
  cat "$LEAF_CONF"
  echo "-----------------------------"
  pause

  # CSR
  openssl req -new -key "${KEYNAME}.key" -out "${KEYNAME}.csr" -config "$LEAF_CONF"
  echo "OK: generated ${KEYNAME}.csr"

  # Sign
  openssl x509 -req -days "$DAYS" -sha256 \
    -in "${KEYNAME}.csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAserial "$CA_SRL" \
    -out "${KEYNAME}.crt" \
    -extfile "$LEAF_CONF" -extensions v3_req

  echo "OK: generated ${KEYNAME}.crt"

  # Optional: PKCS#12 bundle (useful for some clients)
  read -r -p "Generate PKCS#12 bundle (${KEYNAME}.p12)? [y/N]: " GENP12

  GENP12="${GENP12:-N}"
  if [[ "$GENP12" =~ ^[Yy]$ ]]; then
    read -r -s -p "P12 password (empty = none): " P12PASS
    echo
    if [[ -n "${P12PASS:-}" ]]; then
      openssl pkcs12 -export -out "${KEYNAME}.p12" \
        -inkey "${KEYNAME}.key" -in "${KEYNAME}.crt" -certfile "$CA_CRT" \
        -passout "pass:${P12PASS}"
    else
      openssl pkcs12 -export -out "${KEYNAME}.p12" \
        -inkey "${KEYNAME}.key" -in "${KEYNAME}.crt" -certfile "$CA_CRT" \
        -passout pass:
    fi
    echo "OK: generated ${KEYNAME}.p12"
  fi

  echo
  echo "---- Leaf verify ----"
  openssl x509 -in "${KEYNAME}.crt" -noout -subject -issuer -dates
  echo
  echo "SAN / EKU:"
  openssl x509 -in "${KEYNAME}.crt" -noout -text | sed -n '/X509v3 Subject Alternative Name:/,/X509v3/p;/X509v3 Extended Key Usage:/p'
  echo
  echo "Chain verify:"
  openssl verify -CAfile "$CA_CRT" "${KEYNAME}.crt"
  echo "---------------------"
}

main() {
  echo "Choose action:"
  echo "  1) Generate Root CA (rootCA.key/rootCA.crt/rootCA.srl)"
  echo "  2) Generate Leaf cert signed by Root CA"
  echo "  3) Both (Root CA then Leaf)"
  read -r -p "Enter 1/2/3: " CHOICE

  case "${CHOICE:-}" in
    1) gen_root_ca ;;
    2) gen_leaf ;;
    3) gen_root_ca; gen_leaf ;;
    *) echo "Invalid choice" >&2; exit 1 ;;
  esac
}

main
