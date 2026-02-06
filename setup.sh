#!/bin/bash
# Agent Machine Setup Script
# Sets up a machine for agentic AI development work

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/agent-setup"
BIN_DIR="/usr/local/bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    apt-get update -y
    apt-get upgrade -y
    log_success "System packages updated"
}

# Install basic dependencies
install_dependencies() {
    log_info "Installing basic dependencies..."
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        gnupg \
        apt-transport-https \
        ca-certificates \
        software-properties-common \
        unzip \
        build-essential \
        netcat-openbsd
    log_success "Basic dependencies installed"
}

# Install Python 3 with pip
install_python() {
    log_info "Installing Python 3 and pip..."

    # Core python packages (available on both Debian and Ubuntu)
    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev

    # python3-full is Debian-specific, install if available
    apt-get install -y python3-full 2>/dev/null || true

    # Ensure pip is available (some Ubuntu versions need this)
    if ! command -v pip3 &> /dev/null; then
        log_info "Installing pip via get-pip.py..."
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        python3 /tmp/get-pip.py --break-system-packages
        rm /tmp/get-pip.py
    fi

    log_success "Python 3 and pip installed"
}

# Install nvm and Node.js 24
install_nodejs() {
    log_info "Installing nvm and Node.js 24..."

    # Install nvm system-wide
    export NVM_DIR="/usr/local/nvm"
    mkdir -p "$NVM_DIR"

    if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        log_info "Downloading and installing nvm..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | NVM_DIR="$NVM_DIR" bash
    fi

    # Source nvm
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Install Node.js 24
    log_info "Installing Node.js 24..."
    nvm install 24
    nvm use 24
    nvm alias default 24

    # Create system-wide symlinks
    NODE_PATH=$(nvm which 24)
    NODE_DIR=$(dirname "$NODE_PATH")
    ln -sf "$NODE_PATH" /usr/local/bin/node
    ln -sf "$NODE_DIR/npm" /usr/local/bin/npm
    ln -sf "$NODE_DIR/npx" /usr/local/bin/npx

    # Add nvm to system profile for all users
    cat > /etc/profile.d/nvm.sh << 'NVMEOF'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
NVMEOF

    chmod +x /etc/profile.d/nvm.sh

    log_success "nvm and Node.js 24 installed"
    log_info "Node version: $(node --version)"
    log_info "npm version: $(npm --version)"
}

# Install Claude Code
install_claude_code() {
    log_info "Installing Claude Code..."
    if ! command -v claude &> /dev/null; then
        npm install -g @anthropic-ai/claude-code
        log_success "Claude Code installed"
    else
        log_info "Claude Code already installed"
    fi
}

# Install Codex (OpenAI)
install_codex() {
    log_info "Installing Codex CLI..."
    if ! command -v codex &> /dev/null; then
        npm install -g @openai/codex
        log_success "Codex installed"
    else
        log_info "Codex already installed"
    fi
}

# Install Amp
install_amp() {
    log_info "Installing Amp..."
    if ! command -v amp &> /dev/null; then
        npm install -g @anthropic-ai/amp
        log_success "Amp installed"
    else
        log_info "Amp already installed"
    fi
}

# Install VSCode
install_vscode() {
    log_info "Installing Visual Studio Code..."
    if ! command -v code &> /dev/null; then
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
        install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
        rm -f /tmp/packages.microsoft.gpg
        apt-get update
        apt-get install -y code
        log_success "VSCode installed"
    else
        log_info "VSCode already installed"
    fi
}

# Install NoMachine
install_nomachine() {
    log_info "Installing NoMachine..."
    if ! command -v nxserver &> /dev/null; then
        NOMACHINE_VERSION="8.14.2"
        NOMACHINE_BUILD="1"
        ARCH=$(dpkg --print-architecture)
        if [ "$ARCH" = "amd64" ]; then
            NOMACHINE_ARCH="amd64"
        else
            NOMACHINE_ARCH="arm64"
        fi
        wget -q "https://download.nomachine.com/download/8.14/Linux/nomachine_${NOMACHINE_VERSION}_${NOMACHINE_BUILD}_${NOMACHINE_ARCH}.deb" -O /tmp/nomachine.deb
        apt-get install -y /tmp/nomachine.deb
        rm /tmp/nomachine.deb
        log_success "NoMachine installed"
    else
        log_info "NoMachine already installed"
    fi
}

# Install Tailscale
install_tailscale() {
    log_info "Installing Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale installed"
        log_info "Run 'sudo tailscale up' to connect to your tailnet"
    else
        log_info "Tailscale already installed"
    fi
}

# Configure UFW to restrict NoMachine to Tailscale only
configure_firewall() {
    log_info "Configuring UFW firewall..."

    # Install ufw if not present
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi

    # Allow SSH so we don't lock ourselves out
    ufw allow ssh

    # Allow NoMachine (port 4000) only from Tailscale network (100.64.0.0/10)
    ufw allow from 100.64.0.0/10 to any port 4000 proto tcp
    ufw allow from 100.64.0.0/10 to any port 4000 proto udp

    # Deny NoMachine port from all other sources
    ufw deny 4000

    # Enable UFW (--force to avoid interactive prompt)
    ufw --force enable

    log_success "UFW configured: NoMachine (port 4000) restricted to Tailscale network only"
}

# Install Cinnamon desktop
install_cinnamon() {
    log_info "Installing Cinnamon desktop environment..."
    apt-get install -y cinnamon-desktop-environment lightdm
    systemctl set-default graphical.target
    log_success "Cinnamon desktop installed"
}

# Setup global aliases for sandboxless execution
setup_aliases() {
    log_info "Setting up global aliases..."

    # Create xclaude wrapper
    cat > "$BIN_DIR/xclaude" << 'EOF'
#!/bin/bash
# xclaude - Run Claude Code without sandbox and permission prompts
exec claude --dangerously-skip-permissions "$@"
EOF
    chmod +x "$BIN_DIR/xclaude"

    # Create xcodex wrapper
    cat > "$BIN_DIR/xcodex" << 'EOF'
#!/bin/bash
# xcodex - Run Codex without sandbox and permission prompts
# Uses gpt-5.2-codex xhigh model with full dangerous mode
exec codex --dangerously-bypass-approvals-and-sandbox -m "gpt-5.2-codex xhigh" "$@"
EOF
    chmod +x "$BIN_DIR/xcodex"

    # Create xamp wrapper
    cat > "$BIN_DIR/xamp" << 'EOF'
#!/bin/bash
# xamp - Run Amp without sandbox and permission prompts
exec amp --dangerously-allow-all "$@"
EOF
    chmod +x "$BIN_DIR/xamp"

    log_success "Global aliases created: xclaude, xcodex, xamp"
}

# Setup Telegram bot service
setup_telegram_bot() {
    log_info "Setting up Telegram bot service..."

    # Create config directory
    mkdir -p "$CONFIG_DIR"

    # Copy Python bot script
    cp "$SCRIPT_DIR/telegram-bot/agent_telegram_bot.py" "$CONFIG_DIR/"

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

    # Copy alertme and promptme scripts
    cp "$SCRIPT_DIR/telegram-bot/alertme" "$BIN_DIR/"
    cp "$SCRIPT_DIR/telegram-bot/promptme" "$BIN_DIR/"
    chmod +x "$BIN_DIR/alertme"
    chmod +x "$BIN_DIR/promptme"

    # Install systemd service
    cp "$SCRIPT_DIR/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
    systemctl daemon-reload

    log_success "Telegram bot service configured"
    log_info "Run 'tgsetup' to configure the bot"
}

# Install telegram bot setup script
install_telegram_setup() {
    log_info "Installing Telegram bot setup script..."
    cp "$SCRIPT_DIR/telegram-bot/tgsetup" "$BIN_DIR/"
    chmod +x "$BIN_DIR/tgsetup"
    log_success "Telegram bot setup script installed (tgsetup)"
}

# Install ralph2 and ralphsetup
install_ralph2() {
    log_info "Installing ralph2 and ralphsetup..."

    # Create ralph2 directory structure
    mkdir -p "$CONFIG_DIR/ralph2"
    mkdir -p "$CONFIG_DIR/ralph2/skills/prd"
    mkdir -p "$CONFIG_DIR/ralph2/skills/ralph"

    # Copy ralph2 files
    cp "$SCRIPT_DIR/ralph2/ralph2.sh" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/ralph2/prompt.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/ralph2/CLAUDE.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/ralph2/AGENTS.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/ralph2/CODEX.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/ralph2/prd.json.example" "$CONFIG_DIR/ralph2/"

    # Copy skills if they exist
    if [ -d "$SCRIPT_DIR/ralph2/skills" ]; then
        cp -r "$SCRIPT_DIR/ralph2/skills/"* "$CONFIG_DIR/ralph2/skills/"
    fi

    chmod +x "$CONFIG_DIR/ralph2/ralph2.sh"

    # Create global ralph2 command
    cat > "$BIN_DIR/ralph2" << EOF
#!/bin/bash
# ralph2 - Enhanced Ralph agent loop with Codex support
exec "$CONFIG_DIR/ralph2/ralph2.sh" "\$@"
EOF
    chmod +x "$BIN_DIR/ralph2"

    # Install ralphsetup
    cp "$SCRIPT_DIR/ralph2/ralphsetup" "$BIN_DIR/"
    chmod +x "$BIN_DIR/ralphsetup"

    log_success "ralph2 and ralphsetup installed"
}

# Main installation
main() {
    check_root

    echo "========================================"
    echo "  Agent Machine Setup"
    echo "========================================"
    echo ""

    update_system
    install_dependencies
    install_python
    install_nodejs

    echo ""
    log_info "Installing AI coding tools..."
    install_claude_code
    install_codex
    install_amp

    echo ""
    log_info "Installing development tools..."
    install_vscode

    echo ""
    log_info "Installing remote access tools..."
    install_nomachine
    install_tailscale
    configure_firewall

    echo ""
    log_info "Installing desktop environment..."
    install_cinnamon

    echo ""
    log_info "Setting up agent tools..."
    setup_aliases
    setup_telegram_bot
    install_telegram_setup
    install_ralph2

    echo ""
    echo "========================================"
    log_success "Setup complete!"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. Run 'tgsetup' to configure the Telegram bot"
    echo "  2. Run 'sudo tailscale up' to connect to your tailnet"
    echo "  3. Use 'xclaude', 'xcodex', 'xamp' for sandboxless AI tool execution"
    echo "  4. Use 'alertme' and 'promptme' for notifications"
    echo "  5. Use 'ralph2' for autonomous agent loops"
    echo "  6. Use 'ralphsetup <directory>' to initialize ralph2 in a project"
    echo ""
}

main "$@"
