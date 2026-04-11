#!/bin/bash
# =============================================================================
# setup-enrollment.sh — Install TAK enrollment + provisioning tools
# =============================================================================
# Clones https://github.com/sgofferj/TAK-mass-enrollment and configures it
# for automated user provisioning from a CSV file. Also installs the
# provision-users.sh script that generates client certificates and data
# packages for both ATAK and iTAK.
#
# What it does:
#   1. Installs Python 3 venv/pip if needed
#   2. Clones the TAK-mass-enrollment repository
#   3. Sets up Python virtual environment with dependencies
#   4. Patches main.py to save generated passwords to CSV
#   5. Extracts unencrypted admin cert/key for API access
#   6. Installs provision-users.sh + generate-enrollment-pdf.py
#   7. Creates wrapper scripts
#   8. Runs initial provisioning if users.csv exists
#
# CSV format (semicolon-separated, first line skipped as header):
#   Name;username;groups;IN groups;OUT groups
#
# Prerequisites:
#   - TAK Server running (setup-tak.sh completed)
#   - Admin cert generated (/opt/tak/tak/certs/files/admin.p12)
#   - /opt/scripts/config.env with TAK_DOMAIN, TAK_CA_PASS
#
# After setup, provision users any time with:
#   sudo /opt/tak-enrollment/provision.sh /path/to/users.csv
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

ENROLL_DIR="/opt/tak-enrollment"
REPO_DIR="${ENROLL_DIR}/TAK-mass-enrollment"
TAK_DIR="/opt/tak"
CERT_DIR="${TAK_DIR}/tak/certs"

info "Installing TAK enrollment + provisioning tools..."
info "  Repo: https://github.com/sgofferj/TAK-mass-enrollment"
info "  Install dir: ${ENROLL_DIR}"

# ------------------------------------------------------------------
# 1. Install Python dependencies
# ------------------------------------------------------------------
info "Installing Python build dependencies..."
apt-get install -y -qq python3-pip python3-venv python3-dev > /dev/null 2>&1
log "Python build dependencies installed"

# ------------------------------------------------------------------
# 2. Clone repository
# ------------------------------------------------------------------
mkdir -p "$ENROLL_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  info "TAK-mass-enrollment already cloned, pulling latest..."
  cd "$REPO_DIR" && git pull --quiet
else
  info "Cloning TAK-mass-enrollment..."
  git clone --quiet https://github.com/sgofferj/TAK-mass-enrollment.git "$REPO_DIR"
fi
log "Repository ready at ${REPO_DIR}"

# ------------------------------------------------------------------
# 3. Set English language (default is Finnish)
# ------------------------------------------------------------------
cd "$REPO_DIR"
if grep -q 'import lang_fi as lang' main.py 2>/dev/null; then
  sed -i 's/import lang_fi as lang/import lang_en as lang/' main.py
  log "Language set to English"
else
  info "Language already set (not Finnish default)"
fi

# ------------------------------------------------------------------
# 4. Set up Python virtual environment
# ------------------------------------------------------------------
info "Setting up Python virtual environment..."
if [[ ! -d "${REPO_DIR}/venv" ]]; then
  python3 -m venv "${REPO_DIR}/venv"
fi
source "${REPO_DIR}/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
pip install --quiet qrcode Pillow fpdf2
deactivate
log "Python venv ready (${REPO_DIR}/venv)"

# ------------------------------------------------------------------
# 5. Extract admin certificate (unencrypted PEM for API access)
# ------------------------------------------------------------------
info "Extracting admin certificate for API access..."

ADMIN_P12=""
for path in "${CERT_DIR}/files/admin.p12" "${CERT_DIR}/admin.p12"; do
  if [[ -f "$path" ]]; then
    ADMIN_P12="$path"
    break
  fi
done

if [[ -z "$ADMIN_P12" ]]; then
  err "admin.p12 not found in ${CERT_DIR} — run setup-tak.sh first"
fi

# Extract certificate PEM (client cert only, no CA, no bag attributes)
openssl pkcs12 -in "$ADMIN_P12" -clcerts -nokeys \
  -passin "pass:${TAK_CA_PASS}" -legacy 2>/dev/null \
| openssl x509 -out "${ENROLL_DIR}/admin.pem" \
|| openssl pkcs12 -in "$ADMIN_P12" -clcerts -nokeys \
  -passin "pass:${TAK_CA_PASS}" \
| openssl x509 -out "${ENROLL_DIR}/admin.pem"

# Extract private key (unencrypted — the requests library needs this)
openssl pkcs12 -in "$ADMIN_P12" -nocerts -nodes \
  -passin "pass:${TAK_CA_PASS}" -legacy 2>/dev/null \
| openssl pkey -out "${ENROLL_DIR}/admin-key.pem" \
|| openssl pkcs12 -in "$ADMIN_P12" -nocerts -nodes \
  -passin "pass:${TAK_CA_PASS}" \
| openssl pkey -out "${ENROLL_DIR}/admin-key.pem"

chmod 600 "${ENROLL_DIR}/admin-key.pem"
log "Admin cert extracted: ${ENROLL_DIR}/admin.pem + admin-key.pem"

# ------------------------------------------------------------------
# 6. Patch main.py to save passwords to CSV
# ------------------------------------------------------------------
info "Patching main.py to save passwords..."
if [[ -f /opt/scripts/patch-main.py ]]; then
  cd "$REPO_DIR"
  python3 /opt/scripts/patch-main.py
  log "main.py patched (passwords.csv will be saved)"
else
  warn "patch-main.py not found — passwords won't be saved to CSV"
fi

# ------------------------------------------------------------------
# 7. Install provisioning scripts
# ------------------------------------------------------------------
info "Installing provisioning scripts..."

# Copy provision-users.sh
if [[ -f /opt/scripts/provision-users.sh ]]; then
  cp /opt/scripts/provision-users.sh "${ENROLL_DIR}/provision.sh"
  chmod +x "${ENROLL_DIR}/provision.sh"
  log "Provisioning script: ${ENROLL_DIR}/provision.sh"
else
  warn "provision-users.sh not found in /opt/scripts/"
fi

# Copy enrollment PDF generator
if [[ -f /opt/scripts/generate-enrollment-pdf.py ]]; then
  cp /opt/scripts/generate-enrollment-pdf.py "${ENROLL_DIR}/generate-enrollment-pdf.py"
  log "PDF generator: ${ENROLL_DIR}/generate-enrollment-pdf.py"
else
  warn "generate-enrollment-pdf.py not found in /opt/scripts/"
fi

# Create output directory
mkdir -p /home/tak/enrollment-output/datapackages
chown -R tak:tak /home/tak/enrollment-output

# ------------------------------------------------------------------
# 8. Create wrapper script (enroll.sh — legacy, calls provision.sh)
# ------------------------------------------------------------------
cat > "${ENROLL_DIR}/enroll.sh" << 'WRAPPER'
#!/bin/bash
# =============================================================================
# enroll.sh — TAK user provisioning wrapper
# =============================================================================
# Provisions TAK Server users from a CSV file: creates users, generates
# client certificates, builds ATAK + iTAK data packages, and generates
# enrollment PDFs with QR codes.
#
# Usage:
#   sudo /opt/tak-enrollment/enroll.sh <users.csv>
#   sudo /opt/tak-enrollment/enroll.sh <users.csv> --delete
#
# CSV format (semicolon-separated, first line is skipped as header):
#   Name;username;groups;IN groups;OUT groups
#
# Output:
#   ~/enrollment-output/enrollment-slips.pdf
#   ~/enrollment-output/passwords.csv
#   ~/enrollment-output/datapackages/<user>-itak.zip
#   ~/enrollment-output/datapackages/<user>-atak.zip
#
# Download all artifacts:
#   scp -r tak@<server>:~/enrollment-output/ .
# =============================================================================
set -euo pipefail

exec /opt/tak-enrollment/provision.sh "$@"
WRAPPER

chmod +x "${ENROLL_DIR}/enroll.sh"
log "Wrapper script: ${ENROLL_DIR}/enroll.sh"

# ------------------------------------------------------------------
# 9. Set permissions
# ------------------------------------------------------------------
chown -R tak:tak "$ENROLL_DIR"
log "Permissions set (owner: tak)"

# ------------------------------------------------------------------
# 10. Run initial provisioning if users.csv exists
# ------------------------------------------------------------------
if [[ -f "${ENROLL_DIR}/users.csv" ]]; then
  echo ""
  info "Found users.csv — running initial provisioning..."
  info "CSV: ${ENROLL_DIR}/users.csv"
  echo ""

  bash "${ENROLL_DIR}/provision.sh" "${ENROLL_DIR}/users.csv" || {
    warn "Initial provisioning had errors — check output above"
    warn "You can retry: sudo /opt/tak-enrollment/provision.sh /opt/tak-enrollment/users.csv"
  }
else
  info "No users.csv found — skipping initial provisioning"
  info "To provision users later:"
  info "  1. Create a CSV file (see docs/enrollment.md for format)"
  info "  2. Upload and run:"
  info "     scp users.csv tak@${TAK_DOMAIN}:/tmp/"
  info "     ssh tak@${TAK_DOMAIN} 'sudo /opt/tak-enrollment/provision.sh /tmp/users.csv'"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
log "TAK enrollment + provisioning tools installed"
info "  Provision: sudo /opt/tak-enrollment/provision.sh <users.csv>"
info "  Delete:    sudo /opt/tak-enrollment/provision.sh <users.csv> --delete"
info "  Output:    ~/enrollment-output/"
