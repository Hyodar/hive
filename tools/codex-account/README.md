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

# Switch for the current session (like nvm use)
codex-account use work
codex-account use personal

# Set the default for new shells (like nvm alias default)
codex-account default work

# Interactive selection (no name = pick from a list)
codex-account use

# See what's saved
codex-account list
codex-account current
```

### Shell init

To restore the default account on new shell sessions, add to `.bashrc` or `.zshrc`:

```bash
eval "$(codex-account init)"
```

## Commands

| Command | Description |
|---------|-------------|
| `setup <name>` | Logout, login, and save as a named account |
| `save <name>` | Save current auth as a named account |
| `use [name]` | Switch to a named account for the current session |
| `default [name]` | Set (or show) the default account for new shells |
| `init` | Output shell init script (eval in `.bashrc`/`.zshrc`) |
| `list` | List all saved accounts (`*` = active, default marked) |
| `current` | Show the currently active account name |

## How It Works

- Works like nvm: `use` sets the account for the current session, `default` sets what new shells start with
- Manages `~/.codex/auth.json` snapshots in `~/.codex/accounts/`
- Uses symlinks for zero-copy switching
