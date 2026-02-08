#!/bin/bash
# install.sh - Standalone installer for Ralph2
#
# Installs ralph2 and prd commands, skills, and optionally alertme/promptme.
# Works independently of the full Hive worker setup.
#
# Usage:
#   curl -fsSL <url>/install.sh | bash
#   ./install.sh [OPTIONS]
#
# Options:
#   --system          Install system-wide to /usr/local/bin (requires sudo)
#   --no-skills       Skip installing skills to AI tool directories
#   --no-telegram     Skip installing alertme/promptme
#   --help            Show this help

set -e

# Resolve the directory this script lives in (for local installs from repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Defaults
SYSTEM_INSTALL=false
INSTALL_SKILLS=true
INSTALL_TELEGRAM=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)
            SYSTEM_INSTALL=true
            shift
            ;;
        --no-skills)
            INSTALL_SKILLS=false
            shift
            ;;
        --no-telegram)
            INSTALL_TELEGRAM=false
            shift
            ;;
        --help|-h)
            echo "Ralph2 Standalone Installer"
            echo ""
            echo "Usage: ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --system          Install system-wide to /usr/local/bin (requires sudo)"
            echo "  --no-skills       Skip installing skills to AI tool directories"
            echo "  --no-telegram     Skip installing alertme/promptme"
            echo "  --help            Show this help"
            echo ""
            echo "Default install locations (user-local):"
            echo "  Binaries:  ~/.local/bin/"
            echo "  Skills:    ~/.ralph2/skills/"
            echo "  AI skills: ~/.claude/skills/, ~/.config/amp/skills/, ~/.codex/skills/"
            echo ""
            echo "System install locations (--system):"
            echo "  Binaries:  /usr/local/bin/"
            echo "  Skills:    /etc/hive/ralph2/skills/"
            echo "  AI skills: same as above (per-user)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
done

echo ""
echo -e "${CYAN}========================================"
echo -e "  Ralph2 Standalone Installer"
echo -e "========================================${NC}"
echo ""

# ---- Check dependencies ----

MISSING_DEPS=()

if ! command -v jq &>/dev/null; then
    MISSING_DEPS+=("jq")
fi

if ! command -v git &>/dev/null; then
    MISSING_DEPS+=("git")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log_error "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them with:"
    if command -v apt-get &>/dev/null; then
        echo "  sudo apt-get install -y ${MISSING_DEPS[*]}"
    elif command -v brew &>/dev/null; then
        echo "  brew install ${MISSING_DEPS[*]}"
    elif command -v dnf &>/dev/null; then
        echo "  sudo dnf install -y ${MISSING_DEPS[*]}"
    elif command -v pacman &>/dev/null; then
        echo "  sudo pacman -S ${MISSING_DEPS[*]}"
    else
        echo "  Please install: ${MISSING_DEPS[*]}"
    fi
    exit 1
fi
log_success "Dependencies: jq, git"

# Check for at least one AI tool
HAS_CLAUDE=false
HAS_CODEX=false
HAS_AMP=false

command -v claude &>/dev/null && HAS_CLAUDE=true
command -v codex &>/dev/null && HAS_CODEX=true
command -v amp &>/dev/null && HAS_AMP=true

if [ "$HAS_CLAUDE" = false ] && [ "$HAS_CODEX" = false ] && [ "$HAS_AMP" = false ]; then
    log_warn "No AI tools found (claude, codex, amp)"
    echo "  Ralph2 requires at least one. Install with:"
    echo "    npm install -g @anthropic-ai/claude-code"
    echo "    npm install -g @openai/codex"
    echo "    npm install -g @anthropic-ai/amp"
    echo ""
    echo "  Continuing installation anyway..."
else
    TOOLS_FOUND=""
    [ "$HAS_CLAUDE" = true ] && TOOLS_FOUND+="claude "
    [ "$HAS_CODEX" = true ] && TOOLS_FOUND+="codex "
    [ "$HAS_AMP" = true ] && TOOLS_FOUND+="amp "
    log_success "AI tools: $TOOLS_FOUND"
fi

# ---- Determine install paths ----

if [ "$SYSTEM_INSTALL" = true ]; then
    if [ "$EUID" -ne 0 ]; then
        log_error "System install requires root. Run with: sudo ./install.sh --system"
        exit 1
    fi
    BIN_DIR="/usr/local/bin"
    SKILLS_DIR="/etc/hive/ralph2/skills"
    RALPH2_DIR="/etc/hive/ralph2"
else
    BIN_DIR="$HOME/.local/bin"
    SKILLS_DIR="$HOME/.ralph2/skills"
    RALPH2_DIR="$HOME/.ralph2"
fi

log_info "Install mode: $([ "$SYSTEM_INSTALL" = true ] && echo "system-wide" || echo "user-local")"
log_info "Binaries: $BIN_DIR"
log_info "Skills:   $SKILLS_DIR"

# ---- Check source files exist ----

if [ ! -f "$SCRIPT_DIR/ralph2.sh" ]; then
    log_error "Cannot find ralph2.sh in $SCRIPT_DIR"
    echo "Run this script from the ralph2 directory, or clone the repo first."
    exit 1
fi

# ---- Install ralph2 core ----

log_info "Installing ralph2..."

mkdir -p "$BIN_DIR"
mkdir -p "$RALPH2_DIR"
mkdir -p "$SKILLS_DIR/prd"
mkdir -p "$SKILLS_DIR/ralph"
mkdir -p "$SKILLS_DIR/ralph-tasks"

# Copy ralph2.sh to install dir
cp "$SCRIPT_DIR/ralph2.sh" "$RALPH2_DIR/ralph2.sh"
chmod +x "$RALPH2_DIR/ralph2.sh"

# Copy skills
cp "$SCRIPT_DIR/skills/prd/SKILL.md" "$SKILLS_DIR/prd/"
cp "$SCRIPT_DIR/skills/ralph/SKILL.md" "$SKILLS_DIR/ralph/"
cp "$SCRIPT_DIR/skills/ralph-tasks/SKILL.md" "$SKILLS_DIR/ralph-tasks/"

# Copy prd.json.example
cp "$SCRIPT_DIR/prd.json.example" "$RALPH2_DIR/"

# Create ralph2 wrapper in bin
cat > "$BIN_DIR/ralph2" << EOF
#!/bin/bash
export HIVE_SKILLS_DIR="${SKILLS_DIR}"
exec "$RALPH2_DIR/ralph2.sh" "\$@"
EOF
chmod +x "$BIN_DIR/ralph2"

# Install prd command
cp "$SCRIPT_DIR/prd" "$BIN_DIR/prd"
chmod +x "$BIN_DIR/prd"

# Patch prd to use the installed skills dir by injecting HIVE_SKILLS_DIR
# Only if it doesn't already export it
if ! grep -q "^export HIVE_SKILLS_DIR" "$BIN_DIR/prd"; then
    # Insert after the shebang line
    sed -i '1 a\export HIVE_SKILLS_DIR="'"$SKILLS_DIR"'"' "$BIN_DIR/prd"
fi

log_success "ralph2, prd"

# ---- Install alertme/promptme (optional) ----

if [ "$INSTALL_TELEGRAM" = true ]; then
    TELEGRAM_DIR="$SCRIPT_DIR/../telegram-bot"
    if [ -f "$TELEGRAM_DIR/alertme" ] && [ -f "$TELEGRAM_DIR/promptme" ]; then
        log_info "Installing alertme and promptme..."
        cp "$TELEGRAM_DIR/alertme" "$BIN_DIR/alertme"
        cp "$TELEGRAM_DIR/promptme" "$BIN_DIR/promptme"
        chmod +x "$BIN_DIR/alertme" "$BIN_DIR/promptme"
        log_success "alertme, promptme (Telegram bot service required separately)"
    else
        log_warn "Telegram tools not found at $TELEGRAM_DIR — skipping"
    fi
fi

# ---- Install skills to AI tool directories (optional) ----

if [ "$INSTALL_SKILLS" = true ]; then
    log_info "Installing skills to AI tool directories..."

    TARGET_HOME="$HOME"

    # Claude Code skills -> ~/.claude/skills/
    if [ "$HAS_CLAUDE" = true ] || [ "$SYSTEM_INSTALL" = false ]; then
        CLAUDE_SKILLS="$TARGET_HOME/.claude/skills"
        mkdir -p "$CLAUDE_SKILLS/prd" "$CLAUDE_SKILLS/ralph" "$CLAUDE_SKILLS/ralph-tasks"
        cp "$SCRIPT_DIR/skills/prd/SKILL.md" "$CLAUDE_SKILLS/prd/"
        cp "$SCRIPT_DIR/skills/ralph/SKILL.md" "$CLAUDE_SKILLS/ralph/"
        cp "$SCRIPT_DIR/skills/ralph-tasks/SKILL.md" "$CLAUDE_SKILLS/ralph-tasks/"
        log_success "Claude skills -> $CLAUDE_SKILLS"
    fi

    # Amp skills -> ~/.config/amp/skills/
    if [ "$HAS_AMP" = true ] || [ "$SYSTEM_INSTALL" = false ]; then
        AMP_SKILLS="$TARGET_HOME/.config/amp/skills"
        mkdir -p "$AMP_SKILLS/prd" "$AMP_SKILLS/ralph" "$AMP_SKILLS/ralph-tasks"
        cp "$SCRIPT_DIR/skills/prd/SKILL.md" "$AMP_SKILLS/prd/"
        cp "$SCRIPT_DIR/skills/ralph/SKILL.md" "$AMP_SKILLS/ralph/"
        cp "$SCRIPT_DIR/skills/ralph-tasks/SKILL.md" "$AMP_SKILLS/ralph-tasks/"
        log_success "Amp skills -> $AMP_SKILLS"
    fi

    # Codex skills -> ~/.codex/skills/
    if [ "$HAS_CODEX" = true ] || [ "$SYSTEM_INSTALL" = false ]; then
        CODEX_SKILLS="$TARGET_HOME/.codex/skills"
        mkdir -p "$CODEX_SKILLS/prd" "$CODEX_SKILLS/ralph" "$CODEX_SKILLS/ralph-tasks"
        cp "$SCRIPT_DIR/skills/prd/SKILL.md" "$CODEX_SKILLS/prd/"
        cp "$SCRIPT_DIR/skills/ralph/SKILL.md" "$CODEX_SKILLS/ralph/"
        cp "$SCRIPT_DIR/skills/ralph-tasks/SKILL.md" "$CODEX_SKILLS/ralph-tasks/"
        log_success "Codex skills -> $CODEX_SKILLS"
    fi
fi

# ---- Check PATH ----

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    log_warn "$BIN_DIR is not in your PATH"
    echo ""
    echo "  Add it to your shell profile:"
    echo ""
    if [ -f "$HOME/.zshrc" ]; then
        echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc"
        echo "    source ~/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
        echo "    source ~/.bashrc"
    else
        echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile"
        echo "    source ~/.profile"
    fi
fi

# ---- Done ----

echo ""
echo -e "${GREEN}========================================"
echo -e "  Ralph2 installed successfully!"
echo -e "========================================${NC}"
echo ""
echo "Quick start:"
echo "  1. cd into your project directory"
echo "  2. prd --tool claude          # create a PRD interactively"
echo "  3. ralph2                     # run the agent loop"
echo ""
echo "Other commands:"
echo "  ralph2 --status               # check progress"
echo "  ralph2 --list                 # list all tasks"
echo "  ralph2 --tool codex 5         # use codex, max 5 iterations"
echo "  ralph2 --help                 # full usage"
echo ""
