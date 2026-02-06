#!/bin/bash
# hive init - Initialize this machine as a hive manager
# Sets up Telegram bot, worker registry, and installs hive to PATH

set -e

HIVE_DIR="${HIVE_DIR:-/etc/agent-setup}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="$HIVE_DIR/config.json"
WORKERS_FILE="$HIVE_DIR/workers.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "========================================"
echo "  Hive Manager Initialization"
echo "========================================"
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root (use sudo)"
    exit 1
fi

# ---- Install hive + tools ----

echo -e "${BLUE}[1/4]${NC} Installing hive..."
mkdir -p "$HIVE_DIR/tools"
mkdir -p "$HIVE_DIR/pending_prompts"

# Copy tools to system location
cp -r "$SCRIPT_DIR/tools/hive" "$HIVE_DIR/tools/"
cp -r "$SCRIPT_DIR/tools/telegram-bot" "$HIVE_DIR/tools/"
cp -r "$SCRIPT_DIR/tools/repo-transfer" "$HIVE_DIR/tools/"

# Install hive binary
cp "$SCRIPT_DIR/hive" "$BIN_DIR/hive"
chmod +x "$BIN_DIR/hive"

# Record source repo for worker setup
echo "$SCRIPT_DIR" > "$HIVE_DIR/.source_repo"

echo -e "${GREEN}[OK]${NC} hive installed to $BIN_DIR/hive"

# ---- Config + registry ----

echo -e "${BLUE}[2/4]${NC} Setting up config..."

if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
    "role": "manager",
    "version": "1.0.0"
}
EOF
    echo -e "${GREEN}[OK]${NC} Manager config created"
else
    echo -e "${YELLOW}[SKIP]${NC} Config already exists"
fi

if [ ! -f "$WORKERS_FILE" ]; then
    echo '{"workers":{}}' | jq '.' > "$WORKERS_FILE"
    echo -e "${GREEN}[OK]${NC} Workers registry created"
else
    WORKER_COUNT=$(jq '.workers | length' "$WORKERS_FILE")
    echo -e "${YELLOW}[SKIP]${NC} Workers registry exists ($WORKER_COUNT workers)"
fi

# ---- Telegram bot ----

echo -e "${BLUE}[3/4]${NC} Setting up Telegram bot..."

# Copy bot script
cp "$SCRIPT_DIR/tools/telegram-bot/agent_telegram_bot.py" "$HIVE_DIR/"

# Create default config if not exists
if [ ! -f "$HIVE_DIR/telegram_config.json" ]; then
    cat > "$HIVE_DIR/telegram_config.json" << 'EOF'
{
    "bot_token": "",
    "chat_id": "",
    "binding_phrase": "BIND_AGENT_BOT",
    "bound": false
}
EOF
fi

# Create venv + install deps
if [ ! -d "$HIVE_DIR/venv" ]; then
    python3 -m venv "$HIVE_DIR/venv"
    "$HIVE_DIR/venv/bin/pip" install -q python-telegram-bot aiofiles
    echo -e "${GREEN}[OK]${NC} Python venv created"
else
    echo -e "${YELLOW}[SKIP]${NC} Python venv exists"
fi

# Install systemd service
cp "$SCRIPT_DIR/tools/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
systemctl daemon-reload

echo ""
echo "The Telegram bot will be shared with all workers for notifications."
echo ""
bash "$HIVE_DIR/tools/telegram-bot/tgsetup"

# ---- Done ----

echo -e "${BLUE}[4/4]${NC} Done!"
echo ""
echo -e "${CYAN}"
echo "========================================"
echo "  Hive Manager Ready"
echo "========================================"
echo -e "${NC}"
echo ""
echo "Next steps:"
echo "  hive worker setup <host> --name <name>  # Set up a worker"
echo "  hive worker ls                          # List workers"
echo "  hive repo send <worker> [branch]        # Send repo to worker"
echo ""
