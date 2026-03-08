#!/bin/bash
# =============================================================================
# setup-enrollment.sh — Install TAK mass enrollment tool
# =============================================================================
# Clones https://github.com/sgofferj/TAK-mass-enrollment and configures it
# for automated user provisioning from a CSV file.
#
# What it does:
#   1. Installs Python 3 venv/pip if needed
#   2. Clones the TAK-mass-enrollment repository
#   3. Sets up Python virtual environment with dependencies
#   4. Extracts unencrypted admin cert/key for API access
#   5. Creates a wrapper script (/opt/tak-enrollment/enroll.sh)
#   6. Runs initial enrollment if /opt/tak-enrollment/users.csv exists
#
# The enrollment tool creates TAK Server users with passwords and generates
# a PDF with ATAK Quick Connect QR codes for each user.
#
# CSV format (semicolon-separated, first line skipped as header):
#   Name;username;groups;IN groups;OUT groups
#
# Prerequisites:
#   - TAK Server running (setup-tak.sh completed)
#   - Admin cert generated (/opt/tak/tak/certs/files/admin.p12)
#   - /opt/scripts/config.env with TAK_DOMAIN, TAK_CA_PASS
#
# After setup, add users any time with:
#   sudo /opt/tak-enrollment/enroll.sh /path/to/users.csv
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

info "Installing TAK mass enrollment tool..."
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
# 6. Create wrapper script
# ------------------------------------------------------------------
cat > "${ENROLL_DIR}/enroll.sh" << 'WRAPPER'
#!/bin/bash
# =============================================================================
# enroll.sh — TAK mass enrollment wrapper
# =============================================================================
# Creates TAK Server users from a CSV file and generates a PDF with
# ATAK Quick Connect QR codes for each user.
#
# Usage:
#   sudo /opt/tak-enrollment/enroll.sh <users.csv>
#   sudo /opt/tak-enrollment/enroll.sh <users.csv> --delete
#
# CSV format (semicolon-separated, first line is skipped as header):
#   Name;username;groups;IN groups;OUT groups
#
# Example CSV:
#   Name;Username;Groups;IN Groups;OUT Groups
#   Anna Svensson;anna;blue_team;;
#   Erik Nilsson;erik;red_team;judges;
#   Maria Lindberg;maria;blue_team,medics;judges;incidents
#
# Output:
#   enrollment-slips.pdf — Print and cut into slips for each user
#
# After running, download the PDF:
#   scp tak@<server>:/opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf .
# =============================================================================
set -euo pipefail

source /opt/scripts/config.env

CSV="${1:?Usage: $0 <users.csv> [--delete]}"
[[ -f "$CSV" ]] || { echo "Error: CSV file not found: $CSV"; exit 1; }
shift

cd /opt/tak-enrollment/TAK-mass-enrollment
source venv/bin/activate

python main.py \
  -s "${TAK_DOMAIN}" \
  -c /opt/tak-enrollment/admin.pem \
  -k /opt/tak-enrollment/admin-key.pem \
  -f "$CSV" \
  "$@"

echo ""
echo "============================================"
echo " Enrollment complete!"
echo " PDF: /opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf"
echo ""
echo " Download:"
echo "   scp tak@${TAK_DOMAIN}:/opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf ."
echo "============================================"
WRAPPER

chmod +x "${ENROLL_DIR}/enroll.sh"
log "Wrapper script: ${ENROLL_DIR}/enroll.sh"

# ------------------------------------------------------------------
# 7. Set permissions
# ------------------------------------------------------------------
chown -R tak:tak "$ENROLL_DIR"
log "Permissions set (owner: tak)"

# ------------------------------------------------------------------
# 8. Run initial enrollment if users.csv exists
# ------------------------------------------------------------------
if [[ -f "${ENROLL_DIR}/users.csv" ]]; then
  echo ""
  info "Found users.csv — running initial enrollment..."
  info "CSV: ${ENROLL_DIR}/users.csv"
  echo ""

  bash "${ENROLL_DIR}/enroll.sh" "${ENROLL_DIR}/users.csv" || {
    warn "Initial enrollment had errors — check output above"
    warn "You can retry: sudo /opt/tak-enrollment/enroll.sh /opt/tak-enrollment/users.csv"
  }

  # Copy PDF for easy download
  if [[ -f "${REPO_DIR}/enrollment-slips.pdf" ]]; then
    cp "${REPO_DIR}/enrollment-slips.pdf" "/home/tak/enrollment-slips.pdf"
    chown tak:tak "/home/tak/enrollment-slips.pdf"
    log "Enrollment PDF: /home/tak/enrollment-slips.pdf"
    info "Download: scp tak@${TAK_DOMAIN}:~/enrollment-slips.pdf ."
  fi
else
  info "No users.csv found — skipping initial enrollment"
  info "To enroll users later:"
  info "  1. Create a CSV file (see docs/enrollment.md for format)"
  info "  2. Upload and run:"
  info "     scp users.csv tak@${TAK_DOMAIN}:/tmp/"
  info "     ssh tak@${TAK_DOMAIN} 'sudo /opt/tak-enrollment/enroll.sh /tmp/users.csv'"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
log "TAK mass enrollment tool installed"
info "  Enroll: sudo /opt/tak-enrollment/enroll.sh <users.csv>"
info "  Delete: sudo /opt/tak-enrollment/enroll.sh <users.csv> --delete"
