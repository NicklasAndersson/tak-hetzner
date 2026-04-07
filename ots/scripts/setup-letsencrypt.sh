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
#   4. Updates nginx config for OTS:
#      - ots_certificate_enrollment (port 8446) → LE cert
#      - ots_https port 443 block → LE cert
#      - ots_https port 8443 block → UNCHANGED (self-signed CA cert for mTLS)
#      Port 8443 must keep the self-signed cert because ATAK/iTAK clients
#      verify it against the server's CA. Only native TAK clients connect
#      to 8443, never browsers, so no HSTS conflict.
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

# ── 7. Update ots_https (port 443 only — leave 8443 self-signed for mTLS) ──
# Only the port 443 server block gets the LE cert.
# Port 8443 keeps the self-signed CA cert — ATAK/iTAK clients verify it
# against the server's CA. Browsers never connect to 8443.
python3 << PYEOF
import re

with open("${HTTPS_CONFIG}", "r") as f:
    content = f.read()

# Parse into server blocks and only update the 443 block.
# We find "listen 443" vs "listen 8443" to identify which block we're in.
lines = content.split('\n')
result = []
in_443_block = False
brace_depth = 0

for line in lines:
    stripped = line.strip()

    # Track server blocks by brace depth
    if stripped.startswith('server') and '{' in stripped:
        brace_depth = 1
        in_443_block = False  # reset, will detect on listen line
        result.append(line)
        continue
    elif brace_depth > 0:
        brace_depth += stripped.count('{') - stripped.count('}')
        if brace_depth <= 0:
            in_443_block = False

    # Detect which server block we're in
    if stripped.startswith('listen') and '443' in stripped and '8443' not in stripped:
        in_443_block = True
    elif stripped.startswith('listen') and '8443' in stripped:
        in_443_block = False

    # Only replace certs in the 443 block
    if in_443_block:
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
log "Updated ${HTTPS_CONFIG} (port 443 → LE cert, port 8443 → unchanged self-signed)"

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

# ── 9. Start nginx ──
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

# ── 10. Renewal hooks (standalone requires stopping nginx) ──
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
echo "   - ${CERT_ENROLLMENT} (port 8446 → LE cert)"
echo "   - ${HTTPS_CONFIG} (port 443 → LE cert, port 8443 → unchanged)"
echo ""
echo " Auto-renewal: certbot.timer (every 12 hours)"
echo ""
echo " Port 8443 keeps self-signed CA cert (mTLS for ATAK/iTAK)."
echo " Users enroll via QR code or data package, not the web UI."
echo "============================================"
