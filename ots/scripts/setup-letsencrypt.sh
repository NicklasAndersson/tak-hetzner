#!/bin/bash
# =============================================================================
# setup-letsencrypt.sh — Let's Encrypt for OpenTAK Server
# =============================================================================
# Source: https://docs.opentakserver.io/lets_encrypt.html
#
# What the script does:
#   1. Installs certbot (if missing)
#   2. Temporarily stops nginx
#   3. Obtains Let's Encrypt certificate via standalone challenge
#   4. Updates nginx config for OTS (certificate enrollment + HTTPS 443 + 8443)
#      NOTE: Only ssl_certificate/ssl_certificate_key are replaced.
#      ssl_client_certificate and ssl_verify_client are kept (mTLS).
#      This resolves the HSTS conflict — Firefox blocks self-signed cert
#      on other ports if HSTS is active on port 443.
#   5. Starts nginx again
#   6. Sets up automatic renewal via systemd timer
#
# Usage:
#   sudo bash setup-letsencrypt.sh
#
# Requirements:
#   - OpenTAK Server already installed
#   - DNS A record pointing to the server's IP
#   - Port 80 open in the firewall
# =============================================================================
set -euo pipefail

# Load config.env if it exists
CONFIG_ENV="/opt/scripts/config.env"
if [[ -f "$CONFIG_ENV" ]]; then
  source "$CONFIG_ENV"
fi

DOMAIN="${1:-${OTS_DOMAIN:-tak.example.com}}"
OTS_USER="${2:-tak}"
OTS_HOME="/home/${OTS_USER}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }

# ── Checks ──
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

echo "============================================"
echo " Let's Encrypt setup for OpenTAK Server"
echo " Domain: ${DOMAIN}"
echo "============================================"
echo ""

# Check that OTS nginx config exists
CERT_ENROLLMENT="/etc/nginx/sites-enabled/ots_certificate_enrollment"
HTTPS_CONFIG="/etc/nginx/sites-enabled/ots_https"

[[ ! -f "$CERT_ENROLLMENT" ]] && err "Could not find ${CERT_ENROLLMENT} — is OTS installed?"
[[ ! -f "$HTTPS_CONFIG" ]] && err "Could not find ${HTTPS_CONFIG} — is OTS installed?"

# Check DNS
echo "Checking DNS for ${DOMAIN}..."
RESOLVED_IP=$(dig +short "${DOMAIN}" A | head -1)
if [[ -z "$RESOLVED_IP" ]]; then
  err "No A record found for ${DOMAIN}. Set up DNS first."
fi
log "DNS OK: ${DOMAIN} → ${RESOLVED_IP}"

# ── 1. Install certbot ──
if ! command -v certbot &> /dev/null; then
  warn "certbot missing, installing..."
  apt-get update -qq
  apt-get install -y certbot
  log "certbot installed"
else
  log "certbot already installed"
fi

# ── 2. Stop nginx ──
warn "Temporarily stopping nginx..."
systemctl stop nginx
log "nginx stopped"

# ── 3. Obtain certificate ──
echo ""
echo "Obtaining Let's Encrypt certificate..."
certbot certonly \
  --standalone \
  --preferred-challenges http \
  --non-interactive \
  --agree-tos \
  --email "admin@${DOMAIN}" \
  -d "${DOMAIN}"

LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

[[ ! -f "$LE_CERT" ]] && err "Certificate was not created: ${LE_CERT}"
log "Certificate obtained: ${LE_CERT}"

# ── 4. Find current cert lines in nginx ──
# Find OTS cert paths (varies depending on username)
OTS_CERT=$(grep -m1 'ssl_certificate ' "$CERT_ENROLLMENT" | sed 's/.*ssl_certificate //' | sed 's/;//' | xargs)
OTS_KEY=$(grep -m1 'ssl_certificate_key ' "$CERT_ENROLLMENT" | sed 's/.*ssl_certificate_key //' | sed 's/;//' | xargs)

if [[ -z "$OTS_CERT" || -z "$OTS_KEY" ]]; then
  err "Could not find ssl_certificate in ${CERT_ENROLLMENT}"
fi

log "Current OTS cert: ${OTS_CERT}"
log "Current OTS key:  ${OTS_KEY}"

# ── 5. Backup nginx config ──
BACKUP_DIR="/etc/nginx/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$CERT_ENROLLMENT" "$BACKUP_DIR/"
cp "$HTTPS_CONFIG" "$BACKUP_DIR/"
log "Backup saved in ${BACKUP_DIR}"

# ── 5b. Update server_name in OTS nginx configs ──
# The OTS installer sets server_name to internal names (opentakserver_443 etc.)
# that don't match the actual domain name. This works in isolation, but
# when CloudTAK is added with its own 443 blocks and correct server_name,
# nginx routes TAK requests to the CloudTAK block → wrong cert is served.
for conf_name_pair in "opentakserver_443:${DOMAIN}" "opentakserver_8443:${DOMAIN}" "opentakserver_8446:${DOMAIN}"; do
  old_name="${conf_name_pair%%:*}"
  new_name="${conf_name_pair##*:}"
  for conf in "$CERT_ENROLLMENT" "$HTTPS_CONFIG"; do
    if grep -q "server_name ${old_name};" "$conf" 2>/dev/null; then
      sed -i "s/server_name ${old_name};/server_name ${new_name};/" "$conf"
      log "server_name ${old_name} → ${new_name} in $(basename ${conf})"
    fi
  done
done

# ── 6. Update ots_certificate_enrollment ──
sed -i "s|ssl_certificate .*${OTS_CERT}.*|ssl_certificate ${LE_CERT};|" "$CERT_ENROLLMENT"
sed -i "s|ssl_certificate_key .*${OTS_KEY}.*|ssl_certificate_key ${LE_KEY};|" "$CERT_ENROLLMENT"
log "Updated ${CERT_ENROLLMENT}"

# ── 7. Update ots_https (ALL server blocks: 443 + 8443) ──
# Replace ssl_certificate/ssl_certificate_key with Let's Encrypt in all blocks.
# ssl_client_certificate and ssl_verify_client are left UNCHANGED (mTLS).
# This resolves the HSTS conflict: Firefox applies HSTS to all ports
# for the same domain, so self-signed cert on 8443 is blocked if 443 has HSTS.
python3 << PYEOF
import re

with open("${HTTPS_CONFIG}", "r") as f:
    content = f.read()

# Replace ssl_certificate and ssl_certificate_key in ALL server blocks.
# Matches lines with OTS self-signed cert paths.
# NOT ssl_client_certificate (it should be kept for mTLS).
lines = content.split('\n')
result = []

for line in lines:
    stripped = line.strip()
    # Replace server cert (ssl_certificate, not ssl_client_certificate)
    if stripped.startswith('ssl_certificate ') and '${OTS_CERT}' in line:
        indent = line[:len(line) - len(line.lstrip())]
        line = f'{indent}ssl_certificate ${LE_CERT};'
    elif stripped.startswith('ssl_certificate_key') and '${OTS_KEY}' in line:
        indent = line[:len(line) - len(line.lstrip())]
        line = f'{indent}ssl_certificate_key ${LE_KEY};'
    result.append(line)

with open("${HTTPS_CONFIG}", "w") as f:
    f.write('\n'.join(result))
PYEOF
log "Updated ${HTTPS_CONFIG} (port 443 + 8443 — LE server cert, mTLS preserved)"

# ── 8. Test nginx config ──
echo ""
if ! nginx -t 2>&1; then
  echo -e "${RED}[✘]${NC} nginx config has errors! Restoring from backup..."
  cp "$BACKUP_DIR/ots_certificate_enrollment" "$CERT_ENROLLMENT"
  cp "$BACKUP_DIR/ots_https" "$HTTPS_CONFIG"
  systemctl start nginx
  err "Restored to backup. Check manually."
fi
log "nginx config OK"

# ── 9. Re-add HSTS now that we have valid LE certs ──
# HSTS was removed in setup-all.sh to avoid Firefox caching
# HSTS with self-signed cert. Now that LE certs are in place it's safe.
python3 << HSTS_PYEOF
import re

for config_path in ["${CERT_ENROLLMENT}", "${HTTPS_CONFIG}"]:
    with open(config_path, "r") as f:
        content = f.read()
    # Check if HSTS already exists
    if "Strict-Transport-Security" in content:
        continue
    # Add HSTS after the ssl_certificate_key line in each server block
    lines = content.split("\n")
    result = []
    for line in lines:
        result.append(line)
        if line.strip().startswith("ssl_certificate_key") and line.strip().endswith(";"):
            indent = line[:len(line) - len(line.lstrip())]
            result.append(f'{indent}add_header Strict-Transport-Security "max-age=63072000" always;')
    with open(config_path, "w") as f:
        f.write("\n".join(result))
HSTS_PYEOF
log "HSTS headers restored (valid LE certs)"

# ── 10. Start nginx ──
systemctl start nginx
log "nginx started"

# ── 10. Check certbot timer ──
if systemctl is-active --quiet certbot.timer; then
  log "certbot auto-renewal timer already active"
else
  systemctl enable certbot.timer
  systemctl start certbot.timer
  log "certbot auto-renewal timer enabled"
fi

# ── 11. Renewal hooks (standalone requires stopping nginx) ──
HOOK_PRE="/etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh"
HOOK_POST="/etc/letsencrypt/renewal-hooks/post/start-nginx.sh"
mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post}

if [[ ! -f "$HOOK_PRE" ]]; then
  cat > "$HOOK_PRE" << 'HOOK_EOF'
#!/bin/bash
systemctl stop nginx
HOOK_EOF
  chmod +x "$HOOK_PRE"
  log "Renewal pre-hook created (stops nginx)"
fi

if [[ ! -f "$HOOK_POST" ]]; then
  cat > "$HOOK_POST" << 'HOOK_EOF'
#!/bin/bash
systemctl start nginx
HOOK_EOF
  chmod +x "$HOOK_POST"
  log "Renewal post-hook created (starts nginx)"
fi

# ── Done ──
echo ""
echo "============================================"
echo -e " ${GREEN}Let's Encrypt configured!${NC}"
echo ""
echo " Domain:    ${DOMAIN}"
echo " Cert:      ${LE_CERT}"
echo " Key:       ${LE_KEY}"
echo " Backup:    ${BACKUP_DIR}"
echo ""
echo " Changed files:"
echo "   - ${CERT_ENROLLMENT}"
echo "   - ${HTTPS_CONFIG} (port 443 + 8443)"
echo ""
echo " Auto-renewal: certbot.timer (every 12 hours)"
echo ""
echo " HSTS-fix:"
echo "   Port 8443 now uses LE server cert (resolves HSTS blocking)"
echo "   mTLS (ssl_client_certificate + ssl_verify_client) preserved"
echo "============================================"
