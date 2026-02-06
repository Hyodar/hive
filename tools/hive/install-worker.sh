#!/bin/bash
# install-worker.sh - Internal script run ON the worker during hive worker setup
# Not a user-facing command. Called by worker.sh via SSH.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="/etc/hive"
BIN_DIR="/usr/local/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root (use sudo)"
    exit 1
fi

# Parse arguments
WORKER_NAME=""
WORKER_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --name) WORKER_NAME="$2"; shift 2 ;;
        --password) WORKER_PASSWORD="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "========================================"
echo "  Hive Worker Installation"
echo "========================================"
echo ""

# ---- Hostname ----

if [ -n "$WORKER_NAME" ]; then
    log_info "Setting hostname to '$WORKER_NAME'..."
    hostnamectl set-hostname "$WORKER_NAME"
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t$WORKER_NAME/" /etc/hosts
    else
        echo "127.0.1.1	$WORKER_NAME" >> /etc/hosts
    fi
    log_success "Hostname: $WORKER_NAME"
fi

# ---- Worker user ----

log_info "Setting up 'worker' user..."
if ! id worker &>/dev/null; then
    useradd -m -s /bin/bash worker
fi
usermod -aG sudo worker

if [ -n "$WORKER_PASSWORD" ]; then
    echo "worker:$WORKER_PASSWORD" | chpasswd
    log_success "'worker' user created (password set)"
else
    passwd -l worker 2>/dev/null || true
    log_success "'worker' user created (no password, SSH key auth only)"
fi

# NOPASSWD sudo
echo "worker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/worker
chmod 440 /etc/sudoers.d/worker

# Copy SSH authorized_keys from the setup user
SETUP_USER="${SUDO_USER:-root}"
if [ "$SETUP_USER" = "root" ]; then
    SETUP_HOME="/root"
else
    SETUP_HOME=$(getent passwd "$SETUP_USER" | cut -d: -f6)
fi
if [ -f "$SETUP_HOME/.ssh/authorized_keys" ]; then
    mkdir -p /home/worker/.ssh
    cp "$SETUP_HOME/.ssh/authorized_keys" /home/worker/.ssh/authorized_keys
    chown -R worker:worker /home/worker/.ssh
    chmod 700 /home/worker/.ssh
    chmod 600 /home/worker/.ssh/authorized_keys
    log_success "SSH keys copied to worker user"
else
    log_info "No SSH authorized_keys found for '$SETUP_USER' — configure manually"
fi

# ---- System ----

log_info "Updating system..."
apt-get update -y
apt-get upgrade -y

log_info "Installing dependencies..."
apt-get install -y \
    curl wget git jq gnupg apt-transport-https ca-certificates \
    software-properties-common unzip build-essential netcat-openbsd

log_info "Installing Python 3..."
apt-get install -y python3 python3-pip python3-venv python3-dev
apt-get install -y python3-full 2>/dev/null || true
if ! command -v pip3 &> /dev/null; then
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    python3 /tmp/get-pip.py --break-system-packages
    rm /tmp/get-pip.py
fi
log_success "Python 3"

log_info "Installing Node.js 24..."
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
log_success "Node.js $(node --version)"

# ---- AI Tools ----

log_info "Installing AI coding tools..."
command -v claude &>/dev/null || npm install -g @anthropic-ai/claude-code
command -v codex &>/dev/null || npm install -g @openai/codex
command -v amp &>/dev/null || npm install -g @anthropic-ai/amp
log_success "claude, codex, amp"

log_info "Creating sandboxless wrappers..."
cat > "$BIN_DIR/xclaude" << 'EOF'
#!/bin/bash
exec claude --dangerously-skip-permissions "$@"
EOF
cat > "$BIN_DIR/xcodex" << 'EOF'
#!/bin/bash
exec codex --dangerously-bypass-approvals-and-sandbox -m "gpt-5.2-codex xhigh" "$@"
EOF
cat > "$BIN_DIR/xamp" << 'EOF'
#!/bin/bash
exec amp --dangerously-allow-all "$@"
EOF
chmod +x "$BIN_DIR/xclaude" "$BIN_DIR/xcodex" "$BIN_DIR/xamp"
log_success "xclaude, xcodex, xamp"

# ---- Desktop & Remote Access ----

log_info "Installing VSCode..."
if ! command -v code &>/dev/null; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
    install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
    rm -f /tmp/packages.microsoft.gpg
    apt-get update
    apt-get install -y code
fi
log_success "VSCode"

log_info "Installing NoMachine..."
if ! command -v nxserver &>/dev/null; then
    ARCH=$(dpkg --print-architecture)
    [ "$ARCH" = "amd64" ] && NM_ARCH="amd64" || NM_ARCH="arm64"
    wget -q "https://download.nomachine.com/download/8.14/Linux/nomachine_8.14.2_1_${NM_ARCH}.deb" -O /tmp/nomachine.deb
    apt-get install -y /tmp/nomachine.deb
    rm /tmp/nomachine.deb
fi
log_success "NoMachine"

log_info "Installing Tailscale..."
command -v tailscale &>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
log_success "Tailscale"

log_info "Configuring firewall..."
command -v ufw &>/dev/null || apt-get install -y ufw
ufw allow ssh
ufw allow from 100.64.0.0/10 to any port 4000 proto tcp
ufw allow from 100.64.0.0/10 to any port 4000 proto udp
ufw deny 4000
ufw --force enable
log_success "UFW (NoMachine restricted to Tailscale)"

log_info "Installing Cinnamon desktop..."
apt-get install -y cinnamon-desktop-environment lightdm
systemctl set-default graphical.target
log_success "Cinnamon"

# ---- Agent Tools ----

log_info "Installing agent tools..."
mkdir -p "$CONFIG_DIR/tools"
mkdir -p "$CONFIG_DIR/pending_prompts"
mkdir -p "$CONFIG_DIR/ralph2/skills/prd"
mkdir -p "$CONFIG_DIR/ralph2/skills/ralph"

# Install hive (needed for repo receive)
cp -r "$SCRIPT_DIR/tools/hive" "$CONFIG_DIR/tools/"
cp -r "$SCRIPT_DIR/tools/repo" "$CONFIG_DIR/tools/"
cp "$SCRIPT_DIR/hive" "$BIN_DIR/hive"
chmod +x "$BIN_DIR/hive"

# Ralph2 files
cp "$SCRIPT_DIR/tools/ralph2/ralph2.sh" "$CONFIG_DIR/ralph2/"
cp "$SCRIPT_DIR/tools/ralph2/prompt.md" "$CONFIG_DIR/ralph2/"
cp "$SCRIPT_DIR/tools/ralph2/CLAUDE.md" "$CONFIG_DIR/ralph2/"
cp "$SCRIPT_DIR/tools/ralph2/AGENTS.md" "$CONFIG_DIR/ralph2/"
cp "$SCRIPT_DIR/tools/ralph2/CODEX.md" "$CONFIG_DIR/ralph2/"
cp "$SCRIPT_DIR/tools/ralph2/prd.json.example" "$CONFIG_DIR/ralph2/"
[ -d "$SCRIPT_DIR/tools/ralph2/skills" ] && cp -r "$SCRIPT_DIR/tools/ralph2/skills/"* "$CONFIG_DIR/ralph2/skills/"
chmod +x "$CONFIG_DIR/ralph2/ralph2.sh"

# Standalone commands -> /usr/local/bin/
cat > "$BIN_DIR/ralph2" << EOF
#!/bin/bash
exec "$CONFIG_DIR/ralph2/ralph2.sh" "\$@"
EOF
cp "$SCRIPT_DIR/tools/ralph2/ralphsetup" "$BIN_DIR/ralphsetup"
cp "$SCRIPT_DIR/tools/telegram-bot/alertme" "$BIN_DIR/alertme"
cp "$SCRIPT_DIR/tools/telegram-bot/promptme" "$BIN_DIR/promptme"
cp "$SCRIPT_DIR/tools/telegram-bot/tgsetup" "$BIN_DIR/tgsetup"
chmod +x "$BIN_DIR/ralph2" "$BIN_DIR/ralphsetup" "$BIN_DIR/alertme" "$BIN_DIR/promptme" "$BIN_DIR/tgsetup"

# Telegram bot service
cp "$SCRIPT_DIR/tools/telegram-bot/agent_telegram_bot.py" "$CONFIG_DIR/"
python3 -m venv "$CONFIG_DIR/venv"
"$CONFIG_DIR/venv/bin/pip" install -q python-telegram-bot aiofiles
cp "$SCRIPT_DIR/tools/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
systemctl daemon-reload

log_success "All agent tools installed"

echo ""
echo "========================================"
log_success "Worker installation complete!"
echo "========================================"
echo ""
