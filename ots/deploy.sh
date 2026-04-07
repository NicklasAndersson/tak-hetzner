#!/bin/bash
# =============================================================================
# deploy.sh — Create Hetzner server and install OpenTAK Server
# =============================================================================
# Automates the full deployment:
#   1. Runs build.sh to generate cloud-init.yaml
#   2. Creates a Hetzner server with your pre-allocated primary IP
#   3. Waits for cloud-init to finish (installs OTS, CloudTAK, ADS-B, etc.)
#
# Unlike tak-server, there is nothing to upload — OTS installs from the
# internet via the cloud-init scripts embedded in the image.
#
# Prerequisites:
#   - hcloud CLI installed and configured (hcloud context active)
#   - config.env filled in (domains, SSH key, Hetzner settings, ADS-B coords)
#   - DNS A records for OTS_DOMAIN, CLOUDTAK_DOMAIN, TILES_DOMAIN
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
for var in TAK_HOSTNAME OTS_DOMAIN CLOUDTAK_DOMAIN TILES_DOMAIN HETZNER_SERVER_TYPE HETZNER_IMAGE HETZNER_LOCATION HETZNER_PRIMARY_IP; do
  if [[ -z "${!var:-}" ]]; then
    err "Variable ${var} is missing or empty in config.env"
  fi
done

echo "============================================"
echo " deploy.sh — OpenTAK Server Deployment"
echo "============================================"
echo ""
info "Server:     ${TAK_HOSTNAME}"
info "OTS:        ${OTS_DOMAIN}"
info "CloudTAK:   ${CLOUDTAK_DOMAIN}"
info "Tiles:      ${TILES_DOMAIN}"
info "ADS-B:      ${ADSB_LAT}, ${ADSB_LON} (${ADSB_RADIUS} nm)"
info "Type:       ${HETZNER_SERVER_TYPE}"
info "Image:      ${HETZNER_IMAGE}"
info "Location:   ${HETZNER_LOCATION}"
info "Primary IP: ${HETZNER_PRIMARY_IP}"
echo ""

# ------------------------------------------------------------------
# 1. Build cloud-init.yaml
# ------------------------------------------------------------------
info "Step 1/3 — Generating cloud-init.yaml..."
bash "${SCRIPT_DIR}/build.sh"
echo ""

CLOUD_INIT="${SCRIPT_DIR}/cloud-init.yaml"
[[ -f "$CLOUD_INIT" ]] || err "cloud-init.yaml not generated"

# ------------------------------------------------------------------
# 2. Create Hetzner server
# ------------------------------------------------------------------
info "Step 2/3 — Creating Hetzner server..."

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
info "Step 3/3 — Waiting for cloud-init to finish..."
info "This takes 15-30 minutes (packages, Docker, OTS, CloudTAK, ADS-B)..."

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

# Wait for cloud-init to finish (includes OTS install + full setup)
info "SSH up — waiting for cloud-init to complete (OTS + CloudTAK + ADS-B)..."
MAX_WAIT=2400  # 40 minutes — OTS install + LE + CloudTAK takes a while
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
  sleep 30
  ELAPSED=$((ELAPSED + 30))
  info "Cloud-init status: ${STATUS} (${ELAPSED}s)"
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "Cloud-init did not finish within ${MAX_WAIT}s — check progress:"
  warn "  ssh tak@${PRIMARY_IP_ADDR} 'tail -f /var/log/tak-setup.log'"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "============================================"
log "OpenTAK Server deployed!"
echo "============================================"
echo ""
info "Server:   ${PRIMARY_IP_ADDR}"
info "SSH:      ssh tak@${OTS_DOMAIN}"
info "OTS:      https://${OTS_DOMAIN}:8443"
info "CloudTAK: https://${CLOUDTAK_DOMAIN}"
info "Tiles:    https://${TILES_DOMAIN}"
info "ADS-B:    ${ADSB_LAT}, ${ADSB_LON} (${ADSB_RADIUS} nm)"
echo ""
info "View setup log:"
info "  ssh tak@${OTS_DOMAIN} 'cat /var/log/tak-setup.log'"
echo ""
info "Default OTS login: administrator / password"
echo ""
