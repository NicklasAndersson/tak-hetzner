#!/bin/bash
# =============================================================================
# setup-all.sh — Orchestrates official TAK Server installation
# =============================================================================
# Called by deploy.sh after the TAK Server zip has been uploaded.
# Executes setup scripts in order:
#   1. setup-tak.sh         — Extract zip, build Docker, generate certs, start
#   2. setup-letsencrypt.sh — Obtain Let's Encrypt cert, install into TAK
#   3. setup-cloudtak.sh    — Install CloudTAK web client (Caddy reverse proxy)
#   4. setup-enrollment.sh  — Mass enrollment tool
#   5. setup-maps.sh        — Push map layers + upload map source data package
#
# Log: /var/log/tak-setup.log
# =============================================================================
set -euo pipefail

LOG="/var/log/tak-setup.log"
SCRIPTS_DIR="/opt/scripts"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG"; }
err()  { echo -e "${RED}[✘]${NC} $*" | tee -a "$LOG"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG"; }

# --- Source config ---
source "${SCRIPTS_DIR}/config.env"

echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo " TAK Server (GoC) — Automated Setup" | tee -a "$LOG"
echo " $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# --- Verify zip is present ---
TAK_ZIP="/opt/tak-installer/takserver.zip"
if [[ ! -f "$TAK_ZIP" ]]; then
  err "TAK Server zip not found at ${TAK_ZIP}
    Upload it first: scp takserver-docker-*.zip tak@server:/opt/tak-installer/takserver.zip"
fi
log "TAK Server zip found: $(du -h "$TAK_ZIP" | cut -f1)"

# ------------------------------------------------------------------
# 1. Install TAK Server
# ------------------------------------------------------------------
info "Step 1/5 — Installing TAK Server..."
if bash "${SCRIPTS_DIR}/setup-tak.sh" 2>&1 | tee -a "$LOG"; then
  log "TAK Server installed successfully"
else
  err "TAK Server installation failed — aborting"
fi

# ------------------------------------------------------------------
# 2. Let's Encrypt
# ------------------------------------------------------------------
info "Step 2/5 — Setting up Let's Encrypt..."
if bash "${SCRIPTS_DIR}/setup-letsencrypt.sh" 2>&1 | tee -a "$LOG"; then
  log "Let's Encrypt configured successfully"
else
  warn "Let's Encrypt setup failed — TAK Server is running with self-signed certs"
  warn "You can retry later: sudo bash /opt/scripts/setup-letsencrypt.sh"
fi

# ------------------------------------------------------------------
# 3. CloudTAK
# ------------------------------------------------------------------
info "Step 3/5 — Installing CloudTAK..."
if bash "${SCRIPTS_DIR}/setup-cloudtak.sh" 2>&1 | tee -a "$LOG"; then
  log "CloudTAK installed successfully"
else
  warn "CloudTAK setup failed — TAK Server is still running"
  warn "You can retry later: sudo bash /opt/scripts/setup-cloudtak.sh"
fi

# ------------------------------------------------------------------
# 4. Mass enrollment
# ------------------------------------------------------------------
info "Step 4/5 — Setting up mass enrollment tool..."
if bash "${SCRIPTS_DIR}/setup-enrollment.sh" 2>&1 | tee -a "$LOG"; then
  log "Enrollment tool installed successfully"
else
  warn "Enrollment setup failed — not critical"
  warn "You can retry later: sudo bash /opt/scripts/setup-enrollment.sh"
fi

# ------------------------------------------------------------------
# 5. Map sources
# ------------------------------------------------------------------
info "Step 5/5 — Setting up map sources..."
if bash "${SCRIPTS_DIR}/setup-maps.sh" 2>&1 | tee -a "$LOG"; then
  log "Map sources configured successfully"
else
  warn "Map sources setup failed — not critical"
  warn "You can retry later: sudo bash /opt/scripts/setup-maps.sh"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
log "TAK Server setup complete!"
info "Web UI: https://${TAK_DOMAIN}:8443"
info "SSL CoT: ${TAK_DOMAIN}:8089"
if [[ -n "${CLOUDTAK_DOMAIN:-}" ]]; then
  info "CloudTAK: https://${CLOUDTAK_DOMAIN}"
  info "Tiles: https://${TILES_DOMAIN}"
fi
info "Log: ${LOG}"
echo "============================================" | tee -a "$LOG"
