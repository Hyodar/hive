#!/bin/bash
# hive worker - Manage worker machines
# Subcommands: setup, add, ls, rm

set -e

HIVE_DIR="${HIVE_DIR:-/etc/agent-setup}"
WORKERS_FILE="$HIVE_DIR/workers.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ensure_workers_file() {
    if [ ! -f "$WORKERS_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} Workers registry not found. Run 'hive init' first."
        exit 1
    fi
}

# ---- hive worker add ----
worker_add() {
    local NAME=""
    local HOST=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --host) HOST="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: hive worker add <name> [--host <host>]"
                echo ""
                echo "Register a worker without running setup."
                echo "Name should match the machine's Tailscale name."
                echo "Host defaults to the name (for Tailscale DNS)."
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *)
                if [ -z "$NAME" ]; then NAME="$1"
                else echo -e "${RED}Too many arguments${NC}"; exit 1
                fi
                shift ;;
        esac
    done

    if [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} Worker name is required"
        echo "Usage: hive worker add <name> [--host <host>]"
        exit 1
    fi

    ensure_workers_file

    # Default host to name (Tailscale DNS)
    HOST="${HOST:-$NAME}"

    # Check if already registered
    if jq -e ".workers[\"$NAME\"]" "$WORKERS_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} Worker '$NAME' is already registered"
        return 0
    fi

    # Register
    local ADDED=$(date -Iseconds)
    jq --arg name "$NAME" --arg host "$HOST" --arg added "$ADDED" \
        '.workers[$name] = {"host": $host, "name": $name, "added": $added}' \
        "$WORKERS_FILE" > "$WORKERS_FILE.tmp"
    mv "$WORKERS_FILE.tmp" "$WORKERS_FILE"

    echo -e "${GREEN}[OK]${NC} Worker '$NAME' registered (host: $HOST)"
}

# ---- hive worker ls ----
worker_ls() {
    ensure_workers_file

    local COUNT=$(jq '.workers | length' "$WORKERS_FILE")

    if [ "$COUNT" -eq 0 ]; then
        echo "No workers registered."
        echo "Use 'hive worker add <name>' or 'hive worker setup <host> --name <name>'"
        return 0
    fi

    echo -e "${CYAN}Registered workers ($COUNT):${NC}"
    echo ""
    printf "  %-20s %-30s %s\n" "NAME" "HOST" "ADDED"
    printf "  %-20s %-30s %s\n" "----" "----" "-----"
    jq -r '.workers | to_entries[] | "  \(.value.name)\t\(.value.host)\t\(.value.added)"' "$WORKERS_FILE" \
        | while IFS=$'\t' read -r name host added; do
            printf "  %-20s %-30s %s\n" "$name" "$host" "$added"
        done
    echo ""
}

# ---- hive worker rm ----
worker_rm() {
    local NAME="$1"

    if [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} Worker name is required"
        echo "Usage: hive worker rm <name>"
        exit 1
    fi

    ensure_workers_file

    if ! jq -e ".workers[\"$NAME\"]" "$WORKERS_FILE" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Worker '$NAME' not found"
        exit 1
    fi

    jq --arg name "$NAME" 'del(.workers[$name])' "$WORKERS_FILE" > "$WORKERS_FILE.tmp"
    mv "$WORKERS_FILE.tmp" "$WORKERS_FILE"

    echo -e "${GREEN}[OK]${NC} Worker '$NAME' removed"
}

# ---- hive worker setup ----
worker_setup() {
    local HOST=""
    local NAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) NAME="$2"; shift 2 ;;
            --help|-h)
                cat <<EOF
Usage: hive worker setup <host> --name <name>

Set up a remote machine as a hive worker via SSH.

Arguments:
  host    SSH host (IP address, hostname, or user@host)
  --name  Tailscale machine name for this worker

This will:
  1. Install git on the remote machine
  2. Send the agent-setup repo via bundle
  3. Run the agent setup script
  4. Copy Telegram config from manager
  5. Register the worker
  6. Open an interactive SSH session for final config
EOF
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *)
                if [ -z "$HOST" ]; then HOST="$1"
                else echo -e "${RED}Too many arguments${NC}"; exit 1
                fi
                shift ;;
        esac
    done

    if [ -z "$HOST" ] || [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} Both host and --name are required"
        echo "Usage: hive worker setup <host> --name <name>"
        exit 1
    fi

    ensure_workers_file

    echo -e "${CYAN}"
    echo "========================================"
    echo "  Hive Worker Setup: $NAME"
    echo "========================================"
    echo -e "${NC}"
    echo "  Host:      $HOST"
    echo "  Name:      $NAME"
    echo ""
    echo -e "${YELLOW}[IMPORTANT]${NC} Make sure '${NAME}' will be this machine's"
    echo "Tailscale name when you run 'tailscale up' later."
    echo ""
    read -p "Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        exit 0
    fi

    # Find the agent-setup repo root (where hive was installed from)
    REPO_DIR=""
    # Check if we have a source marker
    if [ -f "$HIVE_DIR/.source_repo" ]; then
        REPO_DIR=$(cat "$HIVE_DIR/.source_repo")
    fi
    if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
        echo -e "${RED}[ERROR]${NC} Cannot find agent-setup repo source."
        echo "Make sure .source_repo is set in $HIVE_DIR/"
        exit 1
    fi

    echo ""
    echo -e "${BLUE}[1/6]${NC} Installing git on remote..."
    ssh "$HOST" "apt-get update -qq && apt-get install -y -qq git" 2>/dev/null || {
        echo -e "${YELLOW}[WARN]${NC} Could not install git (may need sudo or already installed)"
    }

    echo -e "${BLUE}[2/6]${NC} Sending agent-setup repo..."
    BUNDLE_FILE=$(mktemp /tmp/agent-setup-XXXXXX.bundle)
    trap "rm -f '$BUNDLE_FILE'" EXIT
    git -C "$REPO_DIR" bundle create "$BUNDLE_FILE" --all -- 2>/dev/null
    scp -q "$BUNDLE_FILE" "$HOST:/tmp/agent-setup.bundle"
    ssh "$HOST" "rm -rf ~/agent-setup && git clone /tmp/agent-setup.bundle ~/agent-setup && rm -f /tmp/agent-setup.bundle"

    echo -e "${BLUE}[3/6]${NC} Running agent setup (interactive)..."
    ssh -t "$HOST" "cd ~/agent-setup && sudo ./setup-agent.sh"

    echo -e "${BLUE}[4/6]${NC} Copying Telegram config..."
    TG_CONFIG="$HIVE_DIR/telegram_config.json"
    if [ -f "$TG_CONFIG" ]; then
        scp -q "$TG_CONFIG" "$HOST:/etc/agent-setup/telegram_config.json"
        # Restart telegram bot on worker to pick up config
        ssh "$HOST" "systemctl restart agent-telegram-bot 2>/dev/null || true"
        echo -e "${GREEN}[OK]${NC} Telegram config copied"
    else
        echo -e "${YELLOW}[WARN]${NC} No Telegram config found. Run 'hive init' on manager first."
    fi

    echo -e "${BLUE}[5/6]${NC} Registering worker..."
    worker_add "$NAME" --host "$HOST"

    echo -e "${BLUE}[6/6]${NC} Setup complete!"
    echo ""
    echo -e "${GREEN}========================================"
    echo "  Worker '$NAME' is ready"
    echo "========================================"
    echo -e "${NC}"
    echo "Opening SSH session for final configuration."
    echo "You should run:"
    echo "  sudo tailscale up    # Connect to tailnet as '$NAME'"
    echo "  exit                 # When done"
    echo ""
    echo -e "${BLUE}Connecting...${NC}"
    ssh -t "$HOST" || true
}

# ---- Route subcommand ----
SUBCMD="${1:-}"
shift 2>/dev/null || true

case "$SUBCMD" in
    setup)  worker_setup "$@" ;;
    add)    worker_add "$@" ;;
    ls|list) worker_ls "$@" ;;
    rm|remove) worker_rm "$@" ;;
    --help|-h|help)
        echo "Usage: hive worker <command>"
        echo ""
        echo "Commands:"
        echo "  setup <host> --name <name>   Set up a remote worker via SSH"
        echo "  add <name> [--host <host>]   Register a worker without setup"
        echo "  ls                           List registered workers"
        echo "  rm <name>                    Remove a worker from registry"
        ;;
    *)
        echo -e "${RED}Unknown worker command: ${SUBCMD:-<none>}${NC}"
        echo "Run 'hive worker help' for usage"
        exit 1
        ;;
esac
