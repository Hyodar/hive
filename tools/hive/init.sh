#!/bin/bash
# hive init - Initialize this machine as a hive manager
# Creates config, worker registry, sets up Telegram bot, installs hive to PATH

set -e

HIVE_DIR="${HIVE_DIR:-/etc/hive}"
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

# ---- Install hive to PATH ----

echo -e "${BLUE}[1/3]${NC} Installing hive..."
mkdir -p "$HIVE_DIR"

cp "$SCRIPT_DIR/hive" "$BIN_DIR/hive"
chmod +x "$BIN_DIR/hive"

# Record source repo so hive can find tools
echo "$SCRIPT_DIR" > "$HIVE_DIR/.source_repo"

echo -e "${GREEN}[OK]${NC} hive installed to $BIN_DIR/hive"

# ---- Config + registry ----

echo -e "${BLUE}[2/3]${NC} Setting up config..."

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

echo -e "${BLUE}[3/3]${NC} Setting up Telegram bot..."

cp "$SCRIPT_DIR/tools/telegram-bot/agent_telegram_bot.py" "$HIVE_DIR/"

if [ ! -f "$HIVE_DIR/telegram_config.json" ]; then
    cat > "$HIVE_DIR/telegram_config.json" << 'EOF'
{
    "bot_token": "",
    "chat_id": "",
    "bound": false
}
EOF
fi

# Venv for the bot service
if [ ! -d "$HIVE_DIR/venv" ]; then
    python3 -m venv "$HIVE_DIR/venv"
    "$HIVE_DIR/venv/bin/pip" install -q python-telegram-bot aiofiles
    echo -e "${GREEN}[OK]${NC} Python venv created"
else
    echo -e "${YELLOW}[SKIP]${NC} Python venv exists"
fi

cp "$SCRIPT_DIR/tools/telegram-bot/agent-telegram-bot.service" /etc/systemd/system/
systemctl daemon-reload

echo ""
echo "The Telegram bot will be shared with all workers."
echo ""
bash "$SCRIPT_DIR/tools/telegram-bot/tgsetup"

# ---- Done ----

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
echo "  hive repo send <worker> [refspec]        # Send repo to worker"
echo ""
