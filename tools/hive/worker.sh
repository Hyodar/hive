#!/bin/bash
# hive worker - Manage worker machines
# Subcommands: setup, add, ls, rm, set, ssh

set -e

HIVE_DIR="${HIVE_DIR:-$HOME/.hive}"
WORKERS_FILE="$HIVE_DIR/workers.json"
HIVE_SSH_DIR="$HIVE_DIR/ssh"

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

# Resolve SSH identity for a worker: per-worker quick-ssh key > configured ssh_key > default
resolve_worker_ssh_id() {
    local NAME="$1"
    local HIVE_KEY="$HIVE_SSH_DIR/${NAME}_ed25519"
    if [ -f "$HIVE_KEY" ]; then
        echo "-i $HIVE_KEY"
        return
    fi
    if [ -f "$WORKERS_FILE" ]; then
        local SSH_KEY
        SSH_KEY=$(jq -r --arg name "$NAME" '.workers[$name].ssh_key // empty' "$WORKERS_FILE" 2>/dev/null)
        if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
            echo "-i $SSH_KEY"
            return
        fi
    fi
}

# ---- hive worker add ----
worker_add() {
    local NAME=""
    local HOST=""
    local SSH_KEY=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --host) HOST="$2"; shift 2 ;;
            --ssh-key) SSH_KEY="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: hive worker add <name> [--host <host>] [--ssh-key <path>]"
                echo ""
                echo "Register a worker without running setup."
                echo "Name should match the machine's Tailscale name."
                echo "Host defaults to the name (for Tailscale DNS)."
                echo "SSH key is stored and used for all SSH operations to this worker."
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
        echo "Usage: hive worker add <name> [--host <host>] [--ssh-key <path>]"
        exit 1
    fi

    ensure_workers_file

    HOST="${HOST:-$NAME}"

    if jq -e ".workers[\"$NAME\"]" "$WORKERS_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} Worker '$NAME' is already registered"
        return 0
    fi

    local ADDED=$(date -Iseconds)
    local tmp
    tmp=$(mktemp)
    if [ -n "$SSH_KEY" ]; then
        jq --arg name "$NAME" --arg host "$HOST" --arg added "$ADDED" --arg ssh_key "$SSH_KEY" \
            '.workers[$name] = {"host": $host, "name": $name, "added": $added, "ssh_key": $ssh_key}' \
            "$WORKERS_FILE" > "$tmp"
    else
        jq --arg name "$NAME" --arg host "$HOST" --arg added "$ADDED" \
            '.workers[$name] = {"host": $host, "name": $name, "added": $added}' \
            "$WORKERS_FILE" > "$tmp"
    fi
    cat "$tmp" > "$WORKERS_FILE"
    rm -f "$tmp"

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

    local tmp
    tmp=$(mktemp)
    jq --arg name "$NAME" 'del(.workers[$name])' "$WORKERS_FILE" > "$tmp"
    cat "$tmp" > "$WORKERS_FILE"
    rm -f "$tmp"

    echo -e "${GREEN}[OK]${NC} Worker '$NAME' removed"
}

# ---- hive worker set quick-ssh ----
worker_set_quick_ssh() {
    local WORKER=""
    local ENABLE=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) WORKER="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: hive worker set quick-ssh --name <worker> <true|false>"
                echo ""
                echo "Set up or remove passwordless SSH to a worker."
                echo "  true   Generate a quick-ssh key and copy it to the worker"
                echo "  false  Remove the quick-ssh key locally and from the worker"
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            true|false)
                ENABLE="$1"; shift ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}"; exit 1 ;;
        esac
    done

    if [ -z "$WORKER" ] || [ -z "$ENABLE" ]; then
        echo -e "${RED}[ERROR]${NC} Both --name and true/false are required"
        echo "Usage: hive worker set quick-ssh --name <worker> <true|false>"
        exit 1
    fi

    ensure_workers_file

    local HOST
    HOST=$(jq -r --arg name "$WORKER" '.workers[$name].host // empty' "$WORKERS_FILE" 2>/dev/null)
    if [ -z "$HOST" ]; then
        echo -e "${RED}[ERROR]${NC} Worker '$WORKER' not found"
        exit 1
    fi

    local HIVE_KEY="$HIVE_SSH_DIR/${WORKER}_ed25519"

    if [ "$ENABLE" = "true" ]; then
        # Generate per-worker quick-ssh key if it doesn't exist
        if [ ! -f "$HIVE_KEY" ]; then
            echo -e "${BLUE}Generating quick-ssh key ($HIVE_KEY)...${NC}"
            mkdir -p "$HIVE_SSH_DIR"
            ssh-keygen -t ed25519 -N "" -f "$HIVE_KEY" -C "hive-$WORKER"
            echo -e "${GREEN}[OK]${NC} Key generated: $HIVE_KEY"
        else
            echo -e "${BLUE}Using existing quick-ssh key: $HIVE_KEY${NC}"
        fi

        # Use the worker's configured ssh_key (if any) to authenticate for ssh-copy-id
        local BASE_SSH_ID=""
        local WORKER_SSH_KEY
        WORKER_SSH_KEY=$(jq -r --arg name "$WORKER" '.workers[$name].ssh_key // empty' "$WORKERS_FILE" 2>/dev/null)
        if [ -n "$WORKER_SSH_KEY" ] && [ -f "$WORKER_SSH_KEY" ]; then
            BASE_SSH_ID="-o IdentityFile=$WORKER_SSH_KEY"
        fi

        # Copy quick-ssh key to worker
        echo -e "${BLUE}Copying key to worker '$WORKER' ($HOST)...${NC}"
        ssh-copy-id $BASE_SSH_ID -i "$HIVE_KEY" "$HOST"

        echo ""
        echo -e "${GREEN}[OK]${NC} Quick SSH configured for worker '$WORKER'"
        echo "All SSH commands to this worker will now be passwordless."
    else
        # --- Disable quick-ssh ---
        if [ ! -f "$HIVE_KEY" ]; then
            echo -e "${YELLOW}[WARN]${NC} No quick-ssh key found for worker '$WORKER'"
            return 0
        fi

        # Remove from remote authorized_keys
        if [ -f "$HIVE_KEY.pub" ]; then
            local PUB_KEY_DATA
            PUB_KEY_DATA=$(awk '{print $2}' "$HIVE_KEY.pub")

            # Use the quick-ssh key itself (still valid) to connect and remove it
            echo -e "${BLUE}Removing key from worker '$WORKER' ($HOST)...${NC}"
            ssh -i "$HIVE_KEY" "$HOST" "
                if [ -f ~/.ssh/authorized_keys ]; then
                    grep -vF '$PUB_KEY_DATA' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp
                    mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
                fi
            " 2>/dev/null || {
                echo -e "${YELLOW}[WARN]${NC} Could not remove key from remote (worker may be unreachable)"
            }
        fi

        # Delete local key files
        rm -f "$HIVE_KEY" "$HIVE_KEY.pub"
        echo -e "${GREEN}[OK]${NC} Quick SSH disabled for worker '$WORKER'"
    fi
}

# ---- hive worker setup ----
worker_setup() {
    local HOST=""
    local NAME=""
    local PASSWORD=""
    local TAILSCALE_KEY=""
    local NO_DESKTOP=false
    local SSH_KEY=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) NAME="$2"; shift 2 ;;
            --password) PASSWORD="$2"; shift 2 ;;
            --tailscale-key) TAILSCALE_KEY="$2"; shift 2 ;;
            --no-desktop) NO_DESKTOP=true; shift ;;
            --ssh-key) SSH_KEY="$2"; shift 2 ;;
            --help|-h)
                cat <<EOF
Usage: hive worker setup <host> --name <name> [options]

Set up a remote machine as a hive worker via SSH.

Arguments:
  host              SSH host (IP address, hostname, or user@host)
  --name            Tailscale machine name for this worker (also sets hostname)
  --password        Password for the 'worker' user (default: SSH key only)
  --tailscale-key   Tailscale auth key for non-interactive setup
  --no-desktop      Skip NoMachine, Cinnamon, and VSCode (CLI-only worker)
  --ssh-key         SSH key to use for accessing this machine (stored in metadata)

This will:
  1. Install git on the remote machine
  2. Send the agent-setup repo via git bundle
  3. Run the full worker installation (AI tools, desktop, etc.)
     - Sets hostname to the given name
     - Creates a 'worker' sudo user (NOPASSWD)
     - Copies SSH keys to the worker user
  4. Copy Telegram config from this manager
  5. Register the worker (SSH via worker@<name>)
  6. Open an interactive SSH session for final config (tailscale up)
     (skipped when --tailscale-key is provided)
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
        echo "Usage: hive worker setup <host> --name <name> [options]"
        exit 1
    fi

    ensure_workers_file

    # Resolve SSH identity: --ssh-key flag for setup
    local SETUP_SSH_ID=""
    [ -n "$SSH_KEY" ] && SETUP_SSH_ID="-i $SSH_KEY"

    echo -e "${CYAN}"
    echo "========================================"
    echo "  Hive Worker Setup: $NAME"
    echo "========================================"
    echo -e "${NC}"
    echo "  Host:      $HOST"
    echo "  Name:      $NAME"
    echo "  Hostname:  will be set to '$NAME'"
    echo "  User:      'worker' (sudo, NOPASSWD)"
    if [ -n "$PASSWORD" ]; then
        echo "  Password:  (custom)"
    else
        echo "  Password:  (none, SSH key only)"
    fi
    if [ -n "$TAILSCALE_KEY" ]; then
        echo "  Tailscale: auto-auth (key provided)"
    else
        echo "  Tailscale: manual (interactive SSH at end)"
    fi
    if [ "$NO_DESKTOP" = true ]; then
        echo "  Desktop:   none (CLI-only)"
    else
        echo "  Desktop:   Cinnamon + NoMachine"
    fi
    if [ -n "$SSH_KEY" ]; then
        echo "  SSH key:   $SSH_KEY"
    fi
    echo ""
    if [ -z "$TAILSCALE_KEY" ]; then
        echo -e "${YELLOW}[IMPORTANT]${NC} Use '${NAME}' as this machine's"
        echo "Tailscale name when you run 'tailscale up' later."
        echo ""
    fi
    read -p "Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        exit 0
    fi

    # Find the agent-setup repo
    REPO_DIR=""
    if [ -f "$HIVE_DIR/.source_repo" ]; then
        REPO_DIR=$(cat "$HIVE_DIR/.source_repo")
    fi
    if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
        echo -e "${RED}[ERROR]${NC} Cannot find agent-setup repo."
        echo "Run 'hive init' first."
        exit 1
    fi

    echo ""
    echo -e "${BLUE}[1/6]${NC} Installing git on remote..."
    ssh $SETUP_SSH_ID "$HOST" "apt-get update -qq && apt-get install -y -qq git" 2>/dev/null || {
        echo -e "${YELLOW}[WARN]${NC} Could not install git (may need sudo or already installed)"
    }

    echo -e "${BLUE}[2/6]${NC} Sending agent-setup repo..."
    BUNDLE_FILE=$(mktemp /tmp/agent-setup-XXXXXX.bundle)
    trap "rm -f '$BUNDLE_FILE'" EXIT
    git -C "$REPO_DIR" bundle create "$BUNDLE_FILE" --all -- 2>/dev/null
    scp $SETUP_SSH_ID -q "$BUNDLE_FILE" "$HOST:/tmp/agent-setup.bundle"
    ssh $SETUP_SSH_ID "$HOST" "rm -rf ~/agent-setup && git clone /tmp/agent-setup.bundle ~/agent-setup && rm -f /tmp/agent-setup.bundle"

    echo -e "${BLUE}[3/6]${NC} Running worker installation..."
    INSTALL_ARGS="--name '$NAME'"
    if [ -n "$PASSWORD" ]; then
        INSTALL_ARGS="$INSTALL_ARGS --password '$PASSWORD'"
    fi
    if [ -n "$TAILSCALE_KEY" ]; then
        INSTALL_ARGS="$INSTALL_ARGS --tailscale-key '$TAILSCALE_KEY'"
    fi
    if [ "$NO_DESKTOP" = true ]; then
        INSTALL_ARGS="$INSTALL_ARGS --no-desktop"
    fi
    ssh $SETUP_SSH_ID -t "$HOST" "cd ~/agent-setup && sudo bash tools/hive/install-worker.sh $INSTALL_ARGS"

    echo -e "${BLUE}[4/6]${NC} Copying Telegram config..."
    TG_CONFIG="$HIVE_DIR/telegram_config.json"
    if [ -f "$TG_CONFIG" ]; then
        scp $SETUP_SSH_ID -q "$TG_CONFIG" "$HOST:/etc/hive/telegram_config.json"
        ssh $SETUP_SSH_ID "$HOST" "systemctl restart agent-telegram-bot 2>/dev/null || true"
        echo -e "${GREEN}[OK]${NC} Telegram config copied"
    else
        echo -e "${YELLOW}[WARN]${NC} No Telegram config found. Run 'hive init' first."
    fi

    echo -e "${BLUE}[5/6]${NC} Registering worker..."
    if [ -n "$SSH_KEY" ]; then
        worker_add "$NAME" --host "worker@$NAME" --ssh-key "$SSH_KEY"
    else
        worker_add "$NAME" --host "worker@$NAME"
    fi

    echo -e "${BLUE}[6/6]${NC} Setup complete!"
    echo ""
    echo -e "${GREEN}========================================"
    echo "  Worker '$NAME' is ready"
    echo "========================================"
    echo -e "${NC}"

    if [ -n "$TAILSCALE_KEY" ]; then
        echo "Tailscale is connected. Worker is fully configured."
        echo ""
        echo "Connect with:  hive worker ssh $NAME"
    else
        echo "Opening SSH session for final configuration."
        echo "You should run:"
        echo "  sudo tailscale up --hostname=$NAME    # Connect to tailnet"
        echo "  exit                                  # When done"
        echo ""
        echo -e "${BLUE}Connecting as worker@...${NC}"
        # SSH as worker user to the original host to run tailscale up
        BARE_HOST="${HOST#*@}"
        ssh $SETUP_SSH_ID -t "worker@$BARE_HOST" || true
    fi
}

# ---- Route subcommand ----
SUBCMD="${1:-}"
shift 2>/dev/null || true

case "$SUBCMD" in
    setup)   worker_setup "$@" ;;
    add)     worker_add "$@" ;;
    ls|list) worker_ls "$@" ;;
    rm|remove) worker_rm "$@" ;;
    set)
        SET_SUBCMD="${1:-}"
        shift 2>/dev/null || true
        case "$SET_SUBCMD" in
            quick-ssh) worker_set_quick_ssh "$@" ;;
            --help|-h|help|"")
                echo "Usage: hive worker set <setting>"
                echo ""
                echo "Settings:"
                echo "  quick-ssh --name <worker> <true|false>"
                ;;
            *)
                echo -e "${RED}Unknown setting: $SET_SUBCMD${NC}"
                echo "Run 'hive worker set help' for usage"
                exit 1
                ;;
        esac
        ;;
    ssh)
        WORKER="${1:-}"
        if [ -z "$WORKER" ]; then
            echo -e "${RED}Usage: hive worker ssh <name>${NC}"
            exit 1
        fi
        ensure_workers_file
        SSH_TARGET=$(jq -r --arg name "$WORKER" '.workers[$name].host // empty' "$WORKERS_FILE" 2>/dev/null)
        SSH_TARGET="${SSH_TARGET:-$WORKER}"
        WORKER_SSH_ID=$(resolve_worker_ssh_id "$WORKER")
        exec ssh $WORKER_SSH_ID -t "$SSH_TARGET"
        ;;
    --help|-h|help)
        echo "Usage: hive worker <command>"
        echo ""
        echo "Commands:"
        echo "  setup <host> --name <name>          Set up a remote worker via SSH"
        echo "  add <name> [--host <host>]          Register a worker without setup"
        echo "  ls                                  List registered workers"
        echo "  rm <name>                           Remove a worker from registry"
        echo "  set quick-ssh --name <n> true|false Set up or remove passwordless SSH"
        echo "  ssh <name>                          SSH into a worker"
        ;;
    *)
        echo -e "${RED}Unknown worker command: ${SUBCMD:-<none>}${NC}"
        echo "Run 'hive worker help' for usage"
        exit 1
        ;;
esac
