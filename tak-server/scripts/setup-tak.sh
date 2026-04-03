#!/bin/bash
# =============================================================================
# setup-tak.sh — Install official TAK Server (Docker release)
# =============================================================================
# Extracts the TAK Server Docker zip, builds Docker images, generates
# certificates, configures CoreConfig.xml, and starts the containers.
#
# TAK Server 5.x Docker release structure:
#   takserver-docker-X.Y-RELEASE-N/
#   ├── docker/
#   │   ├── Dockerfile.takserver
#   │   └── Dockerfile.takserver-db
#   └── tak/
#       ├── CoreConfig.example.xml
#       ├── configureInDocker.sh
#       ├── db-utils/
#       ├── certs/ (makeRootCa.sh, makeCert.sh)
#       └── ... (configs, jars, etc.)
#
# This script generates a docker-compose.yml since the official release
# does not include one.
#
# References:
#   - https://mytecknet.com/lets-build-a-tak-server/
#   - https://github.com/Cloud-RF/tak-server
#   - https://tak.gov/products/tak-server
#
# Prerequisites:
#   - Docker CE + Docker Compose installed and running
#   - /opt/tak-installer/takserver.zip exists
#   - /opt/scripts/config.env with TAK_DOMAIN, TAK_CA_PASS, TAK_ADMIN_PASS
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

TAK_ZIP="/opt/tak-installer/takserver.zip"
TAK_DIR="/opt/tak"
INSTALLER_DIR="/opt/tak-installer"

info "Installing official TAK Server (Docker release)"
info "Domain: ${TAK_DOMAIN}"

# ------------------------------------------------------------------
# 1. Extract the Docker zip
# ------------------------------------------------------------------
info "Extracting TAK Server Docker release..."
[[ -f "$TAK_ZIP" ]] || err "TAK Server zip not found at ${TAK_ZIP}"

cd "$INSTALLER_DIR"
unzip -o "$TAK_ZIP"

# The zip extracts to a versioned directory like takserver-docker-5.6-RELEASE-22/
EXTRACTED_DIR=$(find "$INSTALLER_DIR" -maxdepth 1 -type d -name 'takserver-docker*' | head -1)
if [[ -z "$EXTRACTED_DIR" ]]; then
  EXTRACTED_DIR=$(find "$INSTALLER_DIR" -maxdepth 1 -type d -name 'takserver*' ! -name 'tak-installer' | head -1)
fi
[[ -n "$EXTRACTED_DIR" ]] || err "Could not find extracted TAK Server directory in ${INSTALLER_DIR}"

TAK_VERSION=$(basename "$EXTRACTED_DIR" | sed 's/takserver-docker-//' | sed 's/takserver-//')
info "Found extracted directory: ${EXTRACTED_DIR}"
info "Detected version: ${TAK_VERSION}"

# Copy to /opt/tak (preserving docker/ and tak/ subdirectories)
mkdir -p "$TAK_DIR"
cp -r "${EXTRACTED_DIR}/"* "$TAK_DIR/"
cd "$TAK_DIR"
log "TAK Server extracted to ${TAK_DIR}"

# ------------------------------------------------------------------
# 2. Configure CoreConfig.xml
# ------------------------------------------------------------------
info "Configuring CoreConfig.xml..."

CORE_CONFIG="${TAK_DIR}/tak/CoreConfig.xml"

if [[ ! -f "$CORE_CONFIG" && -f "${TAK_DIR}/tak/CoreConfig.example.xml" ]]; then
  cp "${TAK_DIR}/tak/CoreConfig.example.xml" "$CORE_CONFIG"
  info "Created CoreConfig.xml from example"
fi

if [[ -f "$CORE_CONFIG" ]]; then
  sed -i "s/TAKSERVER_HOSTNAME/${TAK_DOMAIN}/g" "$CORE_CONFIG" 2>/dev/null || true
  sed -i "s/tak-server-core/${TAK_DOMAIN}/g" "$CORE_CONFIG" 2>/dev/null || true
  sed -i "s/CAPASS/${TAK_CA_PASS}/g" "$CORE_CONFIG" 2>/dev/null || true

  # Fix keystore/truststore passwords to match the actual cert password
  sed -i "s/keystorePass=\"atakatak\"/keystorePass=\"${TAK_CA_PASS}\"/g" "$CORE_CONFIG" 2>/dev/null || true
  sed -i "s/truststorePass=\"atakatak\"/truststorePass=\"${TAK_CA_PASS}\"/g" "$CORE_CONFIG" 2>/dev/null || true

  # Set the database password — the DB setup script reads it from CoreConfig.xml
  # Generate a random DB password if not set
  DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
  sed -i "s|password=\"\"|password=\"${DB_PASS}\"|g" "$CORE_CONFIG" 2>/dev/null || true
  info "Database password set in CoreConfig.xml"

  log "CoreConfig.xml configured with domain ${TAK_DOMAIN}"
else
  warn "CoreConfig.xml not found — TAK Server may generate it on first start"
fi

# ------------------------------------------------------------------
# 3. Generate docker-compose.yml
# ------------------------------------------------------------------
info "Generating docker-compose.yml..."

cat > "${TAK_DIR}/docker-compose.yml" <<'COMPOSE'
services:
  tak-database:
    build:
      context: .
      dockerfile: docker/Dockerfile.takserver-db
    container_name: tak-database
    volumes:
      - ./tak:/opt/tak
      - tak-db-data:/var/lib/postgresql
    networks:
      - tak-net
    restart: unless-stopped
    shm_size: '512m'

  takserver:
    build:
      context: .
      dockerfile: docker/Dockerfile.takserver
    container_name: takserver
    volumes:
      - ./tak:/opt/tak
    ports:
      - "8089:8089"
      - "8090:8090"
      - "8443:8443"
      - "8446:8446"
      - "9000:9000"
      - "9001:9001"
    depends_on:
      - tak-database
    networks:
      - tak-net
    restart: unless-stopped

networks:
  tak-net:
    driver: bridge

volumes:
  tak-db-data:
COMPOSE

log "docker-compose.yml generated"

# ------------------------------------------------------------------
# 4. Build Docker images
# ------------------------------------------------------------------
info "Building TAK Server Docker images..."

cd "$TAK_DIR"

docker compose build
log "Docker images built"

# ------------------------------------------------------------------
# 5. Generate certificates
# ------------------------------------------------------------------
info "Generating TAK Server certificates..."

CERT_DIR="${TAK_DIR}/tak/certs"

if [[ -d "$CERT_DIR" ]]; then
  cd "$CERT_DIR"
  chmod +x *.sh 2>/dev/null || true

  # Set environment variables the cert scripts expect
  export CAPASS="${TAK_CA_PASS}"
  export CA_NAME="takserver-CA"
  export STATE="${TAK_STATE:-State}"
  export CITY="${TAK_CITY:-City}"
  export ORGANIZATION="${TAK_ORGANIZATION:-TAK}"
  export ORGANIZATIONAL_UNIT="${TAK_ORGANIZATIONAL_UNIT:-TAK}"

  # Generate root CA
  if [[ -f "makeRootCa.sh" ]]; then
    info "Generating Root CA..."
    bash makeRootCa.sh --ca-name takserver-CA <<< "${TAK_CA_PASS}"
    log "Root CA generated"
  fi

  # Generate server certificate
  if [[ -f "makeCert.sh" ]]; then
    info "Generating server certificate for ${TAK_DOMAIN}..."
    bash makeCert.sh server takserver <<< "${TAK_CA_PASS}"
    log "Server certificate generated"

    # Generate admin client certificate
    info "Generating admin client certificate..."
    bash makeCert.sh client admin <<< "${TAK_CA_PASS}"
    log "Admin client certificate generated"
  fi

  cd "$TAK_DIR"
else
  warn "Certificate directory not found at ${CERT_DIR}"
fi

# ------------------------------------------------------------------
# 6. Set file permissions
# ------------------------------------------------------------------
info "Setting file permissions..."
chown -R 1000:1000 "$TAK_DIR" 2>/dev/null || true

# ------------------------------------------------------------------
# 7. Start TAK Server containers
# ------------------------------------------------------------------
info "Starting TAK Server containers..."
cd "$TAK_DIR"

docker compose up -d
log "TAK Server containers started"

# ------------------------------------------------------------------
# 8. Wait for TAK Server to be ready
# ------------------------------------------------------------------
info "Waiting for TAK Server to become ready..."
MAX_WAIT=300
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if curl -ks "https://localhost:8443" >/dev/null 2>&1; then
    log "TAK Server is responding on port 8443"
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  info "Waiting... (${ELAPSED}s/${MAX_WAIT}s)"
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "TAK Server did not respond within ${MAX_WAIT}s"
  warn "Check logs: cd /opt/tak && docker compose logs"
fi

# ------------------------------------------------------------------
# 9. Grant admin privileges to admin cert
# ------------------------------------------------------------------
info "Granting admin role to admin certificate..."
if docker exec takserver test -f /opt/tak/certs/files/admin.pem 2>/dev/null; then
  docker exec takserver java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem
  log "Admin certificate authorized"
else
  warn "admin.pem not found in container — grant admin manually:"
  warn "  sudo docker exec takserver java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem"
fi

# ------------------------------------------------------------------
# 10. Copy admin cert for user access
# ------------------------------------------------------------------
ADMIN_P12=""
for path in "tak/certs/files/admin.p12" "tak/certs/admin.p12"; do
  if [[ -f "${TAK_DIR}/${path}" ]]; then
    ADMIN_P12="${TAK_DIR}/${path}"
    break
  fi
done

if [[ -n "$ADMIN_P12" ]]; then
  mkdir -p /home/tak/certs
  cp "$ADMIN_P12" /home/tak/certs/
  chown -R tak:tak /home/tak/certs
  chmod 600 /home/tak/certs/admin.p12
  log "Admin certificate copied to /home/tak/certs/admin.p12"
  info "Download it with: scp tak@${TAK_DOMAIN}:~/certs/admin.p12 ."
fi

# ------------------------------------------------------------------
# 10. Show container status
# ------------------------------------------------------------------
echo ""
info "Container status:"
docker compose ps
echo ""

log "TAK Server (Docker) installation complete"
