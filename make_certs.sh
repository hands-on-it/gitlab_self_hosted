#!/usr/bin/env bash
set -euo pipefail

# =========================
# Self-signed leaf cert via your Root CA (single-file script)
# Outputs: <KEYNAME>.key, <KEYNAME>.csr, <KEYNAME>.crt
# Requires: rootCA.crt, rootCA.key in current directory
# =========================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need openssl

# ---- Inputs (with sane defaults) ----
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

read -r -p "Days valid (default 500): " DAYS
DAYS="${DAYS:-200}"

read -r -p "Key size bits (default 3072): " KEYBITS
KEYBITS="${KEYBITS:-3072}"

read -r -p "Country (C) (default US): " C
C="${C:-US}"

read -r -p "State/Region (ST) (default DC County): " ST
ST="${ST:-DC County}"

read -r -p "City/Locality (L) (default New-York): " L
L="${L:-New-York}"

read -r -p "Organization (O) (default Internet CI Ltd): " O
O="${O:-Internet CI Ltd}"

read -r -p "Org Unit (OU) (default Sec): " OU
OU="${OU:-Sec}"

read -r -p "Email (optional): " EMAIL
EMAIL="${EMAIL:-}"

echo
echo "Will generate:"
echo "  Prefix:    $KEYNAME"
echo "  CN:        $CN"
echo "  DNS.1:     $DNS1"
echo "  DNS.2:     ${DNS2:-<none>}"
echo "  IP.1:      ${ALTIP:-<none>}"
echo "  Valid days:$DAYS"
echo "  Key bits:  $KEYBITS"
echo "  Subject:   C=$C, ST=$ST, L=$L, O=$O, OU=$OU, CN=$CN, EMAIL=${EMAIL:-<none>}"
read -r -p "Enter to continue: "

# ---- Validate CA files ----
[[ -f rootCA.crt ]] || { echo "Missing rootCA.crt in current directory" >&2; exit 1; }
[[ -f rootCA.key ]] || { echo "Missing rootCA.key in current directory" >&2; exit 1; }

# ---- Generate key ----
openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEYBITS}" -out "${KEYNAME}.key"
echo "OK: generated ${KEYNAME}.key"

# ---- Build an ephemeral openssl config (no disk mutation) ----
TMP_CONF="$(mktemp)"
cleanup() { rm -f "$TMP_CONF"; }
trap cleanup EXIT

# Build alt_names dynamically
ALT_NAMES="DNS.1 = ${DNS1}"
if [[ -n "$DNS2" ]]; then
  ALT_NAMES+=$'\n'"DNS.2 = ${DNS2}"
fi
if [[ -n "$ALTIP" ]]; then
  ALT_NAMES+=$'\n'"IP.1  = ${ALTIP}"
fi

# Email line only if provided (keeps DN clean)
EMAIL_LINE=""
if [[ -n "$EMAIL" ]]; then
  EMAIL_LINE=$'\n'"emailAddress = ${EMAIL}"
fi

cat > "$TMP_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C  = ${C}
ST = ${ST}
L  = ${L}
O  = ${O}
OU = ${OU}
CN = ${CN}${EMAIL_LINE}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
${ALT_NAMES}
EOF

echo
echo "---- Generated OpenSSL config ----"
cat "$TMP_CONF"
echo "----------------------------------"
read -r -p "Enter to continue: "

# ---- Generate CSR ----
openssl req -new -key "${KEYNAME}.key" -out "${KEYNAME}.csr" -config "$TMP_CONF"
echo "OK: generated ${KEYNAME}.csr"

# ---- Sign leaf cert with Root CA ----
# Keep a stable serial file next to root CA (better for CI and repeated runs)
SERIAL_FILE="rootCA.srl"
if [[ ! -f "$SERIAL_FILE" ]]; then
  # Create a random-ish initial serial if none exists
  openssl rand -hex 16 > "$SERIAL_FILE"
fi

openssl x509 -req -days "$DAYS" \
  -in "${KEYNAME}.csr" \
  -CA rootCA.crt -CAkey rootCA.key \
  -CAserial "$SERIAL_FILE" \
  -out "${KEYNAME}.crt" \
  -sha256 \
  -extfile "$TMP_CONF" -extensions v3_req

echo "OK: generated ${KEYNAME}.crt"

# ---- Quick verify ----
echo
echo "---- Verify ----"
openssl x509 -in "${KEYNAME}.crt" -noout -subject -issuer -dates
echo
openssl x509 -in "${KEYNAME}.crt" -noout -text | sed -n '/Subject:/p;/X509v3 Subject Alternative Name:/,/X509v3/p;/X509v3 Extended Key Usage:/p'
echo "----------------"
