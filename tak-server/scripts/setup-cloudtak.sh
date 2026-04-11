#!/bin/bash
# =============================================================================
# setup-cloudtak.sh — CloudTAK integration with official TAK Server (GoC)
# =============================================================================
# Version:    1.0.0
# Date:       2026-03-07
# Source:     https://github.com/dfpc-coe/CloudTAK
#
# What the script does:
#   1.  Checks DNS for CLOUDTAK_DOMAIN and TILES_DOMAIN
#   2.  Clones the CloudTAK repo
#   3.  Configures .env (SigningSecret, API_URL, PMTILES_URL)
#   4.  Removes NODE_TLS_REJECT_UNAUTHORIZED (not needed with LE cert)
#   5.  Remaps conflicting ports (MinIO 9000 → 9100, conflicts with TAK Federation)
#   6.  Builds and starts CloudTAK containers
#   7.  Configures Caddy reverse proxy (auto-HTTPS)
#   8.  Generates CloudTAK client cert via TAK Server's makeCert.sh
#   9.  Configures CloudTAK → TAK Server connection (PATCH /api/server)
#   10. Verifies the installation
#
# Usage:
#   sudo bash /opt/scripts/setup-cloudtak.sh
#
# Prerequisites:
#   - TAK Server Docker containers running
#   - Docker installed (done by cloud-init)
#   - Caddy installed (done by cloud-init)
#   - DNS A records for CLOUDTAK_DOMAIN and TILES_DOMAIN
#   - Port 80 and 443 open
#
# Notes:
#   - Official TAK Server port 8443 = mTLS (client cert required)
#   - Port 8446 = clientAuth=false (used for OAuth/password login)
#   - CloudTAK API connects via mTLS on 8443, OAuth login via 8446
#   - NODE_EXTRA_CA_CERTS is set so Node.js trusts the TAK Server's self-signed CA
#   - extra_hosts maps "takserver" → Docker host gateway (cert SAN = DNS:takserver)
#   - GoC TAK Server lacks <certificateSigning> in CoreConfig.xml, so CloudTAK
#     cannot auto-enroll client certs. Each user needs a pre-generated cert + profile.
#   - Users authenticate to CloudTAK with TAK Server username + password
#   - MinIO port 9000 conflicts with TAK Server Federation v1 → remapped to 9100
#   - Caddy handles HTTPS automatically (ACME + auto-renewal)
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

# --- Source config ---
source /opt/scripts/config.env

INSTALL_DIR="/home/tak/cloudtak"
TAK_DIR="/opt/tak"

echo "============================================"
echo " CloudTAK Setup v1.0.0"
echo " CloudTAK: ${CLOUDTAK_DOMAIN}"
echo " Tiles:    ${TILES_DOMAIN}"
echo " TAK:      ${TAK_DOMAIN}"
echo " Install:  ${INSTALL_DIR}"
echo "============================================"
echo ""

# ── Checks ──
command -v docker &>/dev/null || err "Docker missing — run cloud-init first"
command -v git    &>/dev/null || err "Git missing"
command -v caddy  &>/dev/null || err "Caddy missing — should be installed by cloud-init"

# Verify TAK Server is running
if ! docker ps --format '{{.Names}}' | grep -q 'takserver'; then
  err "TAK Server container 'takserver' is not running. Install TAK Server first."
fi

# ── 1. Check DNS ──
info "Checking DNS resolution..."
SERVER_IP=$(curl -4 -sf https://ifconfig.me || curl -4 -sf https://api.ipify.org || echo "unknown")

for DOMAIN in "$CLOUDTAK_DOMAIN" "$TILES_DOMAIN"; do
  RESOLVED=$(dig +short "$DOMAIN" @1.1.1.1 | tail -1)
  if [[ -z "$RESOLVED" ]]; then
    warn "No A record for ${DOMAIN}. Caddy will retry ACME later."
  elif [[ "$RESOLVED" != "$SERVER_IP" ]]; then
    warn "DNS mismatch: ${DOMAIN} → ${RESOLVED}, server IP is ${SERVER_IP}"
  else
    log "DNS OK: ${DOMAIN} → ${RESOLVED}"
  fi
done

# ── 2. Clone CloudTAK ──
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  log "CloudTAK already cloned in ${INSTALL_DIR}"
else
  info "Cloning CloudTAK..."
  git clone https://github.com/dfpc-coe/CloudTAK.git "${INSTALL_DIR}"
  chown -R tak:tak "${INSTALL_DIR}"
  log "CloudTAK cloned to ${INSTALL_DIR}"
fi
cd "${INSTALL_DIR}"

# ── 3. Configure .env ──
ENV_FILE="${INSTALL_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ ! -f ".env.example" ]]; then
    err ".env.example missing in ${INSTALL_DIR}. Verify CloudTAK was cloned correctly."
  fi
  cp .env.example "$ENV_FILE"
  SIGNING_SECRET=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
  sed -i "s|^SigningSecret=.*|SigningSecret=${SIGNING_SECRET}|" "$ENV_FILE"
  log ".env created from .env.example with random SigningSecret"
else
  log ".env already exists, skipping creation"
fi

sed -i "s|^API_URL=.*|API_URL=https://${CLOUDTAK_DOMAIN}|" "$ENV_FILE"
sed -i "s|^PMTILES_URL=.*|PMTILES_URL=https://${TILES_DOMAIN}|" "$ENV_FILE"
log "API_URL=https://${CLOUDTAK_DOMAIN}, PMTILES_URL=https://${TILES_DOMAIN}"

# Verify .env values
CURRENT_API_URL=$(grep '^API_URL=' "$ENV_FILE" | cut -d= -f2)
if [[ -n "$CURRENT_API_URL" && ! "$CURRENT_API_URL" =~ ^https?:// ]]; then
  sed -i "s|^API_URL=.*|API_URL=https://${CURRENT_API_URL}|" "$ENV_FILE"
  warn "API_URL fixed: added https:// prefix"
fi

# ── 4. Trust TAK Server CA cert in CloudTAK containers ──
# TAK Server uses a self-signed CA. NODE_EXTRA_CA_CERTS tells Node.js to trust it.
# We also mount the CA cert into the container via a volume.
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
CLOUDTAK_CERT_DIR="/home/tak/certs/cloudtak"

if [[ -f "$COMPOSE_FILE" ]]; then
  # Remove NODE_TLS_REJECT_UNAUTHORIZED if present (insecure, replaced by CA trust)
  if grep -q 'NODE_TLS_REJECT_UNAUTHORIZED' "$COMPOSE_FILE"; then
    sed -i '/NODE_TLS_REJECT_UNAUTHORIZED/d' "$COMPOSE_FILE"
    log "NODE_TLS_REJECT_UNAUTHORIZED removed (replaced by NODE_EXTRA_CA_CERTS)"
  fi

  # Add NODE_EXTRA_CA_CERTS, CA cert volume, and extra_hosts to api service
  if ! grep -q 'NODE_EXTRA_CA_CERTS' "$COMPOSE_FILE"; then
    python3 << PYEOF
compose_path = "${INSTALL_DIR}/docker-compose.yml"

with open(compose_path) as f:
    content = f.read()

lines = content.split('\n')
new_lines = []
in_api = False
env_added = False

for line in lines:
    new_lines.append(line)
    # Track when we're in the api service section
    if line.strip().startswith('api:'):
        in_api = True
    elif in_api and line.strip() and not line.startswith(' ') and not line.startswith('\t'):
        in_api = False

    # Add NODE_EXTRA_CA_CERTS after PMTILES_URL
    if in_api and 'PMTILES_URL' in line and not env_added:
        indent = line[:len(line) - len(line.lstrip())]
        new_lines.append(f"{indent}- NODE_EXTRA_CA_CERTS=/etc/ssl/certs/tak-ca.pem")
        env_added = True

result = '\n'.join(new_lines)

# Add volumes and extra_hosts to api service (before environment section)
# extra_hosts maps "takserver" to Docker host gateway IP so TLS cert
# SAN (DNS:takserver) matches the hostname CloudTAK uses to connect.
result = result.replace(
    '            - "5000:5000"\n        environment:',
    '            - "5000:5000"\n        extra_hosts:\n            - "takserver:host-gateway"\n        volumes:\n            - /home/tak/certs/cloudtak/ca.pem:/etc/ssl/certs/tak-ca.pem:ro\n        environment:'
)

with open(compose_path, 'w') as f:
    f.write(result)
PYEOF
    log "NODE_EXTRA_CA_CERTS, CA volume, and extra_hosts added to docker-compose.yml"
  fi
fi

# ── 5. Remap conflicting ports ──
# MinIO port 9000 conflicts with TAK Server Federation v1 (port 9000).
# Remap MinIO API to 9100 and Console to 9102.
if [[ -f "$COMPOSE_FILE" ]]; then
  # Handle both quoted ("9000:9000") and unquoted (- 9000:9000) YAML formats
  if grep -q '9000:9000' "$COMPOSE_FILE"; then
    sed -i 's|9000:9000|9100:9000|g' "$COMPOSE_FILE"
    log "MinIO API port remapped: 9000 → 9100 (avoids TAK Federation v1 conflict)"
  fi

  if grep -q '9002:9002' "$COMPOSE_FILE"; then
    sed -i 's|9002:9002|9102:9002|g' "$COMPOSE_FILE"
    log "MinIO Console port remapped: 9002 → 9102"
  fi
fi

# Update MinIO endpoint in .env if it references port 9000 on localhost
if grep -q 'AWS_S3_Endpoint=http://localhost:9000' "$ENV_FILE" 2>/dev/null; then
  sed -i 's|AWS_S3_Endpoint=http://localhost:9000|AWS_S3_Endpoint=http://localhost:9100|' "$ENV_FILE"
  log "MinIO endpoint in .env updated to port 9100"
fi

# ── 6. Build and start CloudTAK ──
info "Building CloudTAK Docker images (this takes a few minutes)..."
cd "${INSTALL_DIR}"
docker compose build
log "CloudTAK Docker images built"

info "Starting CloudTAK containers..."
docker compose up -d
log "CloudTAK containers started"

info "Waiting for CloudTAK API (max 120s)..."
API_READY=false
for i in $(seq 1 120); do
  if curl -sf http://localhost:5000 > /dev/null 2>&1; then
    log "CloudTAK API responding on :5000"
    API_READY=true
    break
  fi
  sleep 1
done
if [[ "$API_READY" != true ]]; then
  warn "CloudTAK API not responding after 120s"
  warn "Check: cd ${INSTALL_DIR} && docker compose logs api"
fi

echo ""
docker compose ps
echo ""

# ── 7. Configure Caddy reverse proxy ──
info "Configuring Caddy reverse proxy..."

cat > /etc/caddy/Caddyfile << CADDYEOF
# CloudTAK — reverse proxy with automatic HTTPS
${CLOUDTAK_DOMAIN} {
    reverse_proxy localhost:5000 {
        flush_interval -1
    }
}

# Tiles — PMTiles tile server
${TILES_DOMAIN} {
    reverse_proxy localhost:5002 {
        flush_interval -1
    }
}
CADDYEOF

log "Caddyfile written to /etc/caddy/Caddyfile"

# Validate Caddy config
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
  log "Caddy config validated"
else
  warn "Caddy config validation had warnings (may still work)"
fi

systemctl enable caddy
systemctl restart caddy
log "Caddy started (auto-HTTPS for ${CLOUDTAK_DOMAIN} and ${TILES_DOMAIN})"

# Wait for Caddy to obtain certs and start serving
info "Waiting for Caddy to provision TLS certificates..."
sleep 10
for i in $(seq 1 30); do
  if curl -sf "https://${CLOUDTAK_DOMAIN}/" > /dev/null 2>&1; then
    log "Caddy serving HTTPS on ${CLOUDTAK_DOMAIN}"
    break
  fi
  sleep 5
done

# ── 8. Generate CloudTAK client certificate ──
info "Generating CloudTAK client certificate via TAK Server..."

CERT_DIR="${TAK_DIR}/tak/certs"
CLOUDTAK_CERT_DIR="/home/tak/certs/cloudtak"
mkdir -p "$CLOUDTAK_CERT_DIR"

# Generate client cert using TAK Server's makeCert.sh
if [[ -f "${CERT_DIR}/makeCert.sh" ]]; then
  cd "$CERT_DIR"
  export CAPASS="${TAK_CA_PASS}"
  export CA_NAME="takserver-CA"
  export STATE="${TAK_STATE:-State}"
  export CITY="${TAK_CITY:-City}"
  export ORGANIZATION="${TAK_ORGANIZATION:-TAK}"
  export ORGANIZATIONAL_UNIT="${TAK_ORGANIZATIONAL_UNIT:-TAK}"

  if [[ ! -f "${CERT_DIR}/files/cloudtak.p12" ]]; then
    info "Running makeCert.sh client cloudtak..."
    bash makeCert.sh client cloudtak <<< "${TAK_CA_PASS}"
    log "CloudTAK client certificate generated"
  else
    log "CloudTAK client cert already exists"
  fi

  # Find the p12 file
  CLOUDTAK_P12=""
  for path in "${CERT_DIR}/files/cloudtak.p12" "${CERT_DIR}/cloudtak.p12"; do
    if [[ -f "$path" ]]; then
      CLOUDTAK_P12="$path"
      break
    fi
  done

  if [[ -n "$CLOUDTAK_P12" ]]; then
    # Extract PEM cert (client cert only, no CA) and strip bag attributes
    openssl pkcs12 -in "$CLOUDTAK_P12" -clcerts -nokeys \
      -passin "pass:${TAK_CA_PASS}" -legacy 2>/dev/null \
    | openssl x509 -out "${CLOUDTAK_CERT_DIR}/cloudtak.pem" \
    || openssl pkcs12 -in "$CLOUDTAK_P12" -clcerts -nokeys \
      -passin "pass:${TAK_CA_PASS}" \
    | openssl x509 -out "${CLOUDTAK_CERT_DIR}/cloudtak.pem"

    # Extract private key (unencrypted, no bag attributes)
    openssl pkcs12 -in "$CLOUDTAK_P12" -nocerts -nodes \
      -passin "pass:${TAK_CA_PASS}" -legacy 2>/dev/null \
    | openssl pkey -out "${CLOUDTAK_CERT_DIR}/cloudtak.key" \
    || openssl pkcs12 -in "$CLOUDTAK_P12" -nocerts -nodes \
      -passin "pass:${TAK_CA_PASS}" \
    | openssl pkey -out "${CLOUDTAK_CERT_DIR}/cloudtak.key"

    # Find the CA cert
    CA_PEM=""
    for ca_path in "${CERT_DIR}/files/ca.pem" "${CERT_DIR}/files/truststore-root.pem" "${CERT_DIR}/ca.pem"; do
      if [[ -f "$ca_path" ]]; then
        CA_PEM="$ca_path"
        break
      fi
    done

    if [[ -n "$CA_PEM" ]]; then
      cp "$CA_PEM" "${CLOUDTAK_CERT_DIR}/ca.pem"
      # Build cert chain: client cert + CA cert
      cat "${CLOUDTAK_CERT_DIR}/cloudtak.pem" "${CLOUDTAK_CERT_DIR}/ca.pem" > "${CLOUDTAK_CERT_DIR}/cloudtak-chain.pem"
      log "Certificate chain built: cloudtak.pem + ca.pem → cloudtak-chain.pem"
    else
      warn "CA certificate not found — using client cert only"
      cp "${CLOUDTAK_CERT_DIR}/cloudtak.pem" "${CLOUDTAK_CERT_DIR}/cloudtak-chain.pem"
    fi

    # Also grant cloudtak cert admin access and __ANON__ group in TAK Server
    info "Granting admin role and __ANON__ group to cloudtak certificate..."
    if docker exec takserver test -f /opt/tak/certs/files/cloudtak.pem 2>/dev/null; then
      docker exec takserver java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/cloudtak.pem || true
      docker exec takserver java -jar /opt/tak/utils/UserManager.jar usermod -A -g "__ANON__" cloudtak || true
      log "CloudTAK certificate authorized as admin with __ANON__ group"
    fi

    chown -R tak:tak "$CLOUDTAK_CERT_DIR"
    chmod 600 "${CLOUDTAK_CERT_DIR}"/*.key 2>/dev/null || true
    log "Client certificate files in ${CLOUDTAK_CERT_DIR}"
  else
    warn "cloudtak.p12 not found after generation"
  fi
else
  warn "makeCert.sh not found — cannot generate client certificate"
fi

# ── 9. Configure CloudTAK → TAK Server connection ──
info "Configuring CloudTAK server connection..."

# Wait for CloudTAK API to be ready
for i in $(seq 1 15); do
  if curl -sf http://localhost:5000 > /dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ -f "${CLOUDTAK_CERT_DIR}/cloudtak-chain.pem" && -f "${CLOUDTAK_CERT_DIR}/cloudtak.key" ]]; then
  # Official TAK Server uses cert-only auth (no username/password).
  # CloudTAK's PATCH /api/server requires username+password for initial setup,
  # which isn't available in cert-only mode.  Write config directly to the DB.
  CONFIG_RESULT=$(python3 << PYEOF
import json
import subprocess
import sys

tak_domain = "${TAK_DOMAIN}"
cert_dir = "${CLOUDTAK_CERT_DIR}"

try:
    with open(f"{cert_dir}/cloudtak-chain.pem") as f:
        cert_pem = f.read().strip()
    with open(f"{cert_dir}/cloudtak.key") as f:
        key_pem = f.read().strip()
except Exception as e:
    print(f"ERROR: Cannot read cert files: {e}", file=sys.stderr)
    sys.exit(1)

auth_json = json.dumps({"cert": cert_pem, "key": key_pem})
# Dollar-quoting avoids SQL escaping issues with PEM content
dq = "\$\$"

# Use "takserver" hostname (not domain) because the TAK Server certificate
# SAN is DNS:takserver. The extra_hosts directive in docker-compose.yml maps
# "takserver" to the Docker host gateway so it resolves correctly.
sql = f"""
UPDATE server SET
    url   = {dq}ssl://takserver:8089{dq},
    api   = {dq}https://takserver:8443{dq},
    webtak = {dq}https://takserver:8446{dq},
    name  = {dq}TAK Server{dq},
    auth  = {dq}{auth_json}{dq}::json,
    updated = NOW()
WHERE id = 1;

INSERT INTO profile (username, auth, system_admin, name)
VALUES ({dq}cloudtak{dq}, {dq}{auth_json}{dq}::json, true, {dq}CloudTAK Admin{dq})
ON CONFLICT (username) DO UPDATE SET
    auth = EXCLUDED.auth,
    system_admin = true,
    updated = NOW();
"""

result = subprocess.run(
    ["docker", "exec", "-i", "cloudtak-postgis-1", "psql", "-U", "docker", "-d", "gis"],
    input=sql,
    capture_output=True,
    text=True
)

if result.returncode != 0:
    print(f"ERROR: psql failed: {result.stderr}", file=sys.stderr)
    sys.exit(1)

if "UPDATE 1" in result.stdout:
    print("OK")
else:
    print(f"WARN: unexpected psql output: {result.stdout}", file=sys.stderr)
    print("OK")
PYEOF
  )

  if [[ "$CONFIG_RESULT" == "OK" ]]; then
    log "CloudTAK server & admin profile configured (direct DB)"
    log "  api: https://takserver:8443  webtak: https://takserver:8446 (via extra_hosts)"

    # Restart API so it reloads the new server config from DB
    info "Restarting CloudTAK API to apply configuration..."
    cd "${INSTALL_DIR}"
    docker compose restart api
    sleep 5
    log "CloudTAK API restarted"
  else
    warn "CloudTAK server configuration failed."
    warn "You can configure it manually via the CloudTAK web UI."
  fi
else
  warn "Client certificate files not found — skipping server configuration"
  warn "Configure the TAK Server connection manually in CloudTAK."
fi

# ── 10. Verify installation ──
echo ""
info "Verifying installation..."

# Check CloudTAK is responding
CLOUDTAK_OK=false
if curl -sf --max-time 10 "https://${CLOUDTAK_DOMAIN}/" > /dev/null 2>&1; then
  log "CloudTAK responding at https://${CLOUDTAK_DOMAIN}"
  CLOUDTAK_OK=true
else
  warn "Could not reach https://${CLOUDTAK_DOMAIN}"
fi

# Check tiles endpoint
if curl -sf --max-time 10 "https://${TILES_DOMAIN}/" > /dev/null 2>&1; then
  log "Tiles service responding at https://${TILES_DOMAIN}"
else
  warn "Could not reach https://${TILES_DOMAIN}"
fi

# Check TAK Server still responding
if curl -ks --max-time 10 "https://localhost:8443" > /dev/null 2>&1; then
  log "TAK Server still responding on :8443"
else
  warn "TAK Server not responding — check: cd /opt/tak && docker compose ps"
fi

# ── Done ──
echo ""
echo "============================================"
echo -e " ${GREEN}CloudTAK v1.0.0 configured!${NC}"
echo ""
echo " CloudTAK:  https://${CLOUDTAK_DOMAIN}"
echo " Tiles:     https://${TILES_DOMAIN}"
echo " TAK WebUI: https://${TAK_DOMAIN}:8443"
echo " Certs:     ${CLOUDTAK_CERT_DIR}/"
echo " Install:   ${INSTALL_DIR}"
echo ""
echo " Authentication:"
echo "   Log in with your TAK Server username and password."
echo ""
echo "   To add a new user:"
echo "   1. Create TAK user with password:"
echo "      docker exec takserver java -jar /opt/tak/utils/UserManager.jar \\"
echo "        usermod -A -p '<PASSWORD>' <USERNAME>"
echo "      (min 15 chars, 1 upper, 1 lower, 1 digit, 1 special)"
echo ""
echo "   2. Generate client cert for the user:"
echo "      docker exec takserver bash -c 'cd /opt/tak/certs && \\"
echo "        CAPASS=${TAK_CA_PASS} ./makeCert.sh client <USERNAME>'"
echo ""
echo "   3. Inject user profile into CloudTAK DB:"
echo "      See docs/ports.md for the inject_profile.py helper script."
echo ""
echo " Manage CloudTAK:"
echo "   cd ${INSTALL_DIR}"
echo "   docker compose logs -f"
echo "   docker compose restart"
echo ""
echo " Caddy (reverse proxy):"
echo "   systemctl status caddy"
echo "   caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
echo "   journalctl -u caddy"
echo "============================================"
