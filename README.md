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

**Option A: Deploy to a cloud provider**

```bash
hive worker deploy --at hetzner --name agent-vm-1
```

This orders a dedicated server via the Hetzner Robot API, waits for provisioning, then runs the full worker setup automatically. Credentials are prompted each time. If provisioning takes a while, Ctrl+C and resume later:

```bash
hive worker deploy --continue agent-vm-1
```

**Option B: Set up an existing machine**

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
| `hive init` | Initialize this machine as manager (Telegram bot + worker registry) |

### Worker Management

| Command | Description |
|---------|-------------|
| `hive worker deploy --at <cloud> --name <name>` | Deploy a worker to a cloud provider |
| `hive worker deploy --continue <name>` | Resume a cloud deployment |
| `hive worker setup <host> --name <name> [--tailscale-key <key>] [--no-desktop]` | Full remote setup via SSH |
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
| `config.json` | Manager config (role, cloud defaults) |
| `workers.json` | Registered workers |
| `telegram_config.json` | Telegram bot credentials (shared with workers) |
| `deployments/<name>.json` | Cloud deployment state (for `--continue`) |

### Cloud Defaults

Cloud provider defaults are stored in `config.json` and can be overridden per-deploy with `--product` and `--location`:

```json
{
    "clouds": {
        "hetzner": {
            "default_product": "AX41-NVMe",
            "default_location": "FSN1"
        }
    }
}
```

### Supported Cloud Providers

| Provider | API | Auth | Default Product |
|----------|-----|------|-----------------|
| Hetzner | Robot API (dedicated servers) | Username + password (prompted) | AX41-NVMe |

## 📋 Requirements

- Ubuntu/Debian-based Linux
- Tailscale account (networking between machines)
- Telegram account (notifications)

## License

MIT
