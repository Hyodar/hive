#!/bin/bash
# repo-registry.sh - Per-worker repo name registry for hive
#
# Source this file to get registry + refspec functions, or run directly for CLI commands.
#
# Repos are tracked per-worker inside /etc/hive/workers.json:
#   workers.<name>.repos.<repo_name> = "/local/path/to/repo"
#
# Refspec format: <local_branch>[:<worker_repo_name>][@<worker_branch>]
#   main              → local=main,  repo=<basename>, remote=main
#   main:myapp-v2     → local=main,  repo=myapp-v2,   remote=main
#   main@dev          → local=main,  repo=<basename>, remote=dev
#   main:myapp-v2@dev → local=main,  repo=myapp-v2,   remote=dev

HIVE_DIR="${HIVE_DIR:-/etc/hive}"
WORKERS_FILE="$HIVE_DIR/workers.json"

# Colors (safe to re-declare)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ensure_workers_file() {
    if [ ! -f "$WORKERS_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} Workers registry not found. Run 'hive init' first." >&2
        return 1
    fi
}

# ---- Refspec parsing ----

# Parse refspec into PARSED_LOCAL_BRANCH, PARSED_REPO_NAME, PARSED_REMOTE_BRANCH.
# PARSED_REPO_EXPLICIT is true if the user specified a repo name via :.
# Call: parse_refspec "<refspec>" "<default_repo_name>"
parse_refspec() {
    local REFSPEC="$1"
    local DEFAULT_REPO="$2"

    PARSED_LOCAL_BRANCH=""
    PARSED_REPO_NAME="$DEFAULT_REPO"
    PARSED_REMOTE_BRANCH=""
    PARSED_REPO_EXPLICIT=false

    if [ -z "$REFSPEC" ]; then
        return
    fi

    # Split on @
    local BEFORE_AT
    if [[ "$REFSPEC" == *@* ]]; then
        BEFORE_AT="${REFSPEC%%@*}"
        PARSED_REMOTE_BRANCH="${REFSPEC#*@}"
    else
        BEFORE_AT="$REFSPEC"
    fi

    # Split before-@ on :
    if [[ "$BEFORE_AT" == *:* ]]; then
        PARSED_LOCAL_BRANCH="${BEFORE_AT%%:*}"
        PARSED_REPO_NAME="${BEFORE_AT#*:}"
        PARSED_REPO_EXPLICIT=true
    else
        PARSED_LOCAL_BRANCH="$BEFORE_AT"
    fi

    # Default remote branch = local branch
    if [ -z "$PARSED_REMOTE_BRANCH" ]; then
        PARSED_REMOTE_BRANCH="$PARSED_LOCAL_BRANCH"
    fi
}

# ---- Per-worker repo registry ----

# Look up a repo name on a worker. Returns the local path or empty string.
lookup_worker_repo() {
    local WORKER="$1" REPO_NAME="$2"
    jq -r --arg w "$WORKER" --arg r "$REPO_NAME" \
        '.workers[$w].repos[$r] // empty' "$WORKERS_FILE" 2>/dev/null
}

# Find which repo name on a worker points to a given local path.
lookup_worker_repo_by_path() {
    local WORKER="$1" LOCAL_PATH="$2"
    jq -r --arg w "$WORKER" --arg p "$LOCAL_PATH" \
        '.workers[$w].repos // {} | to_entries[] | select(.value == $p) | .key' \
        "$WORKERS_FILE" 2>/dev/null | head -1
}

# Register a repo name on a worker (creates .repos if absent).
register_worker_repo() {
    local WORKER="$1" REPO_NAME="$2" LOCAL_PATH="$3"
    jq --arg w "$WORKER" --arg r "$REPO_NAME" --arg p "$LOCAL_PATH" \
        '.workers[$w].repos //= {} | .workers[$w].repos[$r] = $p' \
        "$WORKERS_FILE" > "$WORKERS_FILE.tmp"
    mv "$WORKERS_FILE.tmp" "$WORKERS_FILE"
}

# Remove a repo from a worker.
remove_worker_repo() {
    local WORKER="$1" REPO_NAME="$2"
    jq --arg w "$WORKER" --arg r "$REPO_NAME" \
        'del(.workers[$w].repos[$r])' \
        "$WORKERS_FILE" > "$WORKERS_FILE.tmp"
    mv "$WORKERS_FILE.tmp" "$WORKERS_FILE"
}

# Resolve repo name for sending to a worker.
# Checks for collisions and auto-registers.
# Sets RESOLVED_REPO_NAME on success.
# Arguments: <worker> <repo_name> <local_path> <explicit: true|false>
resolve_worker_repo_for_send() {
    local WORKER="$1" REPO_NAME="$2" LOCAL_PATH="$3" EXPLICIT="$4"

    ensure_workers_file || return 1

    # Verify worker exists
    if ! jq -e --arg w "$WORKER" '.workers[$w]' "$WORKERS_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} Worker '$WORKER' not in registry, skipping repo registration" >&2
        RESOLVED_REPO_NAME="$REPO_NAME"
        return 0
    fi

    # Check if this local path is already registered under a different name on this worker
    local EXISTING_NAME
    EXISTING_NAME=$(lookup_worker_repo_by_path "$WORKER" "$LOCAL_PATH")
    if [ -n "$EXISTING_NAME" ] && [ "$EXISTING_NAME" != "$REPO_NAME" ] && [ "$EXPLICIT" = false ]; then
        # Path already registered under a different name — use the existing name
        RESOLVED_REPO_NAME="$EXISTING_NAME"
        return 0
    fi

    local EXISTING_PATH
    EXISTING_PATH=$(lookup_worker_repo "$WORKER" "$REPO_NAME")

    if [ -n "$EXISTING_PATH" ]; then
        if [ "$EXISTING_PATH" = "$LOCAL_PATH" ]; then
            # Same path, same name — all good
            RESOLVED_REPO_NAME="$REPO_NAME"
            return 0
        fi

        # Collision: name taken by different path
        if [ "$EXPLICIT" = true ]; then
            echo -e "${RED}[ERROR]${NC} Repo '${REPO_NAME}' on worker '${WORKER}' already maps to:" >&2
            echo -e "  ${EXISTING_PATH}" >&2
            echo -e "This repo is at: ${LOCAL_PATH}" >&2
            echo -e "Use a different name in the refspec (e.g. main:other-name)" >&2
            return 1
        fi

        echo -e "${YELLOW}[COLLISION]${NC} Repo '${REPO_NAME}' on worker '${WORKER}' already maps to:" >&2
        echo -e "  ${EXISTING_PATH}" >&2
        echo "" >&2
        echo "This repo is at: ${LOCAL_PATH}" >&2
        echo "Enter a unique name for this repo on '${WORKER}' (or Ctrl+C to cancel):" >&2

        while true; do
            read -p "> " NEW_NAME </dev/tty
            if [ -z "$NEW_NAME" ]; then
                echo "Name cannot be empty." >&2
                continue
            fi
            local CHECK
            CHECK=$(lookup_worker_repo "$WORKER" "$NEW_NAME")
            if [ -n "$CHECK" ] && [ "$CHECK" != "$LOCAL_PATH" ]; then
                echo "Name '${NEW_NAME}' is also taken (${CHECK}). Try another:" >&2
                continue
            fi
            REPO_NAME="$NEW_NAME"
            break
        done
    fi

    # Register
    register_worker_repo "$WORKER" "$REPO_NAME" "$LOCAL_PATH"
    echo -e "${GREEN}[OK]${NC} Registered repo '${REPO_NAME}' on worker '${WORKER}' -> ${LOCAL_PATH}" >&2
    RESOLVED_REPO_NAME="$REPO_NAME"
}

# ---- CLI commands (when run directly) ----

repo_add_cmd() {
    local WORKER="" NAME=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                echo "Usage: hive repo add <worker> [name]"
                echo ""
                echo "Register the current git repo on a worker."
                echo "Default name is the directory basename."
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *)
                if [ -z "$WORKER" ]; then WORKER="$1"
                elif [ -z "$NAME" ]; then NAME="$1"
                else echo -e "${RED}Too many arguments${NC}"; exit 1
                fi
                shift ;;
        esac
    done

    if [ -z "$WORKER" ]; then
        echo -e "${RED}[ERROR]${NC} Worker name is required"
        echo "Usage: hive repo add <worker> [name]"
        exit 1
    fi

    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo -e "${RED}[ERROR]${NC} Not in a git repository"
        exit 1
    }

    ensure_workers_file || exit 1

    if ! jq -e --arg w "$WORKER" '.workers[$w]' "$WORKERS_FILE" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Worker '$WORKER' not found"
        exit 1
    fi

    NAME="${NAME:-$(basename "$REPO_ROOT")}"
    local EXPLICIT=false
    # If user gave a name argument, treat it as explicit
    [[ $# -ge 1 ]] || EXPLICIT=false

    resolve_worker_repo_for_send "$WORKER" "$NAME" "$REPO_ROOT" "$EXPLICIT"
}

repo_ls_cmd() {
    local WORKER=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                echo "Usage: hive repo ls [worker]"
                echo ""
                echo "List repos registered on workers."
                echo "If worker is given, only show that worker's repos."
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *)
                if [ -z "$WORKER" ]; then WORKER="$1"
                else echo -e "${RED}Too many arguments${NC}"; exit 1
                fi
                shift ;;
        esac
    done

    ensure_workers_file || exit 1

    if [ -n "$WORKER" ]; then
        if ! jq -e --arg w "$WORKER" '.workers[$w]' "$WORKERS_FILE" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR]${NC} Worker '$WORKER' not found"
            exit 1
        fi
        local COUNT
        COUNT=$(jq --arg w "$WORKER" '.workers[$w].repos // {} | length' "$WORKERS_FILE")
        if [ "$COUNT" -eq 0 ]; then
            echo "No repos registered on worker '$WORKER'."
            return 0
        fi
        echo -e "${CYAN}Repos on $WORKER ($COUNT):${NC}"
        echo ""
        printf "  %-25s %s\n" "REPO NAME" "LOCAL PATH"
        printf "  %-25s %s\n" "---------" "----------"
        jq -r --arg w "$WORKER" \
            '.workers[$w].repos // {} | to_entries[] | "\(.key)\t\(.value)"' "$WORKERS_FILE" \
            | while IFS=$'\t' read -r name path; do
                printf "  %-25s %s\n" "$name" "$path"
            done
        echo ""
    else
        # Show all workers
        local HAS_REPOS=false
        jq -r '.workers | to_entries[] | .key' "$WORKERS_FILE" | while read -r w; do
            local COUNT
            COUNT=$(jq --arg w "$w" '.workers[$w].repos // {} | length' "$WORKERS_FILE")
            if [ "$COUNT" -gt 0 ]; then
                HAS_REPOS=true
                echo -e "${CYAN}$w${NC} ($COUNT repos):"
                jq -r --arg w "$w" \
                    '.workers[$w].repos // {} | to_entries[] | "\(.key)\t\(.value)"' "$WORKERS_FILE" \
                    | while IFS=$'\t' read -r name path; do
                        printf "  %-25s %s\n" "$name" "$path"
                    done
                echo ""
            fi
        done
        # Check if anything was printed (subshell issue — just check total)
        local TOTAL
        TOTAL=$(jq '[.workers[].repos // {} | length] | add // 0' "$WORKERS_FILE")
        if [ "$TOTAL" -eq 0 ]; then
            echo "No repos registered on any worker."
            echo "Repos are auto-registered on first 'hive repo send'."
        fi
    fi
}

repo_rm_cmd() {
    local WORKER="" NAME=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                echo "Usage: hive repo rm <worker> <name>"
                echo ""
                echo "Remove a repo from a worker's registry."
                exit 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *)
                if [ -z "$WORKER" ]; then WORKER="$1"
                elif [ -z "$NAME" ]; then NAME="$1"
                else echo -e "${RED}Too many arguments${NC}"; exit 1
                fi
                shift ;;
        esac
    done

    if [ -z "$WORKER" ] || [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} Worker and repo name are required"
        echo "Usage: hive repo rm <worker> <name>"
        exit 1
    fi

    ensure_workers_file || exit 1

    local EXISTING
    EXISTING=$(lookup_worker_repo "$WORKER" "$NAME")
    if [ -z "$EXISTING" ]; then
        echo -e "${RED}[ERROR]${NC} Repo '$NAME' not found on worker '$WORKER'"
        exit 1
    fi

    remove_worker_repo "$WORKER" "$NAME"
    echo -e "${GREEN}[OK]${NC} Repo '${NAME}' removed from worker '${WORKER}' (was ${EXISTING})"
}

# If run directly (not sourced), route subcommands
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SUBCMD="${1:-}"
    shift 2>/dev/null || true

    case "$SUBCMD" in
        add)     repo_add_cmd "$@" ;;
        ls|list) repo_ls_cmd "$@" ;;
        rm|remove) repo_rm_cmd "$@" ;;
        --help|-h|help)
            echo "Usage: hive repo <command>"
            echo ""
            echo "Registry commands:"
            echo "  add <worker> [name]       Register current repo on a worker"
            echo "  ls [worker]               List repos (all workers or specific)"
            echo "  rm <worker> <name>        Remove a repo from a worker"
            echo ""
            echo "Transfer commands (refspec: <local_branch>[:<repo_name>][@<remote_branch>]):"
            echo "  send <worker> [refspec]   Send repo to a worker"
            echo "  fetch <worker> [refspec]  Fetch repo from a worker"
            echo "  ssh <worker> [repo_name]  SSH into worker at repo directory"
            ;;
        *)
            echo -e "${RED}Unknown repo command: ${SUBCMD:-<none>}${NC}"
            echo "Run 'hive repo help' for usage"
            exit 1
            ;;
    esac
fi
