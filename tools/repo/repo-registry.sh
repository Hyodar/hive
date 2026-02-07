#!/bin/bash
# repo-registry.sh - Repo name registry for hive
#
# Source this file to get registry functions, or run directly for add/ls/rm commands.
#
# Registry lives at /etc/hive/repos.json:
# {
#   "repos": {
#     "myapp": { "name": "myapp", "path": "/home/user/myapp", "added": "..." },
#     "myapp-v2": { "name": "myapp-v2", "path": "/home/user/projects/myapp", "added": "..." }
#   }
# }

HIVE_DIR="${HIVE_DIR:-/etc/hive}"
REPOS_FILE="$HIVE_DIR/repos.json"

# Colors (safe to re-declare)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ensure_repos_file() {
    if [ ! -f "$REPOS_FILE" ]; then
        # Auto-create if /etc/hive exists (hive was initialized)
        if [ -d "$HIVE_DIR" ]; then
            echo '{"repos":{}}' | jq '.' > "$REPOS_FILE" 2>/dev/null || {
                echo -e "${RED}[ERROR]${NC} Cannot create repos registry at $REPOS_FILE"
                echo "You may need to run with sudo or run 'hive init' first."
                return 1
            }
        else
            echo -e "${RED}[ERROR]${NC} Hive not initialized. Run 'hive init' first."
            return 1
        fi
    fi
}

# Look up a repo by its local path. Returns the registered name or empty string.
lookup_repo_by_path() {
    local REPO_PATH="$1"
    if [ ! -f "$REPOS_FILE" ]; then
        return
    fi
    jq -r --arg path "$REPO_PATH" \
        '.repos | to_entries[] | select(.value.path == $path) | .key' \
        "$REPOS_FILE" 2>/dev/null | head -1
}

# Check if a repo name is already taken. Returns 0 if taken, 1 if available.
repo_name_taken() {
    local NAME="$1"
    if [ ! -f "$REPOS_FILE" ]; then
        return 1
    fi
    jq -e --arg name "$NAME" '.repos[$name]' "$REPOS_FILE" >/dev/null 2>&1
}

# Register a repo. Writes to repos.json.
register_repo() {
    local NAME="$1"
    local REPO_PATH="$2"
    local ADDED
    ADDED=$(date -Iseconds)
    jq --arg name "$NAME" --arg path "$REPO_PATH" --arg added "$ADDED" \
        '.repos[$name] = {"name": $name, "path": $path, "added": $added}' \
        "$REPOS_FILE" > "$REPOS_FILE.tmp"
    mv "$REPOS_FILE.tmp" "$REPOS_FILE"
}

# Resolve the repo name for the current git repo.
# Auto-registers if not registered. Handles collisions interactively.
# Sets REPO_REGISTERED_NAME on success, exits on failure.
resolve_repo_name() {
    local REPO_ROOT="$1"
    local DEFAULT_NAME
    DEFAULT_NAME=$(basename "$REPO_ROOT")

    ensure_repos_file || exit 1

    # Check if this path is already registered
    local EXISTING_NAME
    EXISTING_NAME=$(lookup_repo_by_path "$REPO_ROOT")
    if [ -n "$EXISTING_NAME" ]; then
        REPO_REGISTERED_NAME="$EXISTING_NAME"
        return 0
    fi

    # Not registered yet. Try the default name (directory basename).
    if repo_name_taken "$DEFAULT_NAME"; then
        # Collision: same name, different path
        local OTHER_PATH
        OTHER_PATH=$(jq -r --arg name "$DEFAULT_NAME" '.repos[$name].path' "$REPOS_FILE")
        echo -e "${YELLOW}[COLLISION]${NC} Repo name '${DEFAULT_NAME}' is already registered for:" >&2
        echo -e "  ${OTHER_PATH}" >&2
        echo "" >&2
        echo "This repo is at: ${REPO_ROOT}" >&2
        echo "Enter a unique name for this repo (or Ctrl+C to cancel):" >&2

        while true; do
            read -p "> " NEW_NAME </dev/tty
            if [ -z "$NEW_NAME" ]; then
                echo "Name cannot be empty." >&2
                continue
            fi
            if repo_name_taken "$NEW_NAME"; then
                local TAKEN_PATH
                TAKEN_PATH=$(jq -r --arg name "$NEW_NAME" '.repos[$name].path' "$REPOS_FILE")
                echo "Name '${NEW_NAME}' is also taken (${TAKEN_PATH}). Try another:" >&2
                continue
            fi
            break
        done

        register_repo "$NEW_NAME" "$REPO_ROOT"
        echo -e "${GREEN}[OK]${NC} Registered repo '${NEW_NAME}' -> ${REPO_ROOT}" >&2
        REPO_REGISTERED_NAME="$NEW_NAME"
    else
        # Name is available, register automatically
        register_repo "$DEFAULT_NAME" "$REPO_ROOT"
        echo -e "${GREEN}[OK]${NC} Registered repo '${DEFAULT_NAME}' -> ${REPO_ROOT}" >&2
        REPO_REGISTERED_NAME="$DEFAULT_NAME"
    fi
}

# ---- CLI commands (when run directly) ----

repo_add() {
    local NAME=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                echo "Usage: hive repo add [name]"
                echo ""
                echo "Register the current git repo in the hive registry."
                echo "If no name is given, uses the directory name."
                echo "If the name collides, you'll be asked for a new one."
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

    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo -e "${RED}[ERROR]${NC} Not in a git repository"
        exit 1
    }

    ensure_repos_file || exit 1

    # Check if this path is already registered
    local EXISTING_NAME
    EXISTING_NAME=$(lookup_repo_by_path "$REPO_ROOT")
    if [ -n "$EXISTING_NAME" ]; then
        echo -e "${YELLOW}[SKIP]${NC} This repo is already registered as '${EXISTING_NAME}'"
        return 0
    fi

    # Use given name or default to basename
    if [ -z "$NAME" ]; then
        NAME=$(basename "$REPO_ROOT")
    fi

    # Check for collision
    if repo_name_taken "$NAME"; then
        local OTHER_PATH
        OTHER_PATH=$(jq -r --arg name "$NAME" '.repos[$name].path' "$REPOS_FILE")
        echo -e "${YELLOW}[COLLISION]${NC} Repo name '${NAME}' is already registered for:"
        echo "  ${OTHER_PATH}"
        echo ""
        echo "This repo is at: ${REPO_ROOT}"
        echo "Enter a unique name for this repo (or Ctrl+C to cancel):"

        while true; do
            read -p "> " NAME
            if [ -z "$NAME" ]; then
                echo "Name cannot be empty."
                continue
            fi
            if repo_name_taken "$NAME"; then
                local TAKEN_PATH
                TAKEN_PATH=$(jq -r --arg name "$NAME" '.repos[$name].path' "$REPOS_FILE")
                echo "Name '${NAME}' is also taken (${TAKEN_PATH}). Try another:"
                continue
            fi
            break
        done
    fi

    register_repo "$NAME" "$REPO_ROOT"
    echo -e "${GREEN}[OK]${NC} Registered repo '${NAME}' -> ${REPO_ROOT}"
}

repo_ls() {
    ensure_repos_file || exit 1

    local COUNT
    COUNT=$(jq '.repos | length' "$REPOS_FILE")

    if [ "$COUNT" -eq 0 ]; then
        echo "No repos registered."
        echo "Use 'hive repo add [name]' from inside a git repo, or just run 'hive repo send'."
        return 0
    fi

    echo -e "${CYAN}Registered repos ($COUNT):${NC}"
    echo ""
    printf "  %-20s %-50s %s\n" "NAME" "PATH" "ADDED"
    printf "  %-20s %-50s %s\n" "----" "----" "-----"
    jq -r '.repos | to_entries[] | "\(.value.name)\t\(.value.path)\t\(.value.added)"' "$REPOS_FILE" \
        | while IFS=$'\t' read -r name path added; do
            printf "  %-20s %-50s %s\n" "$name" "$path" "$added"
        done
    echo ""
}

repo_rm() {
    local NAME="$1"

    if [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} Repo name is required"
        echo "Usage: hive repo rm <name>"
        exit 1
    fi

    ensure_repos_file || exit 1

    if ! repo_name_taken "$NAME"; then
        echo -e "${RED}[ERROR]${NC} Repo '$NAME' not found"
        exit 1
    fi

    local REPO_PATH
    REPO_PATH=$(jq -r --arg name "$NAME" '.repos[$name].path' "$REPOS_FILE")

    jq --arg name "$NAME" 'del(.repos[$name])' "$REPOS_FILE" > "$REPOS_FILE.tmp"
    mv "$REPOS_FILE.tmp" "$REPOS_FILE"

    echo -e "${GREEN}[OK]${NC} Repo '${NAME}' removed (was ${REPO_PATH})"
}

# If run directly (not sourced), route subcommands
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SUBCMD="${1:-}"
    shift 2>/dev/null || true

    case "$SUBCMD" in
        add)     repo_add "$@" ;;
        ls|list) repo_ls "$@" ;;
        rm|remove) repo_rm "$@" ;;
        --help|-h|help)
            echo "Usage: hive repo <command>"
            echo ""
            echo "Registry commands:"
            echo "  add [name]    Register current repo (default name: directory name)"
            echo "  ls            List registered repos"
            echo "  rm <name>     Remove a repo from registry"
            echo ""
            echo "Transfer commands:"
            echo "  send <worker> [branch]    Send repo to a worker"
            echo "  fetch <worker> [branch]   Fetch repo from a worker"
            echo "  ssh <worker>              SSH into worker at repo directory"
            ;;
        *)
            echo -e "${RED}Unknown repo command: ${SUBCMD:-<none>}${NC}"
            echo "Run 'hive repo help' for usage"
            exit 1
            ;;
    esac
fi
