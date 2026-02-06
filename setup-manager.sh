#!/bin/bash
# Setup Manager - Set up this machine as a hive manager
# Installs minimal dependencies, Tailscale, Telegram bot, and hive CLI
#
# Usage: sudo ./setup-manager.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/agent-setup"
BIN_DIR="/usr/local/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
}

# Install system dependencies
install_dependencies() {
    log_info "Updating system and installing dependencies..."
    apt-get update -y
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        openssh-client \
        ca-certificates \
        netcat-openbsd
    log_success "Dependencies installed"
}

# Install Python 3 (for Telegram bot)
install_python() {
    log_info "Installing Python 3..."
    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev
    apt-get install -y python3-full 2>/dev/null || true

    if ! command -v pip3 &> /dev/null; then
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        python3 /tmp/get-pip.py --break-system-packages
        rm /tmp/get-pip.py
    fi
    log_success "Python 3 installed"
}

# Install Tailscale
install_tailscale() {
    log_info "Installing Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale installed"
    else
        log_info "Tailscale already installed"
    fi
}

# Install tools to /etc/agent-setup/tools/
install_tools() {
    log_info "Installing hive tools..."
    mkdir -p "$CONFIG_DIR/tools"

    # Copy all tools
    cp -r "$SCRIPT_DIR/tools/hive" "$CONFIG_DIR/tools/"
    cp -r "$SCRIPT_DIR/tools/telegram-bot" "$CONFIG_DIR/tools/"
    cp -r "$SCRIPT_DIR/tools/repo-transfer" "$CONFIG_DIR/tools/"

    # Mark source repo for worker setup
    echo "$SCRIPT_DIR" > "$CONFIG_DIR/.source_repo"

    log_success "Tools installed to $CONFIG_DIR/tools/"
}

# Set up Telegram bot service
setup_telegram_bot() {
    log_info "Setting up Telegram bot service..."

    mkdir -p "$CONFIG_DIR/pending_prompts"

    # Copy bot script
    cp "$SCRIPT_DIR/tools/telegram-bot/agent_telegram_bot.py" "$CONFIG_DIR/"

    # Create default config if not exists
    if [ ! -f "$CONFIG_DIR/telegram_config.json" ]; then
        cat > "$CONFIG_DIR/telegram_config.json" << 'EOF'
{
    "bot_token": "",
    "chat_id": "",
    "binding_phrase": "BIND_AGENT_BOT",
    "bound": false
}
EOF
    fi

    # Create Python virtual environment
    python3 -m venv "$CONFIG_DIR/venv"
    "$CONFIG_DIR/venv/bin/pip" install python-telegram-bot aiofiles

    # Install systemd service
    cp "$SCRIPT_DIR/tools/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
    systemctl daemon-reload

    log_success "Telegram bot service configured"
}

# Install hive CLI
install_hive() {
    log_info "Installing hive CLI..."
    cp "$SCRIPT_DIR/hive" "$BIN_DIR/hive"
    chmod +x "$BIN_DIR/hive"
    log_success "hive CLI installed to $BIN_DIR/hive"
}

# Main
main() {
    check_root

    echo "========================================"
    echo "  Hive Manager Setup"
    echo "========================================"
    echo ""

    install_dependencies
    install_python
    install_tailscale
    install_tools
    setup_telegram_bot
    install_hive

    echo ""
    echo "========================================"
    log_success "Manager setup complete!"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. sudo tailscale up            # Connect to your tailnet"
    echo "  2. sudo hive init               # Configure Telegram bot & worker registry"
    echo "  3. hive worker setup <host> --name <name>  # Set up workers"
    echo ""
}

main "$@"
