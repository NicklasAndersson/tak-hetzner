#!/bin/bash
# =============================================================================
# setup-maps.sh — Push map layers to official TAK Server + upload data package
# =============================================================================
# 1. Pushes map layers via the Map Layers API (for instant client sync)
# 2. Builds and uploads an ATAK/iTAK data package (for offline XML distribution)
#
# Map sources included:
#   - OpenStreetMap, OpenTopoMap (global topo with contours)
#   - ESRI Satellite, Clarity, World Topo
#   - Lantmäteriet Topo Overview (Swedish, free CC0)
#   - OpenSeaMap Base Chart + Seamarks overlay
#
# Prerequisites:
#   - TAK Server running
#   - Admin cert extracted (setup-enrollment.sh)
#
# Run: bash /opt/scripts/setup-maps.sh
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="/opt/scripts"
ENROLL_DIR="/opt/tak-enrollment"
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

# Find admin cert
ADMIN_PEM="${ENROLL_DIR}/admin.pem"
ADMIN_KEY="${ENROLL_DIR}/admin-key.pem"
TAK_API="https://localhost:8443/Marti/api"

if [[ ! -f "$ADMIN_PEM" ]] || [[ ! -f "$ADMIN_KEY" ]]; then
  err "Admin cert not found at ${ENROLL_DIR} — run setup-enrollment.sh first"
fi

# Ensure zip is available
if ! command -v zip &>/dev/null; then
  info "Installing zip..."
  apt-get install -y zip >/dev/null 2>&1 || err "Failed to install zip"
fi

echo ""
echo "=== Setting up map layers ==="

# ── 1. Push map layers via Map Layers API ──
# Idempotent — checks if layer exists before creating.
add_map_layer() {
  local name="$1"
  local json="$2"

  # Check if layer already exists
  existing=$(curl -ks --cert "$ADMIN_PEM" --key "$ADMIN_KEY" \
    "${TAK_API}/maplayers/all" 2>/dev/null || echo "")
  if echo "$existing" | grep -q "\"name\":\"${name}\""; then
    info "Layer '${name}' already exists, skipping"
    return 0
  fi

  http_code=$(curl -ks --cert "$ADMIN_PEM" --key "$ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -X POST "${TAK_API}/maplayers" \
    -d "$json" \
    -o /dev/null -w '%{http_code}')

  if [[ "$http_code" =~ ^2 ]]; then
    log "Created layer: ${name}"
  else
    warn "Failed to create '${name}' (HTTP ${http_code})"
  fi
}

info "Pushing map layers via Marti API..."

add_map_layer "OpenStreetMap" '{
  "name": "OpenStreetMap",
  "description": "OSM standard tile layer",
  "type": "XYZ",
  "url": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
  "tileType": "png",
  "minZoom": 0,
  "maxZoom": 19,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "OpenTopoMap" '{
  "name": "OpenTopoMap",
  "description": "Topographic map with elevation contours",
  "type": "XYZ",
  "url": "https://a.tile.opentopomap.org/{z}/{x}/{y}.png",
  "tileType": "png",
  "minZoom": 1,
  "maxZoom": 17,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "Esri - Satellite" '{
  "name": "Esri - Satellite",
  "description": "ESRI World Imagery — satellite/aerial photos",
  "type": "XYZ",
  "url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
  "tileType": "jpg",
  "minZoom": 0,
  "maxZoom": 20,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "Esri - Clarity" '{
  "name": "Esri - Clarity",
  "description": "ESRI Clarity — high-resolution satellite imagery",
  "type": "XYZ",
  "url": "https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
  "tileType": "jpg",
  "minZoom": 1,
  "maxZoom": 20,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "Esri - World Topo" '{
  "name": "Esri - World Topo",
  "description": "ESRI World Topographic Map",
  "type": "XYZ",
  "url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}",
  "tileType": "jpg",
  "minZoom": 1,
  "maxZoom": 20,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "Lantmäteriet Topo (Overview)" '{
  "name": "Lantmäteriet Topo (Overview)",
  "description": "Swedish topographic map — Lantmäteriet open data (CC0)",
  "type": "WMS",
  "url": "https://minkarta.lantmateriet.se/map/topowebb",
  "layers": "topowebbkartan",
  "version": "1.1.1",
  "coordinateSystem": "EPSG:3857",
  "tileType": "png",
  "minZoom": 0,
  "maxZoom": 14,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "OpenSeaMap - Base Chart" '{
  "name": "OpenSeaMap - Base Chart",
  "description": "Nautical base chart",
  "type": "XYZ",
  "url": "https://t1.openseamap.org/tiles/base/{z}/{x}/{y}.png",
  "tileType": "png",
  "minZoom": 0,
  "maxZoom": 18,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

add_map_layer "OpenSeaMap - Seamarks" '{
  "name": "OpenSeaMap - Seamarks",
  "description": "Nautical overlay — buoys, lights, markings",
  "type": "XYZ",
  "url": "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png",
  "tileType": "png",
  "minZoom": 9,
  "maxZoom": 18,
  "defaultLayer": false,
  "enabled": true,
  "ignoreErrors": true
}'

log "Map layers pushed via API"

# ── 2. Build and upload data package ──
# The data package provides the same map sources as MOBAC XMLs for
# ATAK/iTAK clients that prefer the XML format over API-pushed layers.
info "Building map source data package..."

mkdir -p "$WORK_DIR/MANIFEST" "$WORK_DIR/maps" "$WORK_DIR/grg"

cat > "$WORK_DIR/maps/se_osm.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenStreetMap</name>
    <minZoom>0</minZoom>
    <maxZoom>19</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <serverParts>a b c</serverParts>
    <url>https://{$serverpart}.tile.openstreetmap.org/{$z}/{$x}/{$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_opentopo.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenTopoMap</name>
    <minZoom>1</minZoom>
    <maxZoom>17</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <serverParts>a b c</serverParts>
    <url>https://{$serverpart}.tile.opentopomap.org/{$z}/{$x}/{$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_satellite.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - Satellite</name>
    <minZoom>0</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{$z}/{$y}/{$x}</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_clarity.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - Clarity</name>
    <minZoom>1</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{$z}/{$y}/{$x}</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_esri_topo.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>Esri - World Topo</name>
    <minZoom>1</minZoom>
    <maxZoom>20</maxZoom>
    <tileType>jpg</tileType>
    <tileUpdate>None</tileUpdate>
    <url>https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{$z}/{$y}/{$x}</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/maps/se_lantmateriet_topo.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customWmsMapSource>
    <name>Lantmäteriet Topo (Overview)</name>
    <minZoom>0</minZoom>
    <maxZoom>14</maxZoom>
    <tileType>PNG</tileType>
    <version>1.1.1</version>
    <layers>topowebbkartan</layers>
    <url>https://minkarta.lantmateriet.se/map/topowebb?</url>
    <coordinatesystem>EPSG:3857</coordinatesystem>
    <backgroundColor>#000000</backgroundColor>
</customWmsMapSource>
EOF

cat > "$WORK_DIR/maps/se_openseamap_base.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenSeaMap - Base Chart</name>
    <minZoom>0</minZoom>
    <maxZoom>18</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <serverParts>t1 t2 t3</serverParts>
    <url>https://{$serverpart}.openseamap.org/tiles/base/{$z}/{$x}/{$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

cat > "$WORK_DIR/grg/grg_openseamap_seamarks.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenSeaMap - Seamarks (Overlay)</name>
    <minZoom>9</minZoom>
    <maxZoom>18</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>https://tiles.openseamap.org/seamark/{$z}/{$x}/{$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
EOF

# Manifest
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

PACKAGE_PATH="/tmp/sweden-maps.zip"
(cd "$WORK_DIR" && zip -r "$PACKAGE_PATH" MANIFEST/ maps/ grg/)
log "Data package created: $(du -h "$PACKAGE_PATH" | cut -f1)"

# Upload — compute SHA256 hash (hash=auto stores the literal string and breaks client verification)
info "Uploading data package..."
PACKAGE_HASH=$(sha256sum "$PACKAGE_PATH" | cut -d' ' -f1)
HTTP_CODE=$(curl -ks --cert "$ADMIN_PEM" --key "$ADMIN_KEY" \
  -F "assetfile=@${PACKAGE_PATH}" \
  "https://localhost:8443/Marti/sync/missionupload?hash=${PACKAGE_HASH}&filename=sweden-maps.zip&creatorUid=admin" \
  -o /dev/null -w '%{http_code}')

if [[ "$HTTP_CODE" =~ ^2 ]]; then
  log "Data package uploaded (HTTP ${HTTP_CODE})"
else
  warn "Upload returned HTTP ${HTTP_CODE} — package saved at ${PACKAGE_PATH}"
fi

echo "=== Map layers setup complete ==="
