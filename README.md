# 🐝 Hive

Manage a swarm of AI coding agents across multiple machines.

## 🚀 Quick Start

### 1. Initialize the manager

```bash
git clone <repo-url> && cd agent-setup
sudo ./hive init         # Installs hive, configures Telegram bot + worker registry
sudo tailscale up        # Connect to tailnet
```

### 2. Provision a worker

```bash
# Full setup (desktop + interactive tailscale)
hive worker setup root@192.168.1.100 --name agent-vm-1

# Fully non-interactive with auth key
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx

# CLI-only worker (no desktop, no NoMachine)
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx --no-desktop
```

This SSHes into the machine, installs all AI tools and dependencies, and copies the shared Telegram config. With `--tailscale-key`, Tailscale is configured automatically (no manual SSH step). With `--no-desktop`, NoMachine, Cinnamon, and VSCode are skipped.

### 3. Send work, get results

```bash
cd ~/my-project
hive repo send agent-vm-1 main     # Push repo to worker

hive repo ssh agent-vm-1 # SSH there to e.g. run ralph

hive repo fetch agent-vm-1 main    # Pull results back
```

### Using Ralph

```bash
ralphsetup
```

With any of the AI agents, ask it to "load the PRD skill to develop <your feature>" then discuss requirements, and when done ask it to "load the ralph skill and add tasks to prd.json based on <task file>.

Then:
```bash
ralph2 --tool <claude|codex|amp> <iterations>
```

## 📖 Hive CLI

### Setup

| Command | Description |
|---------|-------------|
| [`hive init`](tools/hive/) | Initialize this machine as manager (Telegram bot + worker registry) |

### [Worker Management](tools/hive/)

| Command | Description |
|---------|-------------|
| [`hive worker setup <host> --name <name> [--tailscale-key <key>] [--no-desktop]`](tools/hive/) | Full remote setup via SSH |
| [`hive worker add <name> [--host <host>]`](tools/hive/) | Register an existing worker |
| `hive worker ls` | List all registered workers |
| `hive worker rm <name>` | Unregister a worker |
| `hive worker ssh <name>` | SSH into a worker |

### [Repo Transfer](tools/repo/)

| Command | Description |
|---------|-------------|
| [`hive repo send <worker> [branch]`](tools/repo/) | Send current repo to a worker via git bundle |
| [`hive repo fetch <worker> [branch]`](tools/repo/) | Fetch repo back from a worker |
| `hive repo ssh <worker>` | SSH into worker at the repo directory |

## 🔧 Worker Tools

Installed as standalone commands on each worker by `hive worker setup`.

| Category | Command | Description |
|----------|---------|-------------|
| **AI Agents** | `xclaude` | `claude --dangerously-skip-permissions` |
| | `xcodex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| | `xamp` | `amp --dangerously-allow-all` |
| **Orchestration** | [`ralph2`](tools/ralph2/) | Autonomous agent loop (Claude, Codex, Amp) |
| | [`ralphsetup <dir>`](tools/ralph2/) | Initialize ralph2 in a project |
| **Notifications** | [`alertme`](tools/telegram-bot/) | Send a one-way Telegram alert |
| | [`promptme`](tools/telegram-bot/) | Send a Telegram prompt and wait for a reply |
| | [`tgsetup`](tools/telegram-bot/) | Configure the Telegram bot |
| **Account Switching** | [`codex-account`](tools/codex-account/) | Manage multiple Codex accounts |
| | [`claude-account`](tools/claude-account/) | Manage multiple Claude Code accounts |

## ⚙️ Configuration

All state lives in `/etc/hive/` on the manager:

| File | Purpose |
|------|---------|
| `config.json` | Manager role config |
| `workers.json` | Registered workers |
| `telegram_config.json` | Telegram bot credentials (shared with workers) |

## 📋 Requirements

- Ubuntu/Debian-based Linux
- Tailscale account (networking between machines)
- Telegram account (notifications)

## License

MIT
