#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/scripts"
BASE_URL="https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main"

echo "=== Claude Statusline Installer ==="
echo ""

mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install a script: download from main, falling back to the local copy beside
# this installer if the download fails.
install_script() {
  local name="$1"
  echo "Installing ${name} to ${INSTALL_DIR}..."
  local tmp
  tmp=$(mktemp)
  if curl -sSL "${BASE_URL}/${name}" -o "$tmp"; then
    cp "$tmp" "${INSTALL_DIR}/${name}"
    chmod +x "${INSTALL_DIR}/${name}"
    echo "  Installed successfully."
  elif [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    echo "  Failed to download. Falling back to local copy..."
    cp "${SCRIPT_DIR}/${name}" "${INSTALL_DIR}/${name}"
    chmod +x "${INSTALL_DIR}/${name}"
    echo "  Installed from local copy."
  else
    echo "  ERROR: No ${name} found to install."
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
}

install_script "statusline.sh"
install_script "subagent-statusline.sh"

# Write initial update marker
echo "$(date +%s)" > "${INSTALL_DIR}/.statusline-last-update"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Add these to your ~/.claude/settings.json:"
echo ""
echo '  "statusLine": {'
echo '    "type": "command",'
echo '    "command": "~/.claude/scripts/statusline.sh"'
echo '  },'
echo '  "subagentStatusLine": {'
echo '    "type": "command",'
echo '    "command": "~/.claude/scripts/subagent-statusline.sh"'
echo '  }'
echo ""
echo "The main script auto-updates from main once per day and refreshes both."
