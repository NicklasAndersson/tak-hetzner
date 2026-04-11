#!/bin/bash
# =============================================================================
# build-maps-package.sh — Build an ATAK/iTAK data package from map source XMLs
# =============================================================================
# Creates a zip file with MANIFEST/manifest.xml that ATAK/iTAK can import.
# Map source XMLs (MOBAC format) are included as "Preference File" entries.
# Overlay XMLs (grg_* prefix) are included as separate entries.
#
# Usage:
#   ./build-maps-package.sh                        # outputs sweden-maps.zip
#   ./build-maps-package.sh -o custom-name.zip     # custom output name
#
# Import in ATAK: tap Import → select the zip
# Import in iTAK: open the zip via Files / AirDrop
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${SCRIPT_DIR}/sweden-maps.zip"

# Parse args
while getopts "o:" opt; do
  case $opt in
    o) OUTPUT="$OPTARG" ;;
    *) echo "Usage: $0 [-o output.zip]"; exit 1 ;;
  esac
done

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# --- Collect XML files ---
BASEMAPS=()
OVERLAYS=()
for xml in "${SCRIPT_DIR}"/se_*.xml; do
  [[ -f "$xml" ]] && BASEMAPS+=("$xml")
done
for xml in "${SCRIPT_DIR}"/grg_*.xml; do
  [[ -f "$xml" ]] && OVERLAYS+=("$xml")
done

TOTAL=$(( ${#BASEMAPS[@]} + ${#OVERLAYS[@]} ))
if [[ $TOTAL -eq 0 ]]; then
  echo "No XML files found in ${SCRIPT_DIR}"
  exit 1
fi
info "Found ${#BASEMAPS[@]} basemaps, ${#OVERLAYS[@]} overlays"

# --- Build package ---
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR/MANIFEST" "$WORK_DIR/maps" "$WORK_DIR/grg"

# Copy files
for xml in "${BASEMAPS[@]}"; do
  cp "$xml" "$WORK_DIR/maps/"
done
for xml in "${OVERLAYS[@]}"; do
  cp "$xml" "$WORK_DIR/grg/"
done

# --- Generate manifest ---
PACKAGE_UID="sweden-maps-$(date +%Y%m%d)"

cat > "$WORK_DIR/MANIFEST/manifest.xml" << MANIFEST_HEADER
<?xml version="1.0" encoding="UTF-8"?>
<MissionPackageManifest version="2">
    <Configuration>
        <Parameter name="uid" value="${PACKAGE_UID}"/>
        <Parameter name="name" value="Sweden Maps"/>
    </Configuration>
    <Contents>
MANIFEST_HEADER

for xml in "${BASEMAPS[@]}"; do
  filename=$(basename "$xml")
  cat >> "$WORK_DIR/MANIFEST/manifest.xml" << ENTRY
        <Content ignore="false" zipEntry="maps/${filename}">
            <Parameter name="contentType" value="Preference File"/>
        </Content>
ENTRY
done

for xml in "${OVERLAYS[@]}"; do
  filename=$(basename "$xml")
  cat >> "$WORK_DIR/MANIFEST/manifest.xml" << ENTRY
        <Content ignore="false" zipEntry="grg/${filename}">
            <Parameter name="contentType" value="Preference File"/>
        </Content>
ENTRY
done

cat >> "$WORK_DIR/MANIFEST/manifest.xml" << MANIFEST_FOOTER
    </Contents>
</MissionPackageManifest>
MANIFEST_FOOTER

# --- Create zip ---
(cd "$WORK_DIR" && zip -r "$OUTPUT" MANIFEST/ maps/ grg/ -x "*.DS_Store")

echo ""
log "Data package created: ${OUTPUT}"
info "Contains: ${#BASEMAPS[@]} basemaps + ${#OVERLAYS[@]} overlays"
info "Size: $(du -h "$OUTPUT" | cut -f1)"
echo ""
info "Import in ATAK: tap Import → select the zip"
info "Import in iTAK: open the zip via Files / AirDrop"
info "Upload to server:"
info "  curl -k --cert admin.pem -F 'assetfile=@${OUTPUT}' \\"
info "    'https://\${DOMAIN}:8443/Marti/sync/missionupload?hash=auto&filename=$(basename "$OUTPUT")&creatorUid=admin'"
