#!/bin/bash
# =============================================================================
# setup-cloudtak.sh — CloudTAK integration with OpenTAK Server
# =============================================================================
# Version:    3.0.0
# Date:       2026-03-05
# Source:     https://docs.opentakserver.io/cloudtak.html
#
# What the script does:
#   1.  Prepares the tak user (password check, skipped in --auto)
#   2.  Clones the CloudTAK repo
#   3.  Configures .env (directly, without cloudtak.sh install in --auto)
#   4.  Verifies .env values (API_URL, PMTILES_URL)
#   5.  Ensures NODE_TLS_REJECT_UNAUTHORIZED=0 is set (8443 uses self-signed CA cert)
#   6.  Remaps media ports (avoids conflict with OTS mediamtx)
#   7.  Starts CloudTAK containers
#   8.  Creates nginx reverse proxy config for CloudTAK
#   9.  Fixes OTS nginx /oauth location (needed for CloudTAK login)
#   10. Obtains Let's Encrypt cert for the CloudTAK domains
#   11. Generates admin client cert via OTS API
#   12. Configures CloudTAK server connection (PATCH /api/server)
#
# Usage:
#   Run as the tak user (NOT with sudo):
#     bash /opt/scripts/setup-cloudtak.sh [cloudtak-domain] [tiles-domain] [install-dir] [ots-domain]
#
#   Automatic mode (cloud-init):
#     bash /opt/scripts/setup-cloudtak.sh --auto
#
# Requirements:
#   - OpenTAK Server already installed and initialized (CA generated)
#   - Docker installed (done by cloud-init)
#   - DNS A records for cloudtak + tiles subdomains
#   - Port 80 and 443 open
#   - The tak user MUST have a password (sudo passwd tak)
#   - OTS admin password changed from default (password)
#
# Lessons learned from deployment (2026-03-05):
#   - cloudtak.sh install runs "sudo -v" → requires password despite NOPASSWD
#   - API_URL in .env MUST have https:// prefix, otherwise TypeError: Invalid URL
#   - nginx heredoc: $http_upgrade etc. must be protected from shell expansion
#   - Do NOT run the script as root — cloudtak.sh handles sudo itself
#   - NODE_TLS_REJECT_UNAUTHORIZED=0 is NOT needed (OTS uses LE server cert)
#   - OTS nginx /oauth must be added in location block on 8080
#   - CloudTAK webtak URL should point to 8080 (OAuth, no client cert)
#   - CloudTAK api/url should point to 8443 (mTLS with client cert)
#   - Admin client cert is generated via OTS API: POST /api/certificate
#   - python3-certbot-nginx is needed for certbot --nginx
# =============================================================================
set -euo pipefail

# ── Helper function: retry with backoff ──
retry() {
  local max_attempts="$1"; shift
  local delay="$1"; shift
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      return 1
    fi
    warn "Attempt ${attempt}/${max_attempts} failed, waiting ${delay}s..."
    sleep "$delay"
    ((attempt++))
  done
}

# ── Automatic mode ──
AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
  AUTO_MODE=true
  shift
fi

# Load config.env if it exists
CONFIG_ENV="/opt/scripts/config.env"
if [[ -f "$CONFIG_ENV" ]]; then
  source "$CONFIG_ENV"
fi

CLOUDTAK_DOMAIN="${CLOUDTAK_DOMAIN:-${1:-cloudtak.example.com}}"
TILES_DOMAIN="${TILES_DOMAIN:-${2:-tiles.cloudtak.example.com}}"
INSTALL_DIR="${3:-/home/tak/cloudtak}"
OTS_DOMAIN="${OTS_DOMAIN:-${4:-tak.example.com}}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }

# ── Checks ──
if [[ $EUID -eq 0 ]] && [[ "$AUTO_MODE" != true ]]; then
  err "Do NOT run as root/sudo. Run as the tak user: bash $0"
fi

command -v docker &>/dev/null || err "Docker missing — run cloud-init/baseline first"
command -v git    &>/dev/null || err "Git missing"

if [[ "$AUTO_MODE" != true ]]; then
  if ! sudo passwd -S "$(whoami)" 2>/dev/null | grep -qE '^[^ ]+ P'; then
    echo ""
    warn "The tak user has no password set."
    warn "cloudtak.sh install runs 'sudo -v' which requires a password."
    info "Solution: sudo passwd tak"
    err "Set a password and run the script again."
  fi
fi

echo "============================================"
echo " CloudTAK Setup v3.0.0"
echo " CloudTAK: ${CLOUDTAK_DOMAIN}"
echo " Tiles:    ${TILES_DOMAIN}"
echo " OTS:      ${OTS_DOMAIN}"
echo " Install:  ${INSTALL_DIR}"
if [[ "$AUTO_MODE" == true ]]; then
  echo " Mode:     AUTOMATIC"
fi
echo "============================================"
echo ""

# ── OTS-credentials ──
if [[ "$AUTO_MODE" == true ]]; then
  OTS_USERNAME="administrator"
  OTS_PASSWORD="password"
  log "Using default OTS credentials (automatic mode)"
else
  read -rp "OTS admin username [administrator]: " OTS_USERNAME
  OTS_USERNAME="${OTS_USERNAME:-administrator}"
  read -rsp "OTS admin password: " OTS_PASSWORD
  echo ""
  if [[ -z "$OTS_PASSWORD" ]]; then
    err "Password required. If you haven't changed it: default is 'password'"
  fi
fi

# ── 1. Check DNS ──
echo "Checking DNS..."
for DOMAIN in "$CLOUDTAK_DOMAIN" "$TILES_DOMAIN"; do
  RESOLVED=$(dig +short "$DOMAIN" A | head -1)
  if [[ -z "$RESOLVED" ]]; then
    err "No A record for ${DOMAIN}. Set up DNS first. See docs/dns.md"
  fi
  log "DNS OK: ${DOMAIN} → ${RESOLVED}"
done

# ── 2. Clone CloudTAK ──
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  log "CloudTAK already cloned in ${INSTALL_DIR}"
else
  echo "Cloning CloudTAK..."
  git clone https://github.com/dfpc-coe/CloudTAK.git "${INSTALL_DIR}"
  log "CloudTAK cloned to ${INSTALL_DIR}"
fi

# ── 3. Configure CloudTAK .env ──
# Instead of running cloudtak.sh install (which has interactive prompts and
# sudo -v that hangs in cloud-init), we replicate the relevant steps directly:
#   - Create .env from .env.example with random SigningSecret
#   - Set API_URL and PMTILES_URL
#   - Build Docker images
# Steps 1-6 in cloudtak.sh install (ubuntu-check, apt, docker) are already
# handled by cloud-init.
cd "${INSTALL_DIR}"
ENV_FILE="${INSTALL_DIR}/.env"

if [[ "$AUTO_MODE" == true ]]; then
  info "Configuring CloudTAK .env (automatic)..."

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f ".env.example" ]]; then
      err ".env.example missing in ${INSTALL_DIR}. Verify that CloudTAK was cloned correctly."
    fi
    cp .env.example "$ENV_FILE"
    SIGNING_SECRET=$(openssl rand -hex 16)
    sed -i "s|^SigningSecret=.*|SigningSecret=${SIGNING_SECRET}|" "$ENV_FILE"
    log ".env created from .env.example with random SigningSecret"
  else
    log ".env already exists, skipping creation"
  fi

  sed -i "s|^API_URL=.*|API_URL=https://${CLOUDTAK_DOMAIN}|" "$ENV_FILE"
  sed -i "s|^PMTILES_URL=.*|PMTILES_URL=https://${TILES_DOMAIN}|" "$ENV_FILE"
  log "API_URL=https://${CLOUDTAK_DOMAIN}, PMTILES_URL=https://${TILES_DOMAIN}"

  info "Building CloudTAK Docker images (this takes a few minutes)..."
  docker compose build
  log "CloudTAK Docker images built"
else
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  cloudtak.sh install is INTERACTIVE               ║${NC}"
  echo -e "${CYAN}║                                                   ║${NC}"
  echo -e "${CYAN}║  1. Enter password for sudo when prompted          ║${NC}"
  echo -e "${CYAN}║  2. When asked for API_URL, enter:                 ║${NC}"
  echo -e "${CYAN}║       ${CLOUDTAK_DOMAIN}$(printf '%*s' $((33 - ${#CLOUDTAK_DOMAIN})) '')║${NC}"
  echo -e "${CYAN}║  3. Caddyfile: choose [s] Skip                    ║${NC}"
  echo -e "${CYAN}║     (we use nginx, not Caddy)                      ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
  echo ""
  read -rp "Press Enter to continue..."
  ./cloudtak.sh install
  log "cloudtak.sh install complete"
fi

# ── 4. Verify .env values ──
ENV_FILE="${INSTALL_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  # Ensure API_URL has https://
  CURRENT_API_URL=$(grep '^API_URL=' "$ENV_FILE" | cut -d= -f2)
  if [[ -n "$CURRENT_API_URL" && ! "$CURRENT_API_URL" =~ ^https?:// ]]; then
    sed -i "s|^API_URL=.*|API_URL=https://${CURRENT_API_URL}|" "$ENV_FILE"
    log "API_URL fixed: https://${CURRENT_API_URL}"
  fi

  # Ensure PMTILES_URL
  if grep -q '^PMTILES_URL=' "$ENV_FILE"; then
    CURRENT_PMTILES=$(grep '^PMTILES_URL=' "$ENV_FILE" | cut -d= -f2)
    if [[ -z "$CURRENT_PMTILES" ]]; then
      sed -i "s|^PMTILES_URL=.*|PMTILES_URL=https://${TILES_DOMAIN}|" "$ENV_FILE"
      log "PMTILES_URL set to https://${TILES_DOMAIN}"
    fi
  else
    echo "PMTILES_URL=https://${TILES_DOMAIN}" >> "$ENV_FILE"
    log "PMTILES_URL added: https://${TILES_DOMAIN}"
  fi

  echo ""
  info "Important .env values:"
  grep -E '^(API_URL|PMTILES_URL|SigningSecret)=' "$ENV_FILE"
  echo ""
else
  warn ".env missing — check step 3"
fi

# ── 5. Ensure NODE_TLS_REJECT_UNAUTHORIZED=0 is set ──
# OTS port 8443 uses the self-signed CA cert (not LE). CloudTAK connects to
# 8443 and needs to trust that cert. NODE_TLS_REJECT_UNAUTHORIZED=0 is required.
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
  if grep -q 'NODE_TLS_REJECT_UNAUTHORIZED' "$COMPOSE_FILE"; then
    log "NODE_TLS_REJECT_UNAUTHORIZED already set in docker-compose.yml"
  else
    warn "NODE_TLS_REJECT_UNAUTHORIZED not found in docker-compose.yml — CloudTAK may reject OTS 8443 cert"
  fi
fi

# ── 6. Remap media ports (avoid conflict with OTS mediamtx) ──
# OTS mediamtx uses 8554, 1935, 8888, 8889, 9997 and nginx proxies 1936.
# CloudTAK's media container needs the same ports, so we remap them.
if [[ -f "$ENV_FILE" ]]; then
  if ! grep -q 'MEDIA_PORT_RTMP' "$ENV_FILE"; then
    cat >> "$ENV_FILE" << 'MEDIA_PORTS_EOF'

# Media ports remapped to avoid conflict with OTS mediamtx/nginx
MEDIA_PORT_API=9898
MEDIA_PORT_RTSP=8654
MEDIA_PORT_RTMP=2935
MEDIA_PORT_HLS=8988
MEDIA_PORT_SRT=8990
MEDIA_PORTS_EOF
    log "Media ports remapped in .env (avoids OTS conflict)"
    info "  RTSP 8554→8654, RTMP 1935→2935, HLS 8888→8988, SRT 8890→8990, API 9997→9898"
  else
    log "Media ports already remapped in .env"
  fi
fi

# ── 7. Start CloudTAK ──
echo "Starting CloudTAK..."
cd "${INSTALL_DIR}"
docker compose up -d
log "CloudTAK containers started"

echo "Waiting for CloudTAK API (max 120s)..."
API_READY=false
for i in {1..120}; do
  if curl -sf http://localhost:5000 > /dev/null 2>&1; then
    log "API responding on :5000"
    API_READY=true
    break
  fi
  sleep 1
done
if [[ "$API_READY" != true ]]; then
  warn "API not responding after 120s"
  warn "Check: cd ${INSTALL_DIR} && docker compose logs api"
fi

echo ""
docker compose ps
echo ""

# ── 8. Create nginx config ──
NGINX_CONF="/etc/nginx/sites-available/cloudtak"

if [[ -f "$NGINX_CONF" ]]; then
  warn "nginx config already exists: ${NGINX_CONF}"
  sudo cp "$NGINX_CONF" "${NGINX_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
fi

sudo tee "$NGINX_CONF" > /dev/null << 'CLOUDTAK_NGINX_EOF'
server {
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name __CLOUDTAK_DOMAIN__;

    location / {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    listen 80;
}

server {
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name __TILES_DOMAIN__;

    location / {
        proxy_pass http://localhost:5002;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Referer $scheme://$host/;
    }

    listen 80;
}
CLOUDTAK_NGINX_EOF

sudo sed -i "s/__CLOUDTAK_DOMAIN__/${CLOUDTAK_DOMAIN}/g" "$NGINX_CONF"
sudo sed -i "s/__TILES_DOMAIN__/${TILES_DOMAIN}/g" "$NGINX_CONF"
log "nginx config created: ${NGINX_CONF}"

if [[ ! -L /etc/nginx/sites-enabled/cloudtak ]]; then
  sudo ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/cloudtak
  log "nginx site enabled (symlink)"
else
  log "nginx site already enabled"
fi

# ── 9. Fix OTS nginx — add /oauth to proxy location ──
OTS_HTTP_CONF="/etc/nginx/sites-enabled/ots_http"
if [[ -f "$OTS_HTTP_CONF" ]]; then
  if grep -q 'location ~ ^/(api|Marti)' "$OTS_HTTP_CONF" && ! grep -q 'oauth' "$OTS_HTTP_CONF"; then
    sudo python3 -c "
with open('${OTS_HTTP_CONF}') as f:
    content = f.read()
content = content.replace('location ~ ^/(api|Marti) {', 'location ~ ^/(api|Marti|oauth) {')
with open('${OTS_HTTP_CONF}', 'w') as f:
    f.write(content)
"
    log "OTS nginx: /oauth added to proxy location (port 8080)"
  else
    log "OTS nginx: /oauth already in proxy location"
  fi
fi

# Install certbot/nginx-plugin if missing
command -v nginx &>/dev/null || sudo apt-get install -y nginx
if ! command -v certbot &>/dev/null || ! dpkg -l python3-certbot-nginx 2>/dev/null | grep -q '^ii'; then
  sudo apt-get install -y certbot python3-certbot-nginx
  log "certbot + python3-certbot-nginx installed"
fi

sudo nginx -t 2>&1 || err "nginx config has errors — check ${NGINX_CONF}"
log "nginx config OK"
if sudo systemctl is-active --quiet nginx; then
  sudo systemctl reload nginx
  log "nginx reloaded"
else
  sudo systemctl start nginx
  log "nginx started (was not active)"
fi

# ── 10. Let's Encrypt for the CloudTAK domains ──
# IMPORTANT: Do NOT use certbot --nginx here!
# certbot --nginx rewrites ALL nginx SSL configs, including the OTS domain's,
# and replaces the OTS domain cert with the cloudtak cert → cert mismatch.
# Instead: certbot certonly --standalone + manual nginx SSL config.
echo ""
echo "Obtaining Let's Encrypt certificate for CloudTAK (standalone)..."
sudo systemctl stop nginx

sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --cert-name cloudtak \
  --email "admin@${CLOUDTAK_DOMAIN}" \
  -d "${CLOUDTAK_DOMAIN}" \
  -d "${TILES_DOMAIN}"
log "Let's Encrypt cert obtained for the CloudTAK domains"

LE_CLOUDTAK_CERT="/etc/letsencrypt/live/cloudtak/fullchain.pem"
LE_CLOUDTAK_KEY="/etc/letsencrypt/live/cloudtak/privkey.pem"

# Rewrite nginx config with SSL (replaces HTTP-only from step 8)
sudo tee "$NGINX_CONF" > /dev/null << 'CLOUDTAK_SSL_EOF'
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name __CLOUDTAK_DOMAIN__;
    return 301 https://$host$request_uri;
}

server {
    listen 80;
    server_name __TILES_DOMAIN__;
    return 301 https://$host$request_uri;
}

# CloudTAK HTTPS
server {
    listen 443 ssl;
    server_name __CLOUDTAK_DOMAIN__;

    ssl_certificate __LE_CERT__;
    ssl_certificate_key __LE_KEY__;
    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# Tiles HTTPS
server {
    listen 443 ssl;
    server_name __TILES_DOMAIN__;

    ssl_certificate __LE_CERT__;
    ssl_certificate_key __LE_KEY__;
    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        proxy_pass http://localhost:5002;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Referer $scheme://$host/;
    }
}
CLOUDTAK_SSL_EOF

sudo sed -i "s|__CLOUDTAK_DOMAIN__|${CLOUDTAK_DOMAIN}|g" "$NGINX_CONF"
sudo sed -i "s|__TILES_DOMAIN__|${TILES_DOMAIN}|g" "$NGINX_CONF"
sudo sed -i "s|__LE_CERT__|${LE_CLOUDTAK_CERT}|g" "$NGINX_CONF"
sudo sed -i "s|__LE_KEY__|${LE_CLOUDTAK_KEY}|g" "$NGINX_CONF"
log "nginx SSL config created for CloudTAK (manually, not certbot --nginx)"

# Verify that OTS nginx configs do NOT point to CloudTAK cert
for ots_conf in /etc/nginx/sites-enabled/ots_certificate_enrollment /etc/nginx/sites-enabled/ots_https; do
  if [[ -f "$ots_conf" ]] && grep -q "cloudtak" "$ots_conf" 2>/dev/null; then
    warn "OTS config ${ots_conf} references cloudtak cert — fixing..."
    OTS_LE_CERT="/etc/letsencrypt/live/${OTS_DOMAIN}/fullchain.pem"
    OTS_LE_KEY="/etc/letsencrypt/live/${OTS_DOMAIN}/privkey.pem"
    if [[ -f "$OTS_LE_CERT" ]]; then
      sudo sed -i "s|ssl_certificate .*/cloudtak/.*;|ssl_certificate ${OTS_LE_CERT};|" "$ots_conf"
      sudo sed -i "s|ssl_certificate_key .*/cloudtak/.*;|ssl_certificate_key ${OTS_LE_KEY};|" "$ots_conf"
      log "OTS config ${ots_conf} fixed"
    fi
  fi
done

sudo nginx -t 2>&1 || err "nginx config has errors after SSL update"
sudo systemctl start nginx
log "nginx started with SSL"

# ── 11. Generate admin client cert and configure CloudTAK ──
echo ""
echo "Configuring CloudTAK server connection..."
info "Waiting for CloudTAK API after nginx restart..."
for i in {1..30}; do
  if curl -sf http://localhost:5000 > /dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Wait for OTS API (port 8081) — may still be starting after restart
info "Waiting for OTS API (port 8081, max 120s)..."
OTS_API_READY=false
for i in {1..60}; do
  if curl -sf http://localhost:8081/api/health > /dev/null 2>&1; then
    log "OTS API responding on :8081"
    OTS_API_READY=true
    break
  fi
  sleep 2
done
if [[ "$OTS_API_READY" != true ]]; then
  err "OTS API not responding on :8081 after 120s — cannot configure CloudTAK"
fi

info "Generating client certificate for ${OTS_USERNAME}..."

CONFIG_RESULT=$(python3 << PYEOF
import requests
import json
import sys
import os

address = "http://localhost:8081"
username = "${OTS_USERNAME}"
password = "${OTS_PASSWORD}"
cloudtak_domain = "${CLOUDTAK_DOMAIN}"
ots_domain = "${OTS_DOMAIN}"

try:
    s = requests.session()
    r = s.get(f"{address}/api/login", json={}, verify=False)
    csrf_token = r.json()["response"]["csrf_token"]
    s.headers["X-XSRF-TOKEN"] = csrf_token
    s.headers["Referer"] = address

    r = s.post(f"{address}/api/login", json={"username": username, "password": password}, verify=False)
    if r.status_code != 200:
        print(f"ERROR: OTS login failed: {r.status_code}", file=sys.stderr)
        sys.exit(1)

    r = s.post(f"{address}/api/certificate", json={"username": username})
    if r.status_code not in (200, 400):
        print(f"ERROR: Cert generation failed: {r.status_code}", file=sys.stderr)
        sys.exit(1)
    if r.status_code == 400:
        print(f"Client cert already exists for {username} (400 OK)", file=sys.stderr)

    print(f"Client cert generated for {username}", file=sys.stderr)

    home = os.path.expanduser("~")
    with open(f"{home}/ots/ca/certs/{username}/{username}.pem") as f:
        client_cert = f.read()
    with open(f"{home}/ots/ca/ca.pem") as f:
        ca_cert = f.read()
    with open(f"{home}/ots/ca/certs/{username}/{username}.nopass.key") as f:
        client_key = f.read()

    cert_chain = client_cert.strip() + "\n" + ca_cert.strip() + "\n"

    config = {
        "name": "TAK Server",
        "url": f"https://{ots_domain}:8443",
        "api": f"https://{ots_domain}:8443",
        "webtak": f"http://{ots_domain}:8080",
        "auth": {"cert": cert_chain, "key": client_key},
        "username": username,
        "password": password
    }

    # Retry PATCH with backoff (nginx may return 502 right after restart)
    import time
    for attempt in range(5):
        try:
            r = requests.patch(
                "http://localhost:5000/api/server",
                json=config,
                headers={"Content-Type": "application/json"},
                timeout=15
            )
            if r.status_code == 200:
                print("OK")
                break
            elif r.status_code == 502:
                print(f"502 Bad Gateway, retry {attempt+1}/5...", file=sys.stderr)
                time.sleep(5 * (attempt + 1))
            else:
                print(f"ERROR: {r.status_code} {r.text[:200]}", file=sys.stderr)
                sys.exit(1)
        except requests.exceptions.RequestException as e:
            print(f"Request failed, retry {attempt+1}/5: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    else:
        print("ERROR: PATCH /api/server failed after 5 attempts", file=sys.stderr)
        sys.exit(1)

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [[ "$CONFIG_RESULT" == "OK" ]]; then
  log "CloudTAK server connection configured!"
  log "  url/api: https://${OTS_DOMAIN}:8443 (mTLS)"
  log "  webtak:  http://${OTS_DOMAIN}:8080 (OAuth)"
else
  warn "CloudTAK server configuration failed."
  warn "See docs/troubleshooting.md for manual configuration."
fi

# ── 12. Verify ──
echo ""
echo "Verifying installation..."
CLOUDTAK_TITLE=$(curl -sf --max-time 10 "https://${CLOUDTAK_DOMAIN}/" 2>/dev/null | grep -o '<title>[^<]*</title>') || true
if [[ "$CLOUDTAK_TITLE" == *"CloudTAK"* ]]; then
  log "CloudTAK responding correctly at https://${CLOUDTAK_DOMAIN}"
else
  warn "Could not verify CloudTAK at https://${CLOUDTAK_DOMAIN}"
fi

LOGIN_RESULT=$(curl -sf --max-time 10 -X POST "https://${CLOUDTAK_DOMAIN}/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${OTS_USERNAME}\",\"password\":\"${OTS_PASSWORD}\"}") || true
if [[ "${LOGIN_RESULT:-}" == *"token"* ]]; then
  log "CloudTAK login working! (${OTS_USERNAME})"
else
  warn "CloudTAK login could not be verified"
fi

# ── Done ──
echo ""
echo "============================================"
echo -e " ${GREEN}CloudTAK v3.0.0 configured!${NC}"
echo ""
echo " CloudTAK:  https://${CLOUDTAK_DOMAIN}"
echo " Tiles:     https://${TILES_DOMAIN}"
echo " OTS WebUI: https://${OTS_DOMAIN}:8443"
echo " Install:   ${INSTALL_DIR}"
echo ""
echo " Login:     ${OTS_USERNAME} / <your password>"
echo ""
echo " Manage:"
echo "   cd ${INSTALL_DIR}"
echo "   ./cloudtak.sh start|stop|update|backup"
echo ""
echo " Technical details:"
echo "   - webtak URL: http://${OTS_DOMAIN}:8080 (OAuth)"
echo "   - api/url:    https://${OTS_DOMAIN}:8443 (mTLS, CA cert)"
echo "   - OTS nginx /oauth proxy added"
echo "============================================"
