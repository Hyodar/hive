# Agent Setup (Hive)

A manager/worker system for orchestrating agentic AI development across multiple machines. The **manager** controls the swarm, and **workers** run AI coding agents autonomously.

## Architecture

```
Manager                          Workers
┌──────────────────┐      ┌──────────────────┐
│  hive init       │      │  AI tools         │
│  hive worker *   │ SSH  │  ralph2           │
│  hive repo send  │─────>│  alertme/promptme │
│  hive repo fetch │<─────│  xclaude/xcodex   │
│  Telegram bot    │      │  NoMachine + VNC  │
└──────────────────┘      └──────────────────┘
        │                         │
        └─── Tailscale VPN ───────┘
```

## Quick Start

### Manager Setup

```bash
git clone <repo-url>
cd agent-setup
sudo ./setup-manager.sh      # Install deps, Tailscale, Telegram, hive
sudo tailscale up             # Connect to tailnet
sudo hive init                # Configure Telegram bot & worker registry
```

### Worker Setup (from Manager)

```bash
hive worker setup root@192.168.1.100 --name agent-vm-1
# This will SSH in, install everything, copy Telegram config,
# and open a session for you to run 'tailscale up'
```

### Manual Worker Setup

```bash
git clone <repo-url>
cd agent-setup
sudo ./setup-agent.sh
sudo tailscale up
```

## Hive CLI

All tools are accessed through the `hive` command.

### Manager Commands

```bash
hive init                                   # Initialize manager (Telegram, registry)
hive worker setup <host> --name <name>      # Set up a remote worker via SSH
hive worker add <name> [--host <host>]      # Register a worker without setup
hive worker ls                              # List registered workers
hive worker rm <name>                       # Remove a worker
```

### Repo Transfer

```bash
hive repo send <worker> [branch]            # Send current repo to a worker
hive repo fetch <worker> [branch]           # Fetch a repo from a worker
```

### Agent Tools (on Workers)

```bash
hive ralph2 [args]                          # Run ralph2 agent loop
hive ralphsetup <dir>                       # Initialize ralph2 in a project
hive alertme --title "Done" --status success  # Send Telegram alert
hive promptme --title "Continue?" --timeout 60  # Prompt via Telegram
hive tgsetup                                # Configure Telegram bot
```

### AI Tool Wrappers

Sandboxless execution wrappers installed on workers:

| Command | Tool | Description |
|---------|------|-------------|
| `xclaude` | Claude Code | `claude --dangerously-skip-permissions` |
| `xcodex` | Codex | `codex --dangerously-bypass-approvals-and-sandbox` |
| `xamp` | Amp | `amp --dangerously-allow-all` |

## Telegram Notifications

The Telegram bot is set up on the manager and shared with all workers.

```bash
# Alert (one-way notification)
hive alertme --title "Build Complete" --description "All tests passed" --status success

# Prompt (wait for reply)
ANSWER=$(hive promptme --title "Confirm Deploy" --description "Deploy to production?" --timeout 60)
```

## Ralph2

Enhanced AI agent loop for autonomous task execution from a PRD.

```bash
hive ralph2 --status              # Check progress
hive ralph2 --list                # List all tasks
hive ralph2 --tool codex 5        # Run 5 iterations with Codex
hive ralph2 --interactive --alert # Interactive mode with Telegram alerts
```

Initialize in a project:

```bash
hive ralphsetup /path/to/project
cd /path/to/project
cp scripts/ralph/prd.json.example scripts/ralph/prd.json
./ralph2 --status
```

## File Structure

```
agent-setup/
├── hive                        # Central CLI (installed to /usr/local/bin/)
├── setup-manager.sh            # Manager machine setup
├── setup-agent.sh              # Worker machine setup
└── tools/
    ├── hive/
    │   ├── init.sh             # hive init implementation
    │   └── worker.sh           # hive worker subcommands
    ├── ralph2/
    │   ├── ralph2.sh           # Agent loop
    │   ├── ralphsetup          # Project initializer
    │   ├── CLAUDE.md           # Claude Code instructions
    │   ├── CODEX.md            # Codex instructions
    │   ├── prompt.md           # Amp instructions
    │   ├── AGENTS.md           # General agent instructions
    │   ├── prd.json.example    # PRD template
    │   └── skills/             # AI skills (prd, ralph)
    ├── telegram-bot/
    │   ├── agent_telegram_bot.py
    │   ├── agent-telegram-bot.service
    │   ├── tgsetup
    │   ├── alertme
    │   └── promptme
    └── repo-transfer/
        ├── repo-send           # Send repo via git bundles
        ├── repo-fetch          # Fetch repo via git bundles
        └── repo-receive        # Apply received bundle
```

## Configuration

| File | Purpose |
|------|---------|
| `/etc/agent-setup/config.json` | Manager/worker role config |
| `/etc/agent-setup/workers.json` | Registered workers (manager only) |
| `/etc/agent-setup/telegram_config.json` | Telegram bot config (shared) |
| `/etc/agent-setup/tools/` | Installed tool scripts |

## Requirements

- Ubuntu/Debian-based Linux
- Root access for installation
- Internet connection
- Tailscale account (for networking)
- Telegram account (for notifications)

## License

MIT
