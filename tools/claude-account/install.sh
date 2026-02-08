#!/usr/bin/env bash
# Standalone installer for claude-account
# Usage:
#   ./install.sh                    # Install from local repo
#   curl -fsSL <url> | bash         # Install from remote

set -euo pipefail

TOOL_NAME="claude-account"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
REPO_URL="https://raw.githubusercontent.com/Hyodar/hive/master/tools/claude-account/claude-account"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

# Check for jq (required dependency)
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Missing dependency:${NC} jq"
    echo ""
    echo "Install it with:"
    echo "  Ubuntu/Debian: sudo apt install jq"
    echo "  macOS:         brew install jq"
    echo "  Fedora:        sudo dnf install jq"
    exit 1
fi

# Determine source: local file (from repo) or download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$TOOL_NAME" ]]; then
    SOURCE="$SCRIPT_DIR/$TOOL_NAME"
    echo "Installing $TOOL_NAME from local repo..."
else
    echo "Downloading $TOOL_NAME..."
    SOURCE=$(mktemp)
    trap 'rm -f "$SOURCE"' EXIT
    curl -fsSL "$REPO_URL" -o "$SOURCE" || die "Failed to download $TOOL_NAME"
fi

# Install to bin directory
if [[ -w "$INSTALL_DIR" ]]; then
    cp "$SOURCE" "$INSTALL_DIR/$TOOL_NAME"
    chmod +x "$INSTALL_DIR/$TOOL_NAME"
else
    echo "Need sudo to install to $INSTALL_DIR"
    sudo cp "$SOURCE" "$INSTALL_DIR/$TOOL_NAME"
    sudo chmod +x "$INSTALL_DIR/$TOOL_NAME"
fi

echo -e "${GREEN}Installed${NC} $TOOL_NAME to $INSTALL_DIR/$TOOL_NAME"
echo ""
echo "Get started:"
echo "  $TOOL_NAME setup <name>   # Logout, login, save as named account"
echo "  $TOOL_NAME save <name>    # Save current auth as named account"
echo "  $TOOL_NAME use [name]     # Switch accounts"
echo "  $TOOL_NAME list           # List saved accounts"
