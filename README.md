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
hive worker setup root@192.168.1.100 --name agent-vm-1
```

This SSHes into the machine, installs all AI tools and dependencies, copies the shared Telegram config, and opens a session for you to run `tailscale up`.

### 3. Send work, get results

```bash
cd ~/my-project
hive repo send agent-vm-1 main     # Push repo to worker
# ... worker does its thing ...
hive repo fetch agent-vm-1 main    # Pull results back
```

### 4. Access a worker

```bash
hive worker ssh agent-vm-1         # SSH into the worker
hive repo ssh agent-vm-1           # SSH directly into the repo directory
# Or use NoMachine for GUI access
```

## 📖 Hive CLI

### Setup

| Command | Description |
|---------|-------------|
| `hive init` | Initialize this machine as manager (Telegram bot + worker registry) |

### Worker Management

| Command | Description |
|---------|-------------|
| `hive worker setup <host> --name <name>` | Full remote setup via SSH |
| `hive worker add <name> [--host <host>]` | Register an existing worker |
| `hive worker ls` | List all registered workers |
| `hive worker rm <name>` | Unregister a worker |
| `hive worker ssh <name>` | SSH into a worker |

### Repo Transfer

| Command | Description |
|---------|-------------|
| `hive repo send <worker> [branch]` | Send current repo to a worker via git bundle |
| `hive repo fetch <worker> [branch]` | Fetch repo back from a worker |
| `hive repo ssh <worker>` | SSH into worker at the repo directory |

## 🔧 Worker Tools

Installed as standalone commands on each worker by `hive worker setup`.

| Category | Command | Description |
|----------|---------|-------------|
| **AI Agents** | `xclaude` | `claude --dangerously-skip-permissions` |
| | `xcodex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| | `xamp` | `amp --dangerously-allow-all` |
| **Orchestration** | `ralph2` | Autonomous agent loop (Claude, Codex, Amp) |
| | `ralphsetup <dir>` | Initialize ralph2 in a project |
| **Notifications** | `alertme` | Send a one-way Telegram alert |
| | `promptme` | Send a Telegram prompt and wait for a reply |
| | `tgsetup` | Configure the Telegram bot |

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
