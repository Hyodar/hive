# Agent Setup

A comprehensive setup script for configuring machines for agentic AI development work. Installs AI coding tools, remote access software, and provides an integrated notification system with Telegram.

## Features

- **AI Coding Tools**: Claude Code, Codex, and Amp with sandboxless execution wrappers
- **Development Environment**: VSCode, Node.js, and essential dependencies
- **Remote Access**: NoMachine and Tailscale for remote development
- **Desktop Environment**: Cinnamon desktop for GUI access
- **Telegram Integration**: alertme/promptme scripts for notifications and interactive prompts
- **Ralph2**: Enhanced AI agent loop with improved task management and multi-tool support

## Quick Start

```bash
# Clone and run setup
git clone <repo-url>
cd agent-setup
sudo ./setup.sh

# Configure Telegram bot
tgsetup

# Initialize ralph2 in a project
ralphsetup /path/to/your/project
```

## Components

### AI Tool Wrappers

Sandboxless execution wrappers for autonomous agent work:

| Command | Tool | Description |
|---------|------|-------------|
| `xclaude` | Claude Code | `claude --dangerously-skip-permissions` |
| `xcodex` | Codex | `codex --dangerously-bypass-approvals-and-sandbox -m "gpt-5.2-codex xhigh"` |
| `xamp` | Amp | `amp --dangerously-allow-all` |

### Telegram Notifications

#### alertme

Send notifications to your Telegram chat:

```bash
# Success notification
alertme --title "Build Complete" --description "All tests passed" --status success

# Error notification
alertme --title "Build Failed" --description "TypeScript errors" --codeblock "$(cat error.log)" --status error

# Options
#   --title, -t       Alert title (required)
#   --description, -d Alert description
#   --codeblock, -c   Code block to include
#   --status, -s      success | info | warning | error
```

#### promptme

Send a prompt and wait for user response:

```bash
# Get user input
ANSWER=$(promptme --title "Confirm Deploy" --description "Deploy to production?" --timeout 60)
echo "User said: $ANSWER"

# Options (same as alertme plus):
#   --timeout, -T     Timeout in seconds (default: 300)

# Exit codes:
#   0 = success (response on stdout)
#   1 = error
#   2 = timeout
```

### Ralph2

Enhanced AI agent loop based on [snarktank/ralph](https://github.com/snarktank/ralph) with:

- Support for Claude Code, Codex, and Amp
- Improved jq-based task selection and status checking
- Telegram alert integration
- Interactive mode for step-by-step execution

```bash
# Check status
ralph2 --status

# List all tasks
ralph2 --list

# Show next pending task
ralph2 --next

# Run with default tool (Claude)
ralph2 10

# Run with specific tool
ralph2 --tool codex 5
ralph2 --tool amp --alert

# Interactive mode
ralph2 --interactive
```

#### Initialize in a Project

```bash
ralphsetup /path/to/project
cd /path/to/project

# Customize PRD
cp scripts/ralph/prd.json.example scripts/ralph/prd.json
# Edit prd.json with your tasks

# Run
./ralph2 --status
./ralph2
```

#### Install Skills Only

```bash
# Install skills globally without setting up a project
ralphsetup --skills-only

# Skills are installed to:
# ~/.config/amp/skills/prd, ~/.config/amp/skills/ralph
# ~/.claude/skills/prd, ~/.claude/skills/ralph
```

## Configuration

### Telegram Bot Setup

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Run `tgsetup` and enter your bot token
3. Send the binding phrase to your bot to link the chat
4. The bot runs as a systemd service (`agent-telegram-bot`)

```bash
# Check service status
systemctl status agent-telegram-bot

# View logs
journalctl -u agent-telegram-bot -f

# Restart service
sudo systemctl restart agent-telegram-bot
```

### Configuration Files

| File | Purpose |
|------|---------|
| `/etc/agent-setup/telegram_config.json` | Telegram bot configuration |
| `/etc/agent-setup/ralph2/` | Ralph2 default files |

## File Structure

```
agent-setup/
├── setup.sh                    # Main installation script (uses nvm + Node 24)
├── telegram-bot/
│   ├── agent_telegram_bot.py   # Telegram bot service
│   ├── agent-telegram-bot.service  # systemd service
│   ├── tgsetup                 # Setup wizard
│   ├── alertme                 # Alert script
│   └── promptme                # Prompt script
└── ralph2/
    ├── ralph2.sh               # Main agent loop
    ├── ralphsetup              # Project initializer
    ├── AGENTS.md               # Agent instructions (general)
    ├── CLAUDE.md               # Claude Code instructions
    ├── CODEX.md                # Codex instructions
    ├── prompt.md               # Amp instructions
    ├── prd.json.example        # PRD template
    └── skills/
        ├── prd/SKILL.md        # PRD generator skill
        └── ralph/SKILL.md      # PRD to JSON converter skill
```

## Requirements

- Ubuntu/Debian-based Linux
- Root access for installation
- Internet connection
- Telegram account (for notifications)

## License

MIT
