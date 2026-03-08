#!/bin/bash
# =============================================================================
# deploy.sh — Create Hetzner server and install TAK Server
# =============================================================================
# Automates the full deployment:
#   1. Runs build.sh to generate cloud-init.yaml
#   2. Creates a Hetzner server with hcloud (using a pre-allocated primary IP)
#   3. Waits for cloud-init to finish (base system ready)
#   4. SCPs the TAK Server Docker zip to the server
#   5. SSHs in and runs setup-all.sh to install TAK Server
#
# Prerequisites:
#   - hcloud CLI installed and configured (hcloud context active)
#   - config.env filled in (domains, SSH key, Hetzner settings)
#   - TAK Server Docker zip in this directory
#   - DNS A record for TAK_DOMAIN pointing to the primary IP
#
# Usage:
#   ./deploy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

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

# --- Validate prerequisites ---
command -v hcloud >/dev/null 2>&1 || err "hcloud CLI not found — install it: brew install hcloud"
hcloud server list >/dev/null 2>&1 || err "hcloud has no active context/token. Set one up:
    hcloud context create tak
  (You'll need an API token from Hetzner Console → Security → API Tokens)"
[[ -f "$CONFIG" ]] || err "config.env not found — run: cp config.env.example config.env"

source "$CONFIG"

# Validate required variables
for var in TAK_HOSTNAME TAK_DOMAIN TAK_ZIP_FILENAME HETZNER_SERVER_TYPE HETZNER_IMAGE HETZNER_LOCATION HETZNER_PRIMARY_IP; do
  if [[ -z "${!var:-}" ]]; then
    err "Variable ${var} is missing or empty in config.env"
  fi
done

# Validate zip exists
ZIP_PATH="${SCRIPT_DIR}/${TAK_ZIP_FILENAME}"
[[ -f "$ZIP_PATH" ]] || err "TAK Server zip not found: ${ZIP_PATH}
    Download it from https://tak.gov/products/tak-server"

echo "============================================"
echo " deploy.sh — TAK Server Deployment"
echo "============================================"
echo ""
info "Server:     ${TAK_HOSTNAME}"
info "Domain:     ${TAK_DOMAIN}"
info "Type:       ${HETZNER_SERVER_TYPE}"
info "Image:      ${HETZNER_IMAGE}"
info "Location:   ${HETZNER_LOCATION}"
info "Primary IP: ${HETZNER_PRIMARY_IP}"
info "ZIP:        ${TAK_ZIP_FILENAME} ($(du -h "$ZIP_PATH" | cut -f1))"
echo ""

# ------------------------------------------------------------------
# 1. Build cloud-init.yaml
# ------------------------------------------------------------------
info "Step 1/5 — Generating cloud-init.yaml..."
bash "${SCRIPT_DIR}/build.sh"
echo ""

CLOUD_INIT="${SCRIPT_DIR}/cloud-init.yaml"
[[ -f "$CLOUD_INIT" ]] || err "cloud-init.yaml not generated"

# ------------------------------------------------------------------
# 2. Create Hetzner server
# ------------------------------------------------------------------
info "Step 2/5 — Creating Hetzner server..."

# Check if server already exists (by name)
if hcloud server describe "$TAK_HOSTNAME" >/dev/null 2>&1; then
  warn "Server '${TAK_HOSTNAME}' already exists!"
  read -rp "Delete and recreate? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    info "Deleting existing server '${TAK_HOSTNAME}'..."
    hcloud server delete "$TAK_HOSTNAME"
    sleep 5
  else
    err "Aborted — server already exists"
  fi
fi

# Resolve primary IP — supports both a resource name ("tak-ip") and a raw IP address
if [[ "$HETZNER_PRIMARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # Raw IP address — look up the hcloud resource name
  PRIMARY_IP_ADDR="$HETZNER_PRIMARY_IP"
  PRIMARY_IP_NAME=""
  while IFS= read -r line; do
    ip=$(echo "$line" | awk '{print $2}')
    if [[ "$ip" == "$PRIMARY_IP_ADDR" ]]; then
      PRIMARY_IP_NAME=$(echo "$line" | awk '{print $1}')
      break
    fi
  done < <(hcloud primary-ip list -o columns=name,ip 2>/dev/null || true)
  [[ -n "$PRIMARY_IP_NAME" ]] || err "No hcloud primary IP resource found for address ${PRIMARY_IP_ADDR}.
    Create one first:  hcloud primary-ip create --name tak-ip --type ipv4 --datacenter ${HETZNER_LOCATION}-dc14
    Or use the resource name instead of the IP address in config.env."
  info "Resolved IP ${PRIMARY_IP_ADDR} → resource '${PRIMARY_IP_NAME}'"
else
  # Resource name — resolve the IP address
  PRIMARY_IP_NAME="$HETZNER_PRIMARY_IP"
  PRIMARY_IP_ADDR=$(hcloud primary-ip describe "$PRIMARY_IP_NAME" -o format='{{.IP}}' 2>/dev/null) \
    || err "Could not resolve primary IP '${PRIMARY_IP_NAME}' — create it first:
    hcloud primary-ip create --name ${PRIMARY_IP_NAME} --type ipv4 --datacenter ${HETZNER_LOCATION}-dc14"
  info "Primary IP: ${PRIMARY_IP_NAME} → ${PRIMARY_IP_ADDR}"
fi

# Check if the primary IP is still assigned to another server
ASSIGNED_SERVER=$(hcloud primary-ip describe "$PRIMARY_IP_NAME" -o format='{{.AssigneeID}}' 2>/dev/null || echo "0")
if [[ "$ASSIGNED_SERVER" != "0" && "$ASSIGNED_SERVER" != "<no value>" && -n "$ASSIGNED_SERVER" ]]; then
  ASSIGNED_NAME=$(hcloud server describe "$ASSIGNED_SERVER" -o format='{{.Name}}' 2>/dev/null || echo "ID:${ASSIGNED_SERVER}")
  warn "Primary IP '${PRIMARY_IP_NAME}' is still assigned to server '${ASSIGNED_NAME}'"
  read -rp "Delete server '${ASSIGNED_NAME}' and continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    info "Deleting server '${ASSIGNED_NAME}'..."
    hcloud server delete "$ASSIGNED_SERVER"
    sleep 5
  else
    err "Aborted — primary IP is in use by another server"
  fi
fi

hcloud server create \
  --name "$TAK_HOSTNAME" \
  --type "$HETZNER_SERVER_TYPE" \
  --image "$HETZNER_IMAGE" \
  --location "$HETZNER_LOCATION" \
  --user-data-from-file "$CLOUD_INIT" \
  --primary-ipv4 "$PRIMARY_IP_NAME" \
  --without-ipv6

log "Server '${TAK_HOSTNAME}' created at ${PRIMARY_IP_ADDR}"

# ------------------------------------------------------------------
# 3. Wait for cloud-init to complete
# ------------------------------------------------------------------
info "Step 3/5 — Waiting for cloud-init to finish..."
info "This takes 3-5 minutes (packages, Docker, hardening)..."

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
MAX_WAIT=600
ELAPSED=0

# Wait for SSH to become available
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if ssh $SSH_OPTS "tak@${PRIMARY_IP_ADDR}" "echo ok" >/dev/null 2>&1; then
    log "SSH is available"
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  info "Waiting for SSH... (${ELAPSED}s)"
done

[[ $ELAPSED -lt $MAX_WAIT ]] || err "SSH not available after ${MAX_WAIT}s"

# Wait for cloud-init to finish
info "SSH up — waiting for cloud-init to complete..."
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(ssh $SSH_OPTS "tak@${PRIMARY_IP_ADDR}" "cloud-init status 2>/dev/null | awk '/status:/ {print \$2}'" 2>/dev/null || echo "pending")
  if [[ "$STATUS" == "done" ]]; then
    log "Cloud-init finished"
    break
  elif [[ "$STATUS" == "error" ]]; then
    warn "Cloud-init reported errors — check: ssh tak@${PRIMARY_IP_ADDR} 'sudo cloud-init status --long'"
    break
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  info "Cloud-init status: ${STATUS} (${ELAPSED}s)"
done

# Verify Docker is running
ssh $SSH_OPTS "tak@${PRIMARY_IP_ADDR}" "docker --version" >/dev/null 2>&1 \
  || err "Docker not available on server — cloud-init may have failed"
log "Base system ready (Docker, hardening, firewall)"

# ------------------------------------------------------------------
# 4. Upload TAK Server zip
# ------------------------------------------------------------------
info "Step 4/5 — Uploading TAK Server zip..."
info "Uploading ${TAK_ZIP_FILENAME} ($(du -h "$ZIP_PATH" | cut -f1))..."

scp $SSH_OPTS "$ZIP_PATH" "tak@${PRIMARY_IP_ADDR}:/opt/tak-installer/takserver.zip"
log "TAK Server zip uploaded"

# Upload users.csv for mass enrollment (optional)
if [[ -f "${SCRIPT_DIR}/users.csv" ]]; then
  info "Uploading users.csv for mass enrollment..."
  ssh $SSH_OPTS "tak@${PRIMARY_IP_ADDR}" "sudo mkdir -p /opt/tak-enrollment && sudo chown tak:tak /opt/tak-enrollment"
  scp $SSH_OPTS "${SCRIPT_DIR}/users.csv" "tak@${PRIMARY_IP_ADDR}:/opt/tak-enrollment/users.csv"
  log "users.csv uploaded ($(wc -l < "${SCRIPT_DIR}/users.csv" | tr -d ' ') lines)"
fi

# ------------------------------------------------------------------
# 5. Run TAK Server installation
# ------------------------------------------------------------------
info "Step 5/5 — Installing TAK Server..."
info "This takes 5-10 minutes (extract, build Docker image, generate certs, start)..."

ssh $SSH_OPTS "tak@${PRIMARY_IP_ADDR}" "sudo bash /opt/scripts/setup-all.sh"

# Download enrollment PDF if users were enrolled
if [[ -f "${SCRIPT_DIR}/users.csv" ]]; then
  info "Downloading enrollment PDF..."
  if scp $SSH_OPTS "tak@${PRIMARY_IP_ADDR}:/opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf" "${SCRIPT_DIR}/enrollment-slips.pdf" 2>/dev/null; then
    log "Enrollment PDF saved to ${SCRIPT_DIR}/enrollment-slips.pdf"
  else
    warn "Enrollment PDF not found — enrollment may have been skipped"
  fi
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "============================================"
log "TAK Server deployed!"
echo "============================================"
echo ""
info "Server:   ${PRIMARY_IP_ADDR}"
info "SSH:      ssh tak@${TAK_DOMAIN}"
info "Web UI:   https://${TAK_DOMAIN}:8443"
info "SSL CoT:  ${TAK_DOMAIN}:8089"
echo ""
info "Download admin cert:"
info "  scp tak@${TAK_DOMAIN}:~/certs/admin.p12 ."
echo ""
info "Enroll users:"
info "  scp users.csv tak@${TAK_DOMAIN}:/tmp/"
info "  ssh tak@${TAK_DOMAIN} 'sudo /opt/tak-enrollment/enroll.sh /tmp/users.csv'"
echo ""
info "View logs:"
info "  ssh tak@${TAK_DOMAIN} 'cat /var/log/tak-setup.log'"
