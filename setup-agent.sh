#!/bin/bash
# Setup Agent - Set up this machine as a hive worker
# Installs AI tools, development environment, desktop, and agent tooling
#
# Usage: sudo ./setup-agent.sh

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

# ---- System ----

update_system() {
    log_info "Updating system packages..."
    apt-get update -y
    apt-get upgrade -y
    log_success "System packages updated"
}

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

install_python() {
    log_info "Installing Python 3 and pip..."
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
    log_success "Python 3 and pip installed"
}

install_nodejs() {
    log_info "Installing nvm and Node.js 24..."
    export NVM_DIR="/usr/local/nvm"
    mkdir -p "$NVM_DIR"

    if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | NVM_DIR="$NVM_DIR" bash
    fi

    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    nvm install 24
    nvm use 24
    nvm alias default 24

    NODE_PATH=$(nvm which 24)
    NODE_DIR=$(dirname "$NODE_PATH")
    ln -sf "$NODE_PATH" /usr/local/bin/node
    ln -sf "$NODE_DIR/npm" /usr/local/bin/npm
    ln -sf "$NODE_DIR/npx" /usr/local/bin/npx

    cat > /etc/profile.d/nvm.sh << 'NVMEOF'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
NVMEOF
    chmod +x /etc/profile.d/nvm.sh

    log_success "Node.js 24 installed ($(node --version))"
}

# ---- AI Tools ----

install_claude_code() {
    log_info "Installing Claude Code..."
    if ! command -v claude &> /dev/null; then
        npm install -g @anthropic-ai/claude-code
        log_success "Claude Code installed"
    else
        log_info "Claude Code already installed"
    fi
}

install_codex() {
    log_info "Installing Codex CLI..."
    if ! command -v codex &> /dev/null; then
        npm install -g @openai/codex
        log_success "Codex installed"
    else
        log_info "Codex already installed"
    fi
}

install_amp() {
    log_info "Installing Amp..."
    if ! command -v amp &> /dev/null; then
        npm install -g @anthropic-ai/amp
        log_success "Amp installed"
    else
        log_info "Amp already installed"
    fi
}

setup_aliases() {
    log_info "Setting up sandboxless wrappers..."

    cat > "$BIN_DIR/xclaude" << 'EOF'
#!/bin/bash
exec claude --dangerously-skip-permissions "$@"
EOF
    chmod +x "$BIN_DIR/xclaude"

    cat > "$BIN_DIR/xcodex" << 'EOF'
#!/bin/bash
exec codex --dangerously-bypass-approvals-and-sandbox -m "gpt-5.2-codex xhigh" "$@"
EOF
    chmod +x "$BIN_DIR/xcodex"

    cat > "$BIN_DIR/xamp" << 'EOF'
#!/bin/bash
exec amp --dangerously-allow-all "$@"
EOF
    chmod +x "$BIN_DIR/xamp"

    log_success "Wrappers created: xclaude, xcodex, xamp"
}

# ---- Development Environment ----

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

install_tailscale() {
    log_info "Installing Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale installed"
    else
        log_info "Tailscale already installed"
    fi
}

configure_firewall() {
    log_info "Configuring UFW firewall..."
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    ufw allow ssh
    ufw allow from 100.64.0.0/10 to any port 4000 proto tcp
    ufw allow from 100.64.0.0/10 to any port 4000 proto udp
    ufw deny 4000
    ufw --force enable
    log_success "UFW configured: NoMachine restricted to Tailscale"
}

install_cinnamon() {
    log_info "Installing Cinnamon desktop environment..."
    apt-get install -y cinnamon-desktop-environment lightdm
    systemctl set-default graphical.target
    log_success "Cinnamon desktop installed"
}

# ---- Agent Tools ----

install_tools() {
    log_info "Installing hive tools..."
    mkdir -p "$CONFIG_DIR/tools"

    # Install hive subcommands and agent tools (no repo-transfer on worker)
    cp -r "$SCRIPT_DIR/tools/hive" "$CONFIG_DIR/tools/"
    cp -r "$SCRIPT_DIR/tools/ralph2" "$CONFIG_DIR/tools/"
    cp -r "$SCRIPT_DIR/tools/telegram-bot" "$CONFIG_DIR/tools/"

    chmod +x "$CONFIG_DIR/tools/ralph2/ralph2.sh"
    chmod +x "$CONFIG_DIR/tools/ralph2/ralphsetup"

    log_success "Tools installed to $CONFIG_DIR/tools/"
}

install_hive() {
    log_info "Installing hive CLI..."
    cp "$SCRIPT_DIR/hive" "$BIN_DIR/hive"
    chmod +x "$BIN_DIR/hive"
    log_success "hive installed to $BIN_DIR/hive"
}

setup_telegram_bot() {
    log_info "Setting up Telegram bot service..."
    mkdir -p "$CONFIG_DIR/pending_prompts"

    cp "$SCRIPT_DIR/tools/telegram-bot/agent_telegram_bot.py" "$CONFIG_DIR/"

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

    python3 -m venv "$CONFIG_DIR/venv"
    "$CONFIG_DIR/venv/bin/pip" install python-telegram-bot aiofiles

    cp "$SCRIPT_DIR/tools/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
    systemctl daemon-reload

    log_success "Telegram bot service configured"
}

install_ralph2() {
    log_info "Installing ralph2..."
    mkdir -p "$CONFIG_DIR/ralph2"
    mkdir -p "$CONFIG_DIR/ralph2/skills/prd"
    mkdir -p "$CONFIG_DIR/ralph2/skills/ralph"

    cp "$SCRIPT_DIR/tools/ralph2/ralph2.sh" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/tools/ralph2/prompt.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/tools/ralph2/CLAUDE.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/tools/ralph2/AGENTS.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/tools/ralph2/CODEX.md" "$CONFIG_DIR/ralph2/"
    cp "$SCRIPT_DIR/tools/ralph2/prd.json.example" "$CONFIG_DIR/ralph2/"

    if [ -d "$SCRIPT_DIR/tools/ralph2/skills" ]; then
        cp -r "$SCRIPT_DIR/tools/ralph2/skills/"* "$CONFIG_DIR/ralph2/skills/"
    fi

    chmod +x "$CONFIG_DIR/ralph2/ralph2.sh"
    log_success "ralph2 installed"
}

# ---- Main ----

main() {
    check_root

    echo "========================================"
    echo "  Hive Agent (Worker) Setup"
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
    setup_aliases

    echo ""
    log_info "Installing development environment..."
    install_vscode
    install_nomachine
    install_tailscale
    configure_firewall
    install_cinnamon

    echo ""
    log_info "Installing agent tools..."
    install_tools
    install_hive
    setup_telegram_bot
    install_ralph2

    echo ""
    echo "========================================"
    log_success "Agent setup complete!"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. sudo tailscale up              # Connect to tailnet"
    echo "  2. Use xclaude, xcodex, xamp      # Sandboxless AI tools"
    echo "  3. hive ralph2 --status            # Check ralph2"
    echo "  4. hive alertme -t 'Hello'         # Test Telegram (if configured)"
    echo ""
}

main "$@"
