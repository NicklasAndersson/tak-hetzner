#!/bin/bash
# =============================================================================
# setup-letsencrypt.sh — Let's Encrypt for official TAK Server (Docker)
# =============================================================================
# Obtains a Let's Encrypt certificate and converts it to a Java keystore
# (JKS/PKCS12) that TAK Server can use. The cert files are placed in the
# TAK Server's certs directory, which is volume-mounted into the container.
#
# Prerequisites:
#   - TAK Server Docker containers running
#   - Port 80 open (for certbot standalone)
#   - DNS A record pointing TAK_DOMAIN to this server
# =============================================================================
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# --- Source config ---
source /opt/scripts/config.env

TAK_DIR="/opt/tak"
DOMAIN="${TAK_DOMAIN}"
EMAIL="${CERTBOT_EMAIL}"

# Find the certs/files directory (varies by TAK Server version)
CERT_FILES_DIR=""
for path in "${TAK_DIR}/certs/files" "${TAK_DIR}/tak/certs/files" "${TAK_DIR}/certs"; do
  if [[ -d "$path" ]]; then
    CERT_FILES_DIR="$path"
    break
  fi
done
CERT_FILES_DIR="${CERT_FILES_DIR:-${TAK_DIR}/certs/files}"

info "Setting up Let's Encrypt for ${DOMAIN}"

# ------------------------------------------------------------------
# 1. Verify DNS resolution
# ------------------------------------------------------------------
info "Verifying DNS resolution..."
RESOLVED_IP=$(dig +short "$DOMAIN" @1.1.1.1 | tail -1)
SERVER_IP=$(curl -4 -sf https://ifconfig.me || curl -4 -sf https://api.ipify.org || echo "unknown")

if [[ -z "$RESOLVED_IP" ]]; then
  err "DNS lookup failed for ${DOMAIN} — ensure A record exists"
fi

if [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
  warn "DNS mismatch: ${DOMAIN} resolves to ${RESOLVED_IP}, but server IP is ${SERVER_IP}"
  warn "Proceeding anyway — certbot will fail if the domain doesn't point here"
fi
log "DNS OK: ${DOMAIN} → ${RESOLVED_IP}"

# ------------------------------------------------------------------
# 2. Obtain certificate
# ------------------------------------------------------------------
info "Requesting Let's Encrypt certificate..."

# Stop anything on port 80 temporarily
if lsof -i :80 -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Port 80 is in use — stopping services temporarily"
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
  systemctl stop caddy 2>/dev/null || true
  # Stop TAK containers if they bind port 80
  cd "$TAK_DIR" && docker compose stop 2>/dev/null || true
  sleep 2
fi

certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  --domain "$DOMAIN" \
  --preferred-challenges http

LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
[[ -f "${LE_DIR}/fullchain.pem" ]] || err "Certificate not found after certbot — check logs"
log "Let's Encrypt certificate obtained"

# ------------------------------------------------------------------
# 3. Convert to PKCS12 keystore for TAK Server
# ------------------------------------------------------------------
info "Converting certificate to PKCS12 keystore..."

LE_CERT="${LE_DIR}/fullchain.pem"
LE_KEY="${LE_DIR}/privkey.pem"

# Create PKCS12 keystore from LE cert
KEYSTORE_P12="${CERT_FILES_DIR}/letsencrypt.p12"
openssl pkcs12 -export \
  -in "$LE_CERT" \
  -inkey "$LE_KEY" \
  -out "$KEYSTORE_P12" \
  -name "${DOMAIN}" \
  -password "pass:${TAK_CA_PASS}"

log "PKCS12 keystore created: ${KEYSTORE_P12}"

# Also create JKS if keytool is available
JKS_FILE="${CERT_FILES_DIR}/letsencrypt.jks"
if command -v keytool >/dev/null 2>&1; then
  keytool -importkeystore \
    -srckeystore "$KEYSTORE_P12" \
    -srcstoretype PKCS12 \
    -srcstorepass "${TAK_CA_PASS}" \
    -destkeystore "$JKS_FILE" \
    -deststoretype JKS \
    -deststorepass "${TAK_CA_PASS}" \
    -noprompt
  log "JKS keystore created: ${JKS_FILE}"
fi

# Copy PEM files into TAK certs directory for direct use
cp "$LE_CERT" "${CERT_FILES_DIR}/letsencrypt-fullchain.pem"
cp "$LE_KEY" "${CERT_FILES_DIR}/letsencrypt-privkey.pem"
log "PEM certificates copied to ${CERT_FILES_DIR}/"

# Set permissions so TAK Server container can read them
chown -R 1000:1000 "$CERT_FILES_DIR" 2>/dev/null || true
chmod 644 "${CERT_FILES_DIR}/letsencrypt"* 2>/dev/null || true

# ------------------------------------------------------------------
# 4. Update CoreConfig.xml to use LE keystore
# ------------------------------------------------------------------
info "Updating CoreConfig.xml to use Let's Encrypt certificate..."

CORE_CONFIG=""
for path in "${TAK_DIR}/CoreConfig.xml" "${TAK_DIR}/tak/CoreConfig.xml"; do
  if [[ -f "$path" ]]; then
    CORE_CONFIG="$path"
    break
  fi
done

if [[ -n "$CORE_CONFIG" ]]; then
  # Backup
  cp "$CORE_CONFIG" "${CORE_CONFIG}.bak.$(date +%s)"

  # Update keystore references in CoreConfig.xml
  # The connector for port 8443 typically has keystoreFile and keystorePass
  if grep -q 'keystoreFile' "$CORE_CONFIG"; then
    # Get the relative path within the container (usually /opt/tak/certs/files/)
    CONTAINER_CERT_PATH=$(echo "$KEYSTORE_P12" | sed "s|${TAK_DIR}|/opt/tak|")
    sed -i "s|keystoreFile=\"[^\"]*\"|keystoreFile=\"${CONTAINER_CERT_PATH}\"|g" "$CORE_CONFIG"
    log "Updated keystoreFile in CoreConfig.xml"
  fi

  info "Note: You may need to manually verify CoreConfig.xml connector settings"
  info "Config: ${CORE_CONFIG}"
else
  warn "CoreConfig.xml not found — update keystore path manually"
fi

# Restart TAK Server and Caddy (if present)
info "Restarting TAK Server containers..."
cd "$TAK_DIR"
docker compose restart
systemctl start caddy 2>/dev/null || true
log "TAK Server restarted"

# Wait for it to come back
sleep 10
if curl -ks "https://localhost:8443" >/dev/null 2>&1; then
  log "TAK Server is responding with new certificate"
else
  warn "TAK Server not yet responding — may need more time to start"
fi

# ------------------------------------------------------------------
# 6. Set up auto-renewal
# ------------------------------------------------------------------
info "Configuring certificate auto-renewal..."

RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/tak-server.sh"
cat > "$RENEW_HOOK" << 'HOOK'
#!/bin/bash
# Runs after certbot renews the certificate
# Regenerates PKCS12 keystore and restarts TAK Server containers

source /opt/scripts/config.env
TAK_DIR="/opt/tak"
LE_DIR="/etc/letsencrypt/live/${TAK_DOMAIN}"

# Find cert files directory
CERT_FILES_DIR=""
for path in "${TAK_DIR}/certs/files" "${TAK_DIR}/tak/certs/files" "${TAK_DIR}/certs"; do
  [ -d "$path" ] && CERT_FILES_DIR="$path" && break
done
CERT_FILES_DIR="${CERT_FILES_DIR:-${TAK_DIR}/certs/files}"

# Regenerate PKCS12
openssl pkcs12 -export \
  -in "${LE_DIR}/fullchain.pem" \
  -inkey "${LE_DIR}/privkey.pem" \
  -out "${CERT_FILES_DIR}/letsencrypt.p12" \
  -name "${TAK_DOMAIN}" \
  -password "pass:${TAK_CA_PASS}"

# Regenerate JKS if keytool available
if command -v keytool >/dev/null 2>&1; then
  rm -f "${CERT_FILES_DIR}/letsencrypt.jks"
  keytool -importkeystore \
    -srckeystore "${CERT_FILES_DIR}/letsencrypt.p12" \
    -srcstoretype PKCS12 \
    -srcstorepass "${TAK_CA_PASS}" \
    -destkeystore "${CERT_FILES_DIR}/letsencrypt.jks" \
    -deststoretype JKS \
    -deststorepass "${TAK_CA_PASS}" \
    -noprompt
fi

# Update PEM copies
cp "${LE_DIR}/fullchain.pem" "${CERT_FILES_DIR}/letsencrypt-fullchain.pem"
cp "${LE_DIR}/privkey.pem" "${CERT_FILES_DIR}/letsencrypt-privkey.pem"

# Fix permissions
chown -R 1000:1000 "$CERT_FILES_DIR" 2>/dev/null || true

# Restart TAK Server
cd "$TAK_DIR" && docker compose restart

# Restart Caddy (if running — for CloudTAK)
systemctl restart caddy 2>/dev/null || true
HOOK
chmod +x "$RENEW_HOOK"
log "Auto-renewal hook installed"

# Test renewal (dry-run)
certbot renew --dry-run 2>/dev/null && log "Certbot renewal dry-run passed" || warn "Certbot renewal dry-run failed"

log "Let's Encrypt setup complete for ${DOMAIN}"
