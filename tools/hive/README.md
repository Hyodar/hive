# Hive

Core manager and worker management scripts.

## Manager Setup

### `hive init`

Initialize the current machine as a hive manager. Installs the `hive` CLI, creates the config and worker registry, sets up the Telegram bot, and runs `tgsetup`.

```bash
sudo hive init
```

Must be run as root. Creates:
- `/etc/hive/config.json` — manager role config
- `/etc/hive/workers.json` — worker registry (also stores per-worker repo mappings)
- `/etc/hive/telegram_config.json` — Telegram bot credentials

## Worker Management

### `hive worker setup`

Provision a remote machine as a hive worker via SSH.

```bash
hive worker setup root@192.168.1.100 --name agent-vm-1
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx --no-desktop
hive worker setup root@192.168.1.100 --name agent-vm-1 --ssh-key ~/.ssh/id_root
```

| Option | Description |
|--------|-------------|
| `--name <name>` | Tailscale machine name (also sets hostname) |
| `--password <pw>` | Password for the `worker` user (default: SSH key only) |
| `--tailscale-key <key>` | Auth key for non-interactive Tailscale setup |
| `--no-desktop` | Skip NoMachine, Cinnamon, and VSCode |
| `--ssh-key <path>` | SSH key to use for accessing this machine (stored in metadata) |

This will:
1. Install git on the remote
2. Send the hive repo via git bundle
3. Run full worker installation (AI tools, agent tools, desktop)
4. Copy Telegram config from the manager
5. Register the worker
6. Open an interactive SSH session for `tailscale up` (skipped with `--tailscale-key`)

### `hive worker add`

Register an existing worker without running setup.

```bash
hive worker add agent-vm-2
hive worker add agent-vm-2 --host user@10.0.0.5
hive worker add agent-vm-2 --host user@10.0.0.5 --ssh-key ~/.ssh/id_agent2
```

| Option | Description |
|--------|-------------|
| `--host <host>` | SSH host (defaults to name for Tailscale DNS) |
| `--ssh-key <path>` | SSH key for accessing this worker (stored in metadata) |

### `hive worker ls`

List all registered workers.

### `hive worker rm`

Remove a worker from the registry.

```bash
hive worker rm agent-vm-2
```

### `hive worker set quick-ssh`

Set up or remove passwordless SSH to a worker. Generates an unencrypted per-worker quick-ssh key in `/etc/hive/ssh/` and copies it to the worker. Uses the worker's configured `ssh_key` (from `--ssh-key` on add/setup) to authenticate the initial copy. After this, all hive SSH commands use the quick-ssh key automatically.

```bash
# Enable — generates key and copies to worker
hive worker set quick-ssh --name agent-vm-1 true

# Disable — removes key from worker and deletes local key files
hive worker set quick-ssh --name agent-vm-1 false
```

SSH identity resolution order (used by all hive SSH commands):
1. Per-worker quick-ssh key (`/etc/hive/ssh/<worker>_ed25519`) — if quick-ssh is enabled
2. Worker's configured `ssh_key` — if set via `--ssh-key` on add/setup
3. Default SSH auth (agent, config, etc.)

### `hive worker ssh`

SSH into a registered worker.

```bash
hive worker ssh agent-vm-1
```
