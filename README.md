# Gitlab self hosted server installation steps
##

- Gitlab server
- Gitlab conteiner registry
-  Certificates

## How-to

1. Generate rootCA
```bash
   chmod +x gen_cah.sh
   ./gen_ca.sh
```
2. Generate server certificates
```bash
   chmod +x make_certs.sh
   ./make_certs.sh
```

3. Create direcotry for server files
```bash
   mkdir -p /opt/gitlab
   mkdir -p /opt/gitlab/gitlab_certs
```

4. Copy certificates to build directory
```bash
   cp rootCA.crt /opt/gitlab/gitlab_certs
   copy your_server.crt  your_server.key  /opt/gitlab/gitlab_certs
```
5. Generate JWT key file
```bash
   cd /opt/gitlab
   openssl genpkey -algorithm RSA -out ./gitlab_certs/ci_jwt.key -pkeyopt rsa_keygen_bits:4096
```
6. Place Dockerfile and docker-compose.yml into /opt/gitlab/

e.g.
```bash
   vim Dockerfile
   vim docker-compose.yml
```

8. Run
```bash
   docker compose -f docker-compose.yml up -d
```
8. Wait until Deployment finished
```bash
   docker compose -f docker-compose.yml logs -f gitlab
```


