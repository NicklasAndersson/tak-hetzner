#!/bin/bash
# =============================================================================
# provision-users.sh — Full user provisioning for ATAK + iTAK
# =============================================================================
# Creates TAK Server users, generates client certificates, builds data
# packages for both ATAK and iTAK, and generates enrollment PDFs.
#
# Flow:
#   1. Run TAK-mass-enrollment (creates users + captures passwords)
#   2. Generate client certificate per user (makeCert.sh)
#   3. Authorize each cert (UserManager.jar certmod -A)
#   4. Re-export P12 with iOS-compatible encryption (AES-256-CBC)
#   5. Build iOS-compatible CA truststore (once)
#   6. Build per-user data packages (ATAK + iTAK)
#   7. Generate enrollment PDF with QR codes
#   8. Bundle everything to output directory
#
# Usage:
#   sudo /opt/tak-enrollment/provision.sh <users.csv>
#   sudo /opt/tak-enrollment/provision.sh <users.csv> --delete
#
# Output:
#   /home/tak/enrollment-output/
#   ├── enrollment-slips.pdf
#   ├── passwords.csv
#   └── datapackages/
#       ├── <user>-itak.zip
#       └── <user>-atak.zip
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

CSV="${1:?Usage: $0 <users.csv> [--delete]}"
[[ -f "$CSV" ]] || err "CSV file not found: $CSV"

# Handle --delete mode (just pass through to enrollment tool)
if [[ "${2:-}" == "--delete" ]]; then
  info "Deleting users from ${CSV}..."
  cd /opt/tak-enrollment/TAK-mass-enrollment
  source venv/bin/activate
  python main.py \
    -s "${TAK_DOMAIN}" \
    -c /opt/tak-enrollment/admin.pem \
    -k /opt/tak-enrollment/admin-key.pem \
    -f "$CSV" \
    --delete
  log "Users deleted"
  exit 0
fi

# --- Configuration ---
ENROLL_DIR="/opt/tak-enrollment"
REPO_DIR="${ENROLL_DIR}/TAK-mass-enrollment"
TAK_DIR="/opt/tak"
CERT_DIR="${TAK_DIR}/tak/certs"
OUTPUT_DIR="/home/tak/enrollment-output"
DATAPACKAGES_DIR="${OUTPUT_DIR}/datapackages"

CONTAINER_CERT_DIR="/opt/tak/certs"

# Cert password (same for CA and client certs)
CERT_PASS="${TAK_CA_PASS}"

echo ""
echo "============================================"
echo " TAK User Provisioning (ATAK + iTAK)"
echo "============================================"
echo ""

# Parse usernames from CSV
USERNAMES=()
while IFS=';' read -r name username groups in_groups out_groups; do
  [[ "$name" == "Name" ]] && continue  # skip header
  USERNAMES+=("$username")
done < "$CSV"

info "Users to provision: ${USERNAMES[*]}"
info "Domain: ${TAK_DOMAIN}"
echo ""

# ------------------------------------------------------------------
# 1. Run TAK-mass-enrollment (create users + passwords)
# ------------------------------------------------------------------
info "Step 1/6 — Creating TAK Server users..."
cd "$REPO_DIR"
source venv/bin/activate

python main.py \
  -s "${TAK_DOMAIN}" \
  -c /opt/tak-enrollment/admin.pem \
  -k /opt/tak-enrollment/admin-key.pem \
  -f "$CSV"

PASSWORDS_CSV="${REPO_DIR}/passwords.csv"
if [[ ! -f "$PASSWORDS_CSV" ]]; then
  err "passwords.csv not generated — enrollment may have failed"
fi
log "Users created, passwords saved to ${PASSWORDS_CSV}"

# ------------------------------------------------------------------
# 2. Generate client certificates
# ------------------------------------------------------------------
info "Step 2/6 — Generating client certificates..."

for username in "${USERNAMES[@]}"; do
  # Check if cert already exists
  if docker exec takserver test -f "${CONTAINER_CERT_DIR}/files/${username}.pem" 2>/dev/null; then
    info "  ${username}: cert already exists, skipping"
    continue
  fi

  info "  ${username}: generating client certificate..."
  docker exec \
    -e STATE="${TAK_STATE:-SE}" \
    -e CITY="${TAK_CITY:-Stockholm}" \
    -e ORGANIZATIONAL_UNIT="${TAK_ORGANIZATIONAL_UNIT:-TAK}" \
    -e ORGANIZATION="${TAK_ORGANIZATION:-TAK}" \
    -e CAPASS="${CERT_PASS}" \
    -e PASS="${CERT_PASS}" \
    takserver bash -c "cd /opt/tak/certs && ./makeCert.sh client ${username}"

  log "  ${username}: certificate generated"
done

# ------------------------------------------------------------------
# 3. Authorize client certificates
# ------------------------------------------------------------------
info "Step 3/6 — Authorizing client certificates..."

for username in "${USERNAMES[@]}"; do
  docker exec takserver java -jar /opt/tak/utils/UserManager.jar \
    certmod -A "${CONTAINER_CERT_DIR}/files/${username}.pem" 2>/dev/null || true
  log "  ${username}: authorized"
done

# ------------------------------------------------------------------
# 4. Create iOS-compatible P12 files + CA truststore
# ------------------------------------------------------------------
info "Step 4/6 — Creating iOS-compatible certificates..."

# Create output directories
mkdir -p "$DATAPACKAGES_DIR"
WORK_DIR=$(mktemp -d)

# Copy CA cert from container
docker cp "takserver:${CONTAINER_CERT_DIR}/files/ca.pem" "${WORK_DIR}/ca.pem"

# Create iOS-compatible CA truststore (once)
TRUSTSTORE_IOS="${WORK_DIR}/truststore-root.p12"
openssl pkcs12 -export -nokeys \
  -in "${WORK_DIR}/ca.pem" \
  -out "$TRUSTSTORE_IOS" \
  -name truststore-root \
  -passout "pass:${CERT_PASS}" \
  -certpbe AES-256-CBC -macalg sha256
log "iOS-compatible CA truststore created"

for username in "${USERNAMES[@]}"; do
  info "  ${username}: re-exporting P12 for iOS..."

  # Copy legacy P12 from container
  docker cp "takserver:${CONTAINER_CERT_DIR}/files/${username}.p12" "${WORK_DIR}/${username}-legacy.p12"

  # Extract cert and key from legacy P12
  # Try with -legacy flag first (OpenSSL 3.x), fall back to without
  openssl pkcs12 -in "${WORK_DIR}/${username}-legacy.p12" \
    -out "${WORK_DIR}/${username}-cert.pem" -clcerts -nokeys \
    -passin "pass:${CERT_PASS}" -legacy 2>/dev/null \
  || openssl pkcs12 -in "${WORK_DIR}/${username}-legacy.p12" \
    -out "${WORK_DIR}/${username}-cert.pem" -clcerts -nokeys \
    -passin "pass:${CERT_PASS}"

  openssl pkcs12 -in "${WORK_DIR}/${username}-legacy.p12" \
    -out "${WORK_DIR}/${username}-key.pem" -nocerts -nodes \
    -passin "pass:${CERT_PASS}" -legacy 2>/dev/null \
  || openssl pkcs12 -in "${WORK_DIR}/${username}-legacy.p12" \
    -out "${WORK_DIR}/${username}-key.pem" -nocerts -nodes \
    -passin "pass:${CERT_PASS}"

  # Re-export with iOS-compatible encryption (AES-256-CBC)
  openssl pkcs12 -export \
    -in "${WORK_DIR}/${username}-cert.pem" \
    -inkey "${WORK_DIR}/${username}-key.pem" \
    -CAfile "${WORK_DIR}/ca.pem" -chain \
    -out "${WORK_DIR}/${username}-ios.p12" \
    -name "$username" \
    -passout "pass:${CERT_PASS}" \
    -certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256

  log "  ${username}: iOS-compatible P12 created"
done

# ------------------------------------------------------------------
# 5. Build data packages
# ------------------------------------------------------------------
info "Step 5/6 — Building data packages..."

for username in "${USERNAMES[@]}"; do
  info "  ${username}: building ATAK + iTAK data packages..."

  python3 - "$username" "$WORK_DIR" "$TRUSTSTORE_IOS" "$CERT_PASS" "$TAK_DOMAIN" "$DATAPACKAGES_DIR" << 'PYSCRIPT'
import sys, zipfile, uuid, os

username = sys.argv[1]
work_dir = sys.argv[2]
truststore_ios = sys.argv[3]
cert_pass = sys.argv[4]
domain = sys.argv[5]
output_dir = sys.argv[6]

uid_atak = str(uuid.uuid4())

# ATAK .pref file (uses /cert/ paths and MANIFEST structure)
atak_pref = f'''<?xml version='1.0' standalone='yes'?>
<preferences>
    <preference version="1" name="cot_streams">
        <entry key="count" class="class java.lang.Integer">1</entry>
        <entry key="description0" class="class java.lang.String">TAK Server</entry>
        <entry key="enabled0" class="class java.lang.Boolean">true</entry>
        <entry key="connectString0" class="class java.lang.String">{domain}:8089:ssl</entry>
    </preference>
    <preference version="1" name="com.atakmap.app_preferences">
        <entry key="clientPassword" class="class java.lang.String">{cert_pass}</entry>
        <entry key="caPassword" class="class java.lang.String">{cert_pass}</entry>
        <entry key="certificateLocation" class="class java.lang.String">/cert/{username}.p12</entry>
        <entry key="caLocation" class="class java.lang.String">/cert/truststore-root.p12</entry>
    </preference>
</preferences>
'''

# iTAK .pref file (cert/ paths without leading slash, flat zip structure)
itak_pref = f'''<?xml version='1.0' encoding='utf-8'?>
<preferences>
    <preference version="1" name="cot_streams">
        <entry key="count" class="class java.lang.Integer">1</entry>
        <entry key="description0" class="class java.lang.String">TAK Server</entry>
        <entry key="enabled0" class="class java.lang.Boolean">true</entry>
        <entry key="connectString0" class="class java.lang.String">{domain}:8089:ssl</entry>
    </preference>
    <preference version="1" name="com.atakmap.app_preferences">
        <entry key="clientPassword" class="class java.lang.String">{cert_pass}</entry>
        <entry key="caPassword" class="class java.lang.String">{cert_pass}</entry>
        <entry key="certificateLocation" class="class java.lang.String">cert/{username}.p12</entry>
        <entry key="caLocation" class="class java.lang.String">cert/truststore-root.p12</entry>
    </preference>
</preferences>
'''

def make_manifest(uid, username):
    return f'''<MissionPackageManifest version="2">
    <Configuration>
        <Parameter name="uid" value="{uid}"/>
        <Parameter name="name" value="{username}_connection"/>
    </Configuration>
    <Contents>
        <Content ignore="false" zipEntry="certs/{username}.p12"/>
        <Content ignore="false" zipEntry="certs/truststore-root.p12"/>
        <Content ignore="false" zipEntry="{username}.pref"/>
    </Contents>
</MissionPackageManifest>
'''

# --- iTAK data package (flat structure, no MANIFEST) ---
itak_zip = os.path.join(output_dir, f"{username}-itak.zip")
with zipfile.ZipFile(itak_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.write(os.path.join(work_dir, f"{username}-ios.p12"), f"{username}.p12")
    zf.write(truststore_ios, "truststore-root.p12")
    zf.writestr("config.pref", itak_pref)
print(f"  Created: {itak_zip}")

# --- ATAK data package (legacy P12, MANIFEST structure) ---
atak_zip = os.path.join(output_dir, f"{username}-atak.zip")
legacy_p12 = os.path.join(work_dir, f"{username}-legacy.p12")
with zipfile.ZipFile(atak_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.write(legacy_p12, f"certs/{username}.p12")
    zf.write(truststore_ios, "certs/truststore-root.p12")
    zf.writestr(f"{username}.pref", atak_pref)
    zf.writestr("MANIFEST/manifest.xml", make_manifest(uid_atak, username))
print(f"  Created: {atak_zip}")
PYSCRIPT

  log "  ${username}: data packages created"
done

# ------------------------------------------------------------------
# 6. Generate enrollment PDF
# ------------------------------------------------------------------
info "Step 6/6 — Generating enrollment PDF..."

# Copy the PDF generator script and run it
ENROLLMENT_PDF="${OUTPUT_DIR}/enrollment-slips.pdf"
cd "$OUTPUT_DIR"

# Set domain for the PDF generator
export TAK_DOMAIN

python3 /opt/tak-enrollment/generate-enrollment-pdf.py "$CSV" "$PASSWORDS_CSV"

# Move PDF to output dir if it was created in cwd
if [[ -f "enrollment-slips.pdf" ]]; then
  mv enrollment-slips.pdf "$ENROLLMENT_PDF" 2>/dev/null || true
fi

# Copy passwords.csv to output
cp "$PASSWORDS_CSV" "${OUTPUT_DIR}/passwords.csv"

log "Enrollment PDF generated"

# ------------------------------------------------------------------
# Cleanup and summary
# ------------------------------------------------------------------
rm -rf "$WORK_DIR"
chown -R tak:tak "$OUTPUT_DIR"

echo ""
echo "============================================"
log "Provisioning complete!"
echo "============================================"
echo ""
info "Output directory: ${OUTPUT_DIR}"
info ""
info "Files:"
info "  ${ENROLLMENT_PDF}"
info "  ${OUTPUT_DIR}/passwords.csv"
for username in "${USERNAMES[@]}"; do
  info "  ${DATAPACKAGES_DIR}/${username}-itak.zip"
  info "  ${DATAPACKAGES_DIR}/${username}-atak.zip"
done
echo ""
info "Download all:"
info "  scp -r tak@${TAK_DOMAIN}:~/enrollment-output/ ."
echo ""
info "Individual download:"
info "  scp tak@${TAK_DOMAIN}:~/enrollment-output/enrollment-slips.pdf ."
info "  scp tak@${TAK_DOMAIN}:~/enrollment-output/datapackages/<user>-itak.zip ."
echo ""
info "iTAK: AirDrop/email the -itak.zip to iPhone, open with iTAK"
info "ATAK: Import -atak.zip via Settings > Network > TAK Servers"
echo "============================================"
