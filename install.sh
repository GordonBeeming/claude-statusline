#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/scripts"
REPO_URL="https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/statusline.sh"

echo "=== Claude Statusline Installer ==="
echo ""

# --- Install/upgrade goccc ---
echo "Installing/upgrading goccc..."
if command -v brew &>/dev/null; then
  if brew list backstabslash/tap/goccc &>/dev/null; then
    brew upgrade backstabslash/tap/goccc 2>/dev/null || echo "  goccc is already up to date."
  else
    brew install backstabslash/tap/goccc
  fi
else
  echo "  Homebrew not found. Please install goccc manually:"
  echo "  https://github.com/backstabslash/goccc"
fi
echo ""

# --- Install statusline.sh ---
echo "Installing statusline.sh to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

tmp=$(mktemp)
if curl -sSL "$REPO_URL" -o "$tmp"; then
  cp "$tmp" "${INSTALL_DIR}/statusline.sh"
  chmod +x "${INSTALL_DIR}/statusline.sh"
  echo "  Installed successfully."
else
  echo "  Failed to download. Falling back to local copy..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/statusline.sh" ]]; then
    cp "${SCRIPT_DIR}/statusline.sh" "${INSTALL_DIR}/statusline.sh"
    chmod +x "${INSTALL_DIR}/statusline.sh"
    echo "  Installed from local copy."
  else
    echo "  ERROR: No statusline.sh found to install."
    exit 1
  fi
fi
rm -f "$tmp"

# Write initial update marker
echo "$(date +%s)" > "${INSTALL_DIR}/.statusline-last-update"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Add this to your ~/.claude/settings.json:"
echo ""
echo '  "statusLine": {'
echo '    "type": "command",'
echo '    "command": "~/.claude/scripts/statusline.sh"'
echo '  }'
echo ""
echo "The script will auto-update from main once per day."
