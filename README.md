# Hive

A manager/worker system for orchestrating agentic AI development across multiple machines. The **manager** controls the swarm, and **workers** run AI coding agents autonomously.

## Architecture

```
Manager                          Workers
┌──────────────────┐      ┌──────────────────┐
│  hive init       │      │  ralph2           │
│  hive worker *   │ SSH  │  alertme/promptme │
│  hive repo send  │─────>│  xclaude/xcodex   │
│  hive repo fetch │<─────│  NoMachine + VNC  │
│  Telegram bot    │      │  VSCode           │
└──────────────────┘      └──────────────────┘
        │                         │
        └─── Tailscale VPN ───────┘
```

## Quick Start

### 1. Manager Setup

```bash
git clone <repo-url>
cd agent-setup
sudo ./hive init               # Install hive, Telegram bot, worker registry
sudo tailscale up              # Connect to tailnet
```

### 2. Worker Setup (from Manager)

```bash
hive worker setup root@192.168.1.100 --name agent-vm-1
# SSHes in, installs everything, copies Telegram config,
# opens a session for you to run 'tailscale up'
```

### 3. Send Work

```bash
cd ~/my-project
hive repo send agent-vm-1 main    # Send repo to worker
hive repo fetch agent-vm-1 main   # Fetch results back
```

## Hive CLI

```bash
# Manager initialization
hive init                                   # Set up Telegram bot + worker registry

# Worker management
hive worker setup <host> --name <name>      # Full remote setup via SSH
hive worker add <name> [--host <host>]      # Register without setup
hive worker ls                              # List workers
hive worker rm <name>                       # Remove a worker

# Repo transfer
hive repo send <worker> [branch]            # Send repo to worker
hive repo fetch <worker> [branch]           # Fetch repo from worker
```

## Worker Tools

These are installed as standalone commands on each worker:

| Command | Description |
|---------|-------------|
| `ralph2` | AI agent loop (Claude, Codex, Amp) |
| `ralphsetup` | Initialize ralph2 in a project |
| `alertme` | Send Telegram alert |
| `promptme` | Send Telegram prompt, wait for reply |
| `tgsetup` | Configure Telegram bot |
| `xclaude` | `claude --dangerously-skip-permissions` |
| `xcodex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `xamp` | `amp --dangerously-allow-all` |

## File Structure

```
agent-setup/
├── hive                        # CLI entry point
└── tools/
    ├── hive/
    │   ├── init.sh             # hive init (manager setup)
    │   ├── worker.sh           # hive worker subcommands
    │   └── install-worker.sh   # Internal: runs on worker during setup
    ├── ralph2/
    │   ├── ralph2.sh           # Agent loop
    │   ├── ralphsetup          # Project initializer
    │   ├── CLAUDE.md / CODEX.md / prompt.md / AGENTS.md
    │   ├── prd.json.example
    │   └── skills/
    ├── telegram-bot/
    │   ├── agent_telegram_bot.py
    │   ├── agent-telegram-bot.service
    │   ├── tgsetup / alertme / promptme
    └── repo-transfer/
        ├── repo-send / repo-fetch / repo-receive
```

## Configuration

| File | Purpose |
|------|---------|
| `/etc/agent-setup/config.json` | Role config (manager) |
| `/etc/agent-setup/workers.json` | Registered workers |
| `/etc/agent-setup/telegram_config.json` | Telegram bot (shared with workers) |

## Requirements

- Ubuntu/Debian-based Linux
- Tailscale account
- Telegram account (for notifications)

## License

MIT
