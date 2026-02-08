# Codex Account Switcher

Switch between multiple Codex accounts without repeated logins. Linux-only.

Inspired by [codex-auth](https://github.com/Sls0n/codex-account-switcher).

## Install

```bash
# From the repo
./install.sh

# Or directly (downloads the script)
curl -fsSL https://raw.githubusercontent.com/Hyodar/hive/master/tools/codex-account/install.sh | bash

# Custom install directory
INSTALL_DIR=~/.local/bin ./install.sh
```

## Usage

```bash
# Logout, login, and save as a named account (one step)
codex-account setup work

# Save your current login as a named account
codex-account save work

# Switch between them
codex-account use work
codex-account use personal

# Interactive selection (no name = pick from a list)
codex-account use

# See what's saved
codex-account list
codex-account current
```

## Commands

| Command | Description |
|---------|-------------|
| `setup <name>` | Logout, login, and save as a named account |
| `save <name>` | Save current auth as a named account |
| `use [name]` | Switch to a named account (interactive if no name) |
| `list` | List all saved accounts (`*` = active) |
| `current` | Show the currently active account name |

## How It Works

- Manages `~/.codex/auth.json` snapshots in `~/.codex/accounts/`
- Uses symlinks for zero-copy switching
