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
# 1. Create a PRD interactively (launches AI tool to generate prd.json)
prd --tool claude       # or: codex, amp

# 2. Run the agent loop from your project directory
ralph2                          # defaults to claude
ralph2 --tool amp 5             # use amp, max 5 iterations
ralph2 --status                 # check progress
ralph2 --list                   # see all tasks
```

Skills (`prd`, `ralph-tasks`, `ralph`) are installed globally during `hive worker setup` to `~/.claude/skills/`, `~/.config/amp/skills/`, and `~/.codex/skills/`. No per-project setup needed.

## 📖 Hive CLI

### Setup

| Command | Description |
|---------|-------------|
| `hive init` | Initialize this machine as manager (Telegram bot + worker registry) |

### Worker Management

| Command | Description |
|---------|-------------|
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
| | `prd` | Create a PRD and convert to prd.json interactively |
| **Notifications** | `alertme` | Send a one-way Telegram alert |
| | `promptme` | Send a Telegram prompt and wait for a reply |
| | `tgsetup` | Configure the Telegram bot |
| **Account Switching** | `codex-account` | Manage multiple Codex accounts |
| | `claude-account` | Manage multiple Claude Code accounts |

## 🔑 Account Switching

Switch between multiple AI tool accounts without repeated logins. Both tools share the same CLI interface.

Inspired by [codex-auth](https://github.com/Sls0n/codex-account-switcher) and [cc-account-switcher](https://github.com/ming86/cc-account-switcher).

```bash
# Logout, login, and save as a named account (one step)
codex-account setup work       # or: claude-account setup work

# Save your current login as a named account
codex-account save work        # or: claude-account save work

# Switch between them
codex-account use work         # or: claude-account use work
codex-account use personal     # or: claude-account use personal

# Interactive selection (no name = pick from a list)
codex-account use              # or: claude-account use

# See what's saved
codex-account list             # or: claude-account list
codex-account current          # or: claude-account current
```

| Command | Description |
|---------|-------------|
| `setup <name>` | Logout, login, and save as a named account |
| `save <name>` | Save current auth as a named account |
| `use [name]` | Switch to a named account (interactive if no name) |
| `list` | List all saved accounts (`*` = active) |
| `current` | Show the currently active account name |

- **codex-account** manages `~/.codex/auth.json` snapshots in `~/.codex/accounts/`
- **claude-account** manages `~/.claude/.credentials.json` and the `oauthAccount` section of `.claude.json`, stored in `~/.claude/accounts/`
- Both use symlinks for switching (Linux-only)
- `claude-account` requires `jq`

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
