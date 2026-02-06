#!/bin/bash
# hive init - Initialize this machine as a hive manager
# Sets up telegram bot, config directory, and worker registry

set -e

HIVE_DIR="${HIVE_DIR:-/etc/agent-setup}"
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

# Check root for system config
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root (use sudo)"
    exit 1
fi

# Create directory structure
mkdir -p "$HIVE_DIR"
mkdir -p "$HIVE_DIR/pending_prompts"

# Initialize manager config
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

# Initialize workers registry
if [ ! -f "$WORKERS_FILE" ]; then
    echo '{"workers":{}}' | jq '.' > "$WORKERS_FILE"
    echo -e "${GREEN}[OK]${NC} Workers registry created"
else
    WORKER_COUNT=$(jq '.workers | length' "$WORKERS_FILE")
    echo -e "${YELLOW}[SKIP]${NC} Workers registry exists ($WORKER_COUNT workers)"
fi

# Set up telegram bot
echo ""
echo -e "${BLUE}Setting up Telegram bot...${NC}"
echo "The bot will be shared with all workers for notifications."
echo ""
bash "$HIVE_DIR/tools/telegram-bot/tgsetup"

echo ""
echo -e "${CYAN}"
echo "========================================"
echo "  Hive Manager Ready"
echo "========================================"
echo -e "${NC}"
echo ""
echo "Next steps:"
echo "  hive worker setup <host> --name <name>  # Set up a worker"
echo "  hive worker add <name>                  # Register an existing worker"
echo "  hive worker ls                          # List workers"
echo ""
