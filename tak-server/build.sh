#!/bin/bash
# =============================================================================
# build.sh — Generates cloud-init.yaml from template + config
# =============================================================================
# 1. Reads config.env (domains, SSH key, etc.)
# 2. Replaces {{PLACEHOLDER}} in cloud-init.yaml.tpl
# 3. Encodes scripts from scripts/ as gz+b64 and embeds them
# 4. Writes final output to cloud-init.yaml
#
# Usage:
#   cp config.env.example config.env   # fill in your values
#   ./build.sh                         # generates cloud-init.yaml
#   ./deploy.sh                        # creates server, uploads zip, installs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/cloud-init.yaml.tpl"
CONFIG="${SCRIPT_DIR}/config.env"
OUTPUT="${SCRIPT_DIR}/cloud-init.yaml"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# --- Validate files ---
[[ -f "$TEMPLATE" ]] || err "cloud-init.yaml.tpl not found in ${SCRIPT_DIR}"
[[ -f "$CONFIG" ]]   || err "config.env not found — run: cp config.env.example config.env"

echo "============================================"
echo " build.sh — Generating cloud-init.yaml"
echo "       (Official TAK Server)"
echo "============================================"
echo ""

# --- Read config ---
info "Reading config.env..."
source "$CONFIG"

# --- Validate required variables ---
REQUIRED_VARS=(
  TAK_HOSTNAME TAK_TIMEZONE TAK_LOCALE SSH_PUBLIC_KEY
  TAK_DOMAIN CERTBOT_EMAIL
  TAK_CA_PASS TAK_ADMIN_PASS
  CLOUDTAK_DOMAIN TILES_DOMAIN
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    err "Variable ${var} is missing or empty in config.env"
  fi
done
log "All configuration variables validated"

# --- Replace placeholders ---
info "Replacing placeholders in template..."
TMP_FILE=$(mktemp)
cp "$TEMPLATE" "$TMP_FILE"

for var in "${REQUIRED_VARS[@]}"; do
  value="${!var}"
  # Escape special characters for sed (/, &, \)
  escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
  sed -i '' "s|{{${var}}}|${escaped_value}|g" "$TMP_FILE"
done

# Check that no placeholders remain
remaining=$(grep -c '{{' "$TMP_FILE" 2>/dev/null || true)
if [[ "$remaining" -gt 0 ]]; then
  echo ""
  grep -n '{{' "$TMP_FILE"
  err "There are ${remaining} unreplaced placeholders remaining (see above)"
fi
log "All placeholders replaced"

# --- Encode scripts as gz+b64 ---
declare -a SCRIPTS=(
  "setup-tak.sh|# --- TAK Server setup script ---|/opt/scripts/setup-tak.sh"
  "setup-letsencrypt.sh|# --- Let's Encrypt setup script ---|/opt/scripts/setup-letsencrypt.sh"
  "setup-cloudtak.sh|# --- CloudTAK setup script ---|/opt/scripts/setup-cloudtak.sh"
  "setup-enrollment.sh|# --- Enrollment setup script ---|/opt/scripts/setup-enrollment.sh"
  "setup-all.sh|# --- Setup-all orchestration ---|/opt/scripts/setup-all.sh"
)

for entry in "${SCRIPTS[@]}"; do
  IFS='|' read -r script_file comment target_path <<< "$entry"
  src="${SCRIPT_DIR}/scripts/${script_file}"

  if [[ ! -f "$src" ]]; then
    info "Skipping ${script_file} (not found in scripts/)"
    continue
  fi

  info "Encoding ${script_file}..."

  # Generate gz+b64
  encoded=$(gzip -c "$src" | base64)

  # Format with 6 spaces indent (matches cloud-init.yaml)
  formatted=$(echo "$encoded" | fold -w 76 | sed 's/^/      /')

  # Use python3 to replace the content block in YAML
  python3 << PYEOF
import re, sys

cloud_init_path = "${TMP_FILE}"
target_path = "${target_path}"
comment = "${comment}"

with open(cloud_init_path, 'r') as f:
    content = f.read()

new_encoded = """${formatted}"""

pattern = (
    r'(' + re.escape(comment) + r'.*?\n'
    r'\s*- path: ' + re.escape(target_path) + r'\n'
    r'\s*permissions:.*?\n'
    r'\s*encoding: gz\+b64\n'
    r'\s*content: \|\n)'
    r'((?:\s{6,}\S+\n?)+)'
)

match = re.search(pattern, content)
if match:
    replacement = match.group(1) + new_encoded.rstrip() + '\n'
    content = content[:match.start()] + replacement + content[match.end():]
    with open(cloud_init_path, 'w') as f:
        f.write(content)
    print(f"REPLACED: {target_path}")
else:
    new_block = f"""
  {comment}
  - path: {target_path}
    permissions: '0755'
    encoding: gz+b64
    content: |
{new_encoded.rstrip()}

"""
    swap_marker = "  # --- Swap configuration ---"
    if swap_marker in content:
        content = content.replace(swap_marker, new_block.rstrip() + '\n\n' + swap_marker)
        with open(cloud_init_path, 'w') as f:
            f.write(content)
        print(f"ADDED: {target_path}")
    else:
        print(f"SKIP: Could not find insertion point for {target_path}", file=sys.stderr)
        sys.exit(1)
PYEOF

  log "${script_file} → cloud-init.yaml ($(wc -c < "$src" | tr -d ' ') bytes → $(echo "$encoded" | wc -c | tr -d ' ') b64)"
done

# --- Write final output ---
mv "$TMP_FILE" "$OUTPUT"

echo ""
log "cloud-init.yaml generated!"
info "Size: $(wc -c < "$OUTPUT" | tr -d ' ') bytes, $(wc -l < "$OUTPUT" | tr -d ' ') lines"
info "Domain: ${TAK_DOMAIN}"
echo ""
info "Next step: ./deploy.sh"
