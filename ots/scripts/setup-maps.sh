#!/bin/bash
# =============================================================================
# setup-maps.sh — Upload map source data package to OpenTAK Server
# =============================================================================
# Creates an ATAK/iTAK data package containing map source XMLs (MOBAC format)
# and uploads it via the OTS API. Clients receive the map sources on sync.
#
# Map source URLs point at the MapProxy tile cache (setup-mapproxy.sh) so
# ATAK/iTAK fetches tiles through our server instead of hitting upstream
# providers directly.
#
# Map sources included:
#   - OpenStreetMap, OpenTopoMap
#   - ESRI Satellite, Clarity, World Topo
#   - Lantmäteriet Topo Overview (Swedish, CC0)
#   - OpenSeaMap Base Chart + Seamarks overlay
#
# Run: sudo bash /opt/scripts/setup-maps.sh
# Requires: setup-mapproxy.sh must be run first
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="/opt/scripts"
OTS_USER="tak"
OTS_HOME="/home/${OTS_USER}"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

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

# Source config
[[ -f "${SCRIPTS_DIR}/config.env" ]] && source "${SCRIPTS_DIR}/config.env"

TILES_DOMAIN="${TILES_DOMAIN:?TILES_DOMAIN not set in config.env}"
TILES_BASE="https://${TILES_DOMAIN}"

# Check MapProxy availability
if ! curl -sf "http://127.0.0.1:8083/demo/" > /dev/null 2>&1; then
  warn "MapProxy not running — tile URLs will not work until setup-mapproxy.sh is run"
fi

# Ensure zip is available
if ! command -v zip &>/dev/null; then
  info "Installing zip..."
  apt-get install -y zip >/dev/null 2>&1 || err "Failed to install zip"
fi

echo ""
echo "=== Setting up map sources ==="

# --- Generate map source XMLs ---
mkdir -p "$WORK_DIR/MANIFEST" "$WORK_DIR/maps" "$WORK_DIR/grg"

# All tile URLs point at our MapProxy cache (setup-mapproxy.sh).
# MapProxy fetches from upstream on first request, then serves from MBTiles.

cat > "$WORK_DIR/maps/se_osm.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenStreetMap</name>
    <minZoom>0</minZoom>
    <maxZoom>19</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/osm/{\$z}/{\$x}/{\$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_opentopo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenTopoMap</name>
    <minZoom>1</minZoom>
    <maxZoom>17</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/opentopo/{\$z}/{\$x}/{\$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_satellite.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - Satellite</name>
    <minZoom>0</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/esri_satellite/{\$z}/{\$x}/{\$y}.jpg</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_clarity.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - Clarity</name>
    <minZoom>1</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/esri_clarity/{\$z}/{\$x}/{\$y}.jpg</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_topo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - World Topo</name>
    <minZoom>1</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/esri_topo/{\$z}/{\$x}/{\$y}.jpg</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_openseamap_base.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenSeaMap - Base Chart</name>
    <minZoom>0</minZoom>
    <maxZoom>18</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/openseamap_base/{\$z}/{\$x}/{\$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/grg/grg_openseamap_seamarks.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenSeaMap - Seamarks (Overlay)</name>
    <minZoom>9</minZoom>
    <maxZoom>18</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>${TILES_BASE}/openseamap_seamarks/{\$z}/{\$x}/{\$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

log "Generated 7 map source XMLs (6 basemaps + 1 overlay)"

# --- Build manifest ---
PACKAGE_UID="sweden-maps-$(date +%Y%m%d)"

cat > "$WORK_DIR/MANIFEST/manifest.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<MissionPackageManifest version="2">
    <Configuration>
        <Parameter name="uid" value="${PACKAGE_UID}"/>
        <Parameter name="name" value="Sweden Maps"/>
    </Configuration>
    <Contents>
EOF

for xml in "$WORK_DIR"/maps/*.xml; do
  filename=$(basename "$xml")
  cat >> "$WORK_DIR/MANIFEST/manifest.xml" << ENTRY
        <Content ignore="false" zipEntry="maps/${filename}">
            <Parameter name="contentType" value="Preference File"/>
        </Content>
ENTRY
done

for xml in "$WORK_DIR"/grg/*.xml; do
  filename=$(basename "$xml")
  cat >> "$WORK_DIR/MANIFEST/manifest.xml" << ENTRY
        <Content ignore="false" zipEntry="grg/${filename}">
            <Parameter name="contentType" value="Preference File"/>
        </Content>
ENTRY
done

cat >> "$WORK_DIR/MANIFEST/manifest.xml" << 'EOF'
    </Contents>
</MissionPackageManifest>
EOF

# --- Create zip ---
PACKAGE_PATH="/tmp/sweden-maps.zip"
(cd "$WORK_DIR" && zip -r "$PACKAGE_PATH" MANIFEST/ maps/ grg/)
log "Data package created: $(du -h "$PACKAGE_PATH" | cut -f1)"

# --- Upload via internal Marti API ---
# OTS exposes the Marti API on port 8081 (HTTP, localhost only) — no mTLS needed.
# We compute the SHA256 hash ourselves — hash=auto stores the literal string "auto"
# which causes ATAK clients to fail download verification.
OTS_API="http://localhost:8081"
PACKAGE_HASH=$(sha256sum "$PACKAGE_PATH" | cut -d' ' -f1)

info "Uploading data package to OTS..."
HTTP_CODE=$(curl -s \
  -F "assetfile=@${PACKAGE_PATH}" \
  "${OTS_API}/Marti/sync/missionupload?hash=${PACKAGE_HASH}&filename=sweden-maps.zip&creatorUid=admin" \
  -o /dev/null -w '%{http_code}')

if [[ "$HTTP_CODE" =~ ^2 ]]; then
  log "Data package uploaded to OTS (HTTP ${HTTP_CODE})"
  log "Clients will see 7 map sources after syncing"
else
  warn "Upload returned HTTP ${HTTP_CODE} — package saved at ${PACKAGE_PATH}"
  warn "You can upload manually or import the zip directly on devices"
fi

echo "=== Map sources setup complete ==="
