#!/bin/bash
# =============================================================================
# setup-adsb.sh — ADS-B (Airplanes.live) for OpenTAK Server
# =============================================================================
# Version:    1.1.0
# Date:       2026-03-05
# Source:     https://docs.opentakserver.io/adsb.html
#
# What the script does:
#   1. Verifies that OTS is installed
#   2. Sets ADS-B position/radius in ~/ots/config.yml (OTS_ADSB_*)
#   3. Enables Airplanes.live scheduled job automatically
#   4. Restarts OTS + cot_parser to load new config
#   5. Verifies config
#
# Default position: Gamla Stan, Stockholm (59.3258°N, 18.0716°E)
# Radius: 249 nautical miles
#
# The ADS-B job is enabled automatically by the script.
#
# Usage:
#   sudo bash /opt/scripts/setup-adsb.sh [lat] [lon] [radius_nm]
#
# Requirements:
#   - OpenTAK Server already installed and initialized
# =============================================================================
set -euo pipefail

# Load config.env if it exists
CONFIG_ENV="/opt/scripts/config.env"
if [[ -f "$CONFIG_ENV" ]]; then
  source "$CONFIG_ENV"
fi

# ── Default values: Gamla Stan, Stockholm ──
ADSB_LAT="${1:-${ADSB_LAT:-59.3258}}"
ADSB_LON="${2:-${ADSB_LON:-18.0716}}"
ADSB_RADIUS="${3:-${ADSB_RADIUS:-249}}"
OTS_USER="${4:-tak}"
OTS_HOME="/home/${OTS_USER}"
CONFIG_FILE="${OTS_HOME}/ots/config.yml"

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

echo "============================================"
echo " ADS-B Setup for OpenTAK Server"
echo ""
echo " Position:  ${ADSB_LAT}, ${ADSB_LON}"
echo "            (Gamla Stan, Stockholm)"
echo " Radius:    ${ADSB_RADIUS} nm"
echo "============================================"
echo ""

# ── 1. Checks ──
[[ -f "${CONFIG_FILE}" ]] || err "OTS config missing: ${CONFIG_FILE} — install OTS first"

command -v python3 &>/dev/null || err "python3 missing"
python3 -c "import yaml" 2>/dev/null || {
  warn "PyYAML missing — installing..."
  pip3 install --quiet PyYAML || sudo pip3 install --quiet PyYAML
}

log "OTS config found: ${CONFIG_FILE}"

# ── 2. Validate radius ──
if (( $(echo "${ADSB_RADIUS} > 250" | bc -l) )); then
  err "Radius cannot be greater than 250 nm (Airplanes.live API limitation)"
fi
if (( $(echo "${ADSB_RADIUS} <= 0" | bc -l) )); then
  err "Radius must be greater than 0"
fi
log "Radius OK: ${ADSB_RADIUS} nm"

# ── 3. Update config.yml ──
echo ""
echo "Updating ${CONFIG_FILE}..."

# Backup — use cp directly if already root, otherwise sudo
if [[ $EUID -eq 0 ]]; then
  cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
else
  sudo cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi
log "Backup created"

# Use python3 + PyYAML for safe YAML handling
# Run as root if already root, otherwise use sudo
MAYBE_SUDO=""
[[ $EUID -ne 0 ]] && MAYBE_SUDO="sudo"
$MAYBE_SUDO python3 << PYEOF
import yaml
import sys

config_path = "${CONFIG_FILE}"

try:
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f) or {}

    config['OTS_ADSB_LAT'] = ${ADSB_LAT}
    config['OTS_ADSB_LON'] = ${ADSB_LON}
    config['OTS_ADSB_RADIUS'] = ${ADSB_RADIUS}

    # Remove old keys if they exist
    for old_key in ['OTS_AIRPLANES_LIVE_LAT', 'OTS_AIRPLANES_LIVE_LON', 'OTS_AIRPLANES_LIVE_RADIUS']:
        config.pop(old_key, None)

    # Enable ADS-B scheduled job
    from datetime import datetime
    for job in config.get('JOBS', []):
        if job.get('id') == 'get_adsb_data':
            job['next_run_time'] = datetime.now().isoformat()
            break

    with open(config_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print("OK")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

log "config.yml updated:"
info "  OTS_ADSB_LAT:    ${ADSB_LAT}"
info "  OTS_ADSB_LON:    ${ADSB_LON}"
info "  OTS_ADSB_RADIUS: ${ADSB_RADIUS}"
log "ADS-B scheduled job enabled"

# ── 4. Restart OTS + cot_parser ──
echo ""
echo "Restarting OpenTAK Server + cot_parser..."
$MAYBE_SUDO systemctl restart opentakserver
if $MAYBE_SUDO systemctl is-active --quiet cot_parser 2>/dev/null; then
  $MAYBE_SUDO systemctl restart cot_parser
  log "cot_parser restarted"
fi
log "OTS restarted"

# ── 5. Verify ──
echo ""
echo "Verifying ADS-B configuration..."

# Check that config.yml has the correct values
CONFIG_CHECK=$(python3 << PYEOF
import yaml

with open("${CONFIG_FILE}", 'r') as f:
    config = yaml.safe_load(f)

lat = config.get('OTS_ADSB_LAT')
lon = config.get('OTS_ADSB_LON')
radius = config.get('OTS_ADSB_RADIUS')

if lat is not None and lon is not None and radius is not None:
    print(f"OK: lat={lat}, lon={lon}, radius={radius}")
else:
    print("MISSING")
PYEOF
)

if [[ "$CONFIG_CHECK" == OK:* ]]; then
  log "Config verified: ${CONFIG_CHECK#OK: }"
else
  warn "Config verification failed"
fi

# ── Done ──
echo ""
echo "============================================"
echo -e " ${GREEN}ADS-B (Airplanes.live) configured!${NC}"
echo ""
echo " Position:  ${ADSB_LAT}°N, ${ADSB_LON}°E"
echo "            Gamla Stan, Stockholm"
echo " Radius:    ${ADSB_RADIUS} nm"
echo ""
echo " Aircraft will appear after activation:"
echo "   - OTS WebUI map"
echo "   - ATAK/WinTAK/iTAK (group: ADS-B)"
echo "   - CloudTAK map"
echo ""
echo " ADS-B scheduled job is enabled and runs"
echo "   every 1 minute. Change frequency via:"
echo "   OTS WebUI → Scheduled Jobs → Airplanes.live"
echo ""
echo " Change position:"
echo "   Edit ${CONFIG_FILE}"
echo "   sudo systemctl restart opentakserver"
echo "============================================"
