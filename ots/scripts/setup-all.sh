#!/bin/bash
# =============================================================================
# setup-all.sh — Automatic installation of OTS + CloudTAK + ADS-B
# =============================================================================
# Run by cloud-init as root. Installs and configures everything automatically.
#
# Robustness:
#   - OTS installation is critical (aborts on failure)
#   - Let's Encrypt, CloudTAK, ADS-B run with error handling
#   - Failed steps are logged but don't stop the rest
#   - Summary at the end shows status per step
#
# Requirements:
#   - config.env exists in /opt/scripts/
#   - Docker already installed (cloud-init runcmd)
#   - DNS A records for all domains
# =============================================================================
set -uo pipefail
# NOTE: No -e! We handle errors manually per step.

SCRIPTS_DIR="/opt/scripts"
CONFIG="${SCRIPTS_DIR}/config.env"
LOG="/var/log/tak-setup.log"
OTS_USER="tak"
OTS_HOME="/home/${OTS_USER}"

# Step status (0=OK, 1=FAIL, 2=SKIP)
declare -A STEP_STATUS
STEPS=("OTS" "LE-OTS" "CloudTAK" "ADS-B" "MOTD")
for s in "${STEPS[@]}"; do STEP_STATUS[$s]=2; done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG"; }
info() { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG"; }
err()  { echo -e "${RED}[✘]${NC} $*" | tee -a "$LOG"; exit 1; }

# Run a step with error handling. Critical steps abort (err), others log and continue.
# Usage: run_step "NAME" "critical|soft" command arg1 arg2...
run_step() {
  local name="$1"; shift
  local severity="$1"; shift
  STEP_STATUS[$name]=1  # Assume FAIL until proven otherwise
  if "$@"; then
    STEP_STATUS[$name]=0
    return 0
  else
    local rc=$?
    if [[ "$severity" == "critical" ]]; then
      err "Critical step '${name}' failed (exit ${rc}) — aborting"
    else
      warn "Step '${name}' failed (exit ${rc}) — continuing"
      return 0  # Return 0 so the script continues
    fi
  fi
}

# ── Checks ──
[[ $EUID -eq 0 ]] || err "Must be run as root"
[[ -f "$CONFIG" ]] || err "Config missing: ${CONFIG}"

# Load config
source "$CONFIG"

echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo " TAK Server — Automatic installation" | tee -a "$LOG"
echo " OTS:      ${OTS_DOMAIN}" | tee -a "$LOG"
echo " CloudTAK: ${CLOUDTAK_DOMAIN}" | tee -a "$LOG"
echo " Tiles:    ${TILES_DOMAIN}" | tee -a "$LOG"
echo " ADS-B:    ${ADSB_LAT}, ${ADSB_LON}" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# ── 1. Set password for the tak user ──
echo "tak:tak" | chpasswd
log "Password set for the tak user"

# ── 2. Install OpenTAK Server (CRITICAL) ──
install_ots() {
  info "Installing OpenTAK Server (this takes several minutes)..."
  OTS_INSTALLER="/tmp/ots_installer.sh"
  curl -sL https://i.opentakserver.io/ubuntu_installer -o "$OTS_INSTALLER"
  chmod +x "$OTS_INSTALLER"
  sed -i 's|< /dev/tty||g' "$OTS_INSTALLER"
  log "OTS installer downloaded and patched (no /dev/tty prompts)"

  printf 'n\nn\n' | su - "$OTS_USER" -c "bash $OTS_INSTALLER" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[1]}
  rm -f "$OTS_INSTALLER"
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi
  log "OpenTAK Server installed"
}
run_step "OTS" "critical" install_ots

# ── 2b. Remove HSTS headers temporarily ──
# OTS nginx sends Strict-Transport-Security with self-signed cert.
# Firefox caches HSTS and then blocks all access if the cert is not
# trusted. We strip HSTS here and restore it after LE cert.
info "Removing HSTS headers temporarily (self-signed cert)..."
for conf in /etc/nginx/sites-enabled/ots_*; do
  if [[ -f "$conf" ]]; then
    sed -i '/add_header.*Strict-Transport-Security/d' "$conf"
  fi
done
systemctl reload nginx 2>/dev/null || true
log "HSTS removed (will be restored after LE installation)"

# ── 3. Wait for OTS API ──
info "Waiting for OTS API (port 8081, max 240s)..."
OTS_READY=false
for i in {1..120}; do
  if curl -sf http://localhost:8081/api/health > /dev/null 2>&1; then
    log "OTS API responding on :8081"
    OTS_READY=true
    break
  fi
  sleep 2
done
if [[ "$OTS_READY" != true ]]; then
  warn "OTS API did not respond after 240s — continuing anyway"
fi

# ── 4. Let's Encrypt for OTS ──
step_le_ots() {
  info "Running Let's Encrypt setup..."
  bash "${SCRIPTS_DIR}/setup-letsencrypt.sh" "${OTS_DOMAIN}" 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]}
}
run_step "LE-OTS" "soft" step_le_ots

# ── 5. CloudTAK setup (automatic) ──
step_cloudtak() {
  info "Running CloudTAK setup (automatic mode)..."
  su - "$OTS_USER" -c "bash ${SCRIPTS_DIR}/setup-cloudtak.sh --auto" 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]}
}
run_step "CloudTAK" "soft" step_cloudtak

# ── 6. ADS-B setup ──
step_adsb() {
  info "Running ADS-B setup..."
  bash "${SCRIPTS_DIR}/setup-adsb.sh" "${ADSB_LAT}" "${ADSB_LON}" "${ADSB_RADIUS}" 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]}
}
run_step "ADS-B" "soft" step_adsb

# ── 7. Update MOTD ──
update_motd() {
  # Build status lines
  local status_ots="OK"
  local status_cloudtak="OK"
  local status_adsb="OK"
  [[ ${STEP_STATUS[OTS]} -ne 0 ]] && status_ots="FAILED"
  [[ ${STEP_STATUS[CloudTAK]} -ne 0 ]] && status_cloudtak="FAILED"
  [[ ${STEP_STATUS[ADS-B]} -ne 0 ]] && status_adsb="FAILED"

  cat > /etc/motd << MOTD_EOF
============================================
 TAK Server — ${OTS_DOMAIN}
============================================
 OTS:      https://${OTS_DOMAIN}:8443 [${status_ots}]
 CloudTAK: https://${CLOUDTAK_DOMAIN} [${status_cloudtak}]
 Tiles:    https://${TILES_DOMAIN}
 ADS-B:    ${ADSB_LAT}, ${ADSB_LON} (radius ${ADSB_RADIUS} nm) [${status_adsb}]

 Login:    administrator / password

 Manage CloudTAK:
   cd /home/tak/cloudtak
   ./cloudtak.sh start|stop|update|backup

 Log: ${LOG}
============================================
MOTD_EOF
  log "MOTD updated"
}
run_step "MOTD" "soft" update_motd

# ── Summary ──
echo "" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
echo " Installation summary:" | tee -a "$LOG"
FAILURES=0
for s in "${STEPS[@]}"; do
  case ${STEP_STATUS[$s]} in
    0) echo -e "   ${GREEN}[✔]${NC} ${s}" | tee -a "$LOG" ;;
    1) echo -e "   ${RED}[✘]${NC} ${s}" | tee -a "$LOG"; ((FAILURES++)) ;;
    2) echo -e "   ${YELLOW}[-]${NC} ${s} (skipped)" | tee -a "$LOG" ;;
  esac
done
echo "" | tee -a "$LOG"
if [[ $FAILURES -eq 0 ]]; then
  echo -e " ${GREEN}Everything installed and configured!${NC}" | tee -a "$LOG"
else
  echo -e " ${YELLOW}${FAILURES} step(s) failed. See log: ${LOG}${NC}" | tee -a "$LOG"
fi
echo "" | tee -a "$LOG"
echo " OTS:      https://${OTS_DOMAIN}:8443" | tee -a "$LOG"
echo " CloudTAK: https://${CLOUDTAK_DOMAIN}" | tee -a "$LOG"
echo " Tiles:    https://${TILES_DOMAIN}" | tee -a "$LOG"
echo " ADS-B:    ${ADSB_LAT}, ${ADSB_LON}" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo " Log: ${LOG}" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
