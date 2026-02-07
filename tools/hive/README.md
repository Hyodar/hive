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
- `/etc/hive/workers.json` — worker registry
- `/etc/hive/telegram_config.json` — Telegram bot credentials

## Worker Management

### `hive worker setup`

Provision a remote machine as a hive worker via SSH.

```bash
hive worker setup root@192.168.1.100 --name agent-vm-1
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx
hive worker setup root@192.168.1.100 --name agent-vm-1 --tailscale-key tskey-auth-xxx --no-desktop
```

| Option | Description |
|--------|-------------|
| `--name <name>` | Tailscale machine name (also sets hostname) |
| `--password <pw>` | Password for the `worker` user (default: SSH key only) |
| `--tailscale-key <key>` | Auth key for non-interactive Tailscale setup |
| `--no-desktop` | Skip NoMachine, Cinnamon, and VSCode |

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
```

### `hive worker ls`

List all registered workers.

### `hive worker rm`

Remove a worker from the registry.

```bash
hive worker rm agent-vm-2
```

### `hive worker ssh`

SSH into a registered worker.

```bash
hive worker ssh agent-vm-1
```
