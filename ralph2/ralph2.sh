#!/bin/bash
# Ralph2 - Enhanced AI Agent Loop
# Supports: Claude Code, Codex, and Amp
# Features: Improved jq task selection, status checking, alertme/promptme integration
#
# Usage: ./ralph2.sh [OPTIONS] [max_iterations]
#   --tool amp|claude|codex    Select AI tool (default: claude)
#   --status                   Show PRD status and exit
#   --next                     Show next task and exit
#   --list                     List all tasks with status
#   --reset                    Reset all tasks to pending
#   --alert                    Enable telegram alerts on completion/error
#   --interactive              Prompt for confirmation before each iteration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default options
TOOL="claude"
MAX_ITERATIONS=10
SHOW_STATUS=false
SHOW_NEXT=false
LIST_TASKS=false
RESET_TASKS=false
ENABLE_ALERTS=false
INTERACTIVE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tool)
            TOOL="$2"
            shift 2
            ;;
        --tool=*)
            TOOL="${1#*=}"
            shift
            ;;
        --status)
            SHOW_STATUS=true
            shift
            ;;
        --next)
            SHOW_NEXT=true
            shift
            ;;
        --list)
            LIST_TASKS=true
            shift
            ;;
        --reset)
            RESET_TASKS=true
            shift
            ;;
        --alert|--alerts)
            ENABLE_ALERTS=true
            shift
            ;;
        --interactive|-i)
            INTERACTIVE=true
            shift
            ;;
        --help|-h)
            echo "Ralph2 - Enhanced AI Agent Loop"
            echo ""
            echo "Usage: ralph2 [OPTIONS] [max_iterations]"
            echo ""
            echo "Options:"
            echo "  --tool <name>     AI tool: amp, claude, codex (default: claude)"
            echo "  --status          Show PRD status summary and exit"
            echo "  --next            Show next pending task and exit"
            echo "  --list            List all tasks with status and exit"
            echo "  --reset           Reset all tasks to pending"
            echo "  --alert           Send telegram alerts on completion/error"
            echo "  --interactive     Prompt before each iteration"
            echo "  --help            Show this help"
            echo ""
            echo "Examples:"
            echo "  ralph2                     # Run with Claude, 10 iterations"
            echo "  ralph2 --tool codex 5     # Run with Codex, 5 iterations"
            echo "  ralph2 --status           # Check current progress"
            echo "  ralph2 --list             # See all tasks"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITERATIONS="$1"
            else
                echo "Unknown option: $1"
                echo "Use --help for usage"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate tool
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
    echo -e "${RED}Error: Invalid tool '$TOOL'. Must be: amp, claude, codex${NC}"
    exit 1
fi

# Check PRD exists
check_prd() {
    if [ ! -f "$PRD_FILE" ]; then
        echo -e "${RED}Error: PRD file not found at $PRD_FILE${NC}"
        echo "Create one from prd.json.example or use 'ralphsetup' to initialize"
        exit 1
    fi
}

# JQ helper functions for task management
jq_get_project() {
    jq -r '.project // "Unknown Project"' "$PRD_FILE"
}

jq_get_branch() {
    jq -r '.branchName // "main"' "$PRD_FILE"
}

jq_count_total() {
    jq '.userStories | length' "$PRD_FILE"
}

jq_count_completed() {
    jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE"
}

jq_count_pending() {
    jq '[.userStories[] | select(.passes == false)] | length' "$PRD_FILE"
}

jq_get_next_task() {
    # Get highest priority task where passes is false
    jq -r '
        .userStories
        | map(select(.passes == false))
        | sort_by(.priority)
        | first
        | if . then "\(.id): \(.title)" else "none" end
    ' "$PRD_FILE"
}

jq_get_next_task_id() {
    jq -r '
        .userStories
        | map(select(.passes == false))
        | sort_by(.priority)
        | first
        | .id // "none"
    ' "$PRD_FILE"
}

jq_get_next_task_full() {
    jq '
        .userStories
        | map(select(.passes == false))
        | sort_by(.priority)
        | first
    ' "$PRD_FILE"
}

jq_list_tasks() {
    jq -r '
        .userStories
        | sort_by(.priority)
        | .[]
        | if .passes then "  \u2705" else "  \u23f3" end + " [\(.priority)] \(.id): \(.title)"
    ' "$PRD_FILE"
}

jq_all_complete() {
    local pending=$(jq_count_pending)
    [ "$pending" -eq 0 ]
}

jq_reset_all() {
    jq '.userStories |= map(.passes = false)' "$PRD_FILE" > "$PRD_FILE.tmp"
    mv "$PRD_FILE.tmp" "$PRD_FILE"
}

# Show status summary
show_status() {
    check_prd
    local project=$(jq_get_project)
    local branch=$(jq_get_branch)
    local total=$(jq_count_total)
    local completed=$(jq_count_completed)
    local pending=$(jq_count_pending)
    local progress=$((completed * 100 / total))

    echo ""
    echo -e "${CYAN}========================================"
    echo -e "  Ralph2 Status: $project"
    echo -e "========================================${NC}"
    echo ""
    echo -e "Branch:    ${BLUE}$branch${NC}"
    echo -e "Progress:  ${GREEN}$completed${NC}/$total tasks ($progress%)"
    echo -e "Pending:   ${YELLOW}$pending${NC} tasks"
    echo ""

    # Progress bar
    local bar_width=40
    local filled=$((progress * bar_width / 100))
    local empty=$((bar_width - filled))
    printf "["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] %d%%\n" "$progress"
    echo ""

    if [ "$pending" -gt 0 ]; then
        local next=$(jq_get_next_task)
        echo -e "Next task: ${YELLOW}$next${NC}"
    else
        echo -e "${GREEN}All tasks complete!${NC}"
    fi
    echo ""
}

# Show next task details
show_next() {
    check_prd
    local task=$(jq_get_next_task_full)

    if [ "$task" = "null" ]; then
        echo -e "${GREEN}All tasks are complete!${NC}"
        exit 0
    fi

    echo ""
    echo -e "${CYAN}Next Task:${NC}"
    echo "$task" | jq -r '
        "  ID:          \(.id)",
        "  Title:       \(.title)",
        "  Priority:    \(.priority)",
        "  Description: \(.description)",
        "",
        "  Acceptance Criteria:"
    '
    echo "$task" | jq -r '.acceptanceCriteria[]' | while read -r criteria; do
        echo "    - $criteria"
    done
    echo ""
}

# List all tasks
list_tasks() {
    check_prd
    local project=$(jq_get_project)

    echo ""
    echo -e "${CYAN}Tasks for: $project${NC}"
    echo "----------------------------------------"
    jq_list_tasks
    echo ""
    echo "Legend: [priority] ID: Title"
    echo ""
}

# Reset all tasks
reset_tasks() {
    check_prd
    read -p "Reset all tasks to pending? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        jq_reset_all
        echo -e "${GREEN}All tasks reset to pending${NC}"
    else
        echo "Cancelled"
    fi
}

# Handle status-only commands
if [ "$SHOW_STATUS" = true ]; then
    show_status
    exit 0
fi

if [ "$SHOW_NEXT" = true ]; then
    show_next
    exit 0
fi

if [ "$LIST_TASKS" = true ]; then
    list_tasks
    exit 0
fi

if [ "$RESET_TASKS" = true ]; then
    reset_tasks
    exit 0
fi

# Main execution
check_prd

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    CURRENT_BRANCH=$(jq_get_branch)
    LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
        DATE=$(date +%Y-%m-%d)
        FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
        ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

        echo -e "${BLUE}Archiving previous run: $LAST_BRANCH${NC}"
        mkdir -p "$ARCHIVE_FOLDER"
        [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
        [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
        echo "  Archived to: $ARCHIVE_FOLDER"

        # Reset progress file
        echo "# Ralph2 Progress Log" > "$PROGRESS_FILE"
        echo "Started: $(date)" >> "$PROGRESS_FILE"
        echo "Tool: $TOOL" >> "$PROGRESS_FILE"
        echo "---" >> "$PROGRESS_FILE"
    fi
fi

# Track current branch
CURRENT_BRANCH=$(jq_get_branch)
echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"

# Initialize progress file if needed
if [ ! -f "$PROGRESS_FILE" ]; then
    echo "# Ralph2 Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "Tool: $TOOL" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
fi

# Check if already complete
if jq_all_complete; then
    echo -e "${GREEN}All tasks already complete!${NC}"
    if [ "$ENABLE_ALERTS" = true ]; then
        alertme --title "Ralph2 Complete" --description "All tasks were already complete" --status success 2>/dev/null || true
    fi
    exit 0
fi

# Show initial status
echo ""
echo -e "${CYAN}========================================"
echo -e "  Ralph2 - Starting Agent Loop"
echo -e "========================================${NC}"
echo ""
echo "Tool:       $TOOL"
echo "Iterations: $MAX_ITERATIONS (max)"
show_status

# Get prompt file based on tool
get_prompt_file() {
    case "$TOOL" in
        amp)
            echo "$SCRIPT_DIR/prompt.md"
            ;;
        claude)
            echo "$SCRIPT_DIR/CLAUDE.md"
            ;;
        codex)
            echo "$SCRIPT_DIR/CODEX.md"
            ;;
    esac
}

PROMPT_FILE=$(get_prompt_file)

if [ ! -f "$PROMPT_FILE" ]; then
    echo -e "${RED}Error: Prompt file not found: $PROMPT_FILE${NC}"
    exit 1
fi

# Main loop
for i in $(seq 1 $MAX_ITERATIONS); do
    # Check if complete before starting
    if jq_all_complete; then
        echo ""
        echo -e "${GREEN}========================================"
        echo -e "  All tasks complete!"
        echo -e "========================================${NC}"
        if [ "$ENABLE_ALERTS" = true ]; then
            alertme --title "Ralph2 Complete" \
                    --description "All tasks completed successfully after $((i-1)) iterations" \
                    --status success 2>/dev/null || true
        fi
        exit 0
    fi

    NEXT_TASK=$(jq_get_next_task)
    NEXT_ID=$(jq_get_next_task_id)

    echo ""
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  Ralph2 Iteration $i of $MAX_ITERATIONS ($TOOL)${NC}"
    echo -e "${BLUE}  Task: $NEXT_TASK${NC}"
    echo -e "${BLUE}===============================================================${NC}"

    # Interactive mode confirmation
    if [ "$INTERACTIVE" = true ]; then
        read -p "Start iteration $i? (Y/n/q): " confirm
        case "$confirm" in
            n|N)
                echo "Skipping iteration..."
                continue
                ;;
            q|Q)
                echo "Quitting..."
                exit 0
                ;;
        esac
    fi

    # Run the selected tool
    case "$TOOL" in
        amp)
            OUTPUT=$(cat "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
            ;;
        claude)
            OUTPUT=$(claude --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
            ;;
        codex)
            OUTPUT=$(codex --dangerously-auto-approve --quiet < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
            ;;
    esac

    # Check for completion signal
    if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
        echo ""
        echo -e "${GREEN}========================================"
        echo -e "  Ralph2 completed all tasks!"
        echo -e "  Finished at iteration $i of $MAX_ITERATIONS"
        echo -e "========================================${NC}"
        if [ "$ENABLE_ALERTS" = true ]; then
            alertme --title "Ralph2 Complete" \
                    --description "All tasks completed successfully in $i iterations" \
                    --status success 2>/dev/null || true
        fi
        exit 0
    fi

    # Check for errors in output
    if echo "$OUTPUT" | grep -qiE "(fatal error|exception|panic|segfault)"; then
        echo -e "${YELLOW}Warning: Potential error detected in output${NC}"
        if [ "$ENABLE_ALERTS" = true ]; then
            alertme --title "Ralph2 Warning" \
                    --description "Potential error in iteration $i for task $NEXT_ID" \
                    --status warning 2>/dev/null || true
        fi
    fi

    echo ""
    echo -e "${GREEN}Iteration $i complete. Continuing...${NC}"
    sleep 2
done

# Max iterations reached
echo ""
echo -e "${YELLOW}========================================"
echo -e "  Ralph2 reached max iterations ($MAX_ITERATIONS)"
echo -e "========================================${NC}"
echo ""
show_status
echo "Check $PROGRESS_FILE for details."

if [ "$ENABLE_ALERTS" = true ]; then
    alertme --title "Ralph2 Stopped" \
            --description "Reached max iterations ($MAX_ITERATIONS) without completing all tasks" \
            --status warning 2>/dev/null || true
fi

exit 1
