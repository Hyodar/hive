# Claude Account Switcher

Switch between multiple Claude Code accounts without repeated logins. Linux-only.

Inspired by [cc-account-switcher](https://github.com/ming86/cc-account-switcher).

## Install

```bash
# From the repo
./install.sh

# Or directly (downloads the script)
curl -fsSL https://raw.githubusercontent.com/Hyodar/hive/main/tools/claude-account/install.sh | bash

# Custom install directory
INSTALL_DIR=~/.local/bin ./install.sh
```

Requires `jq` (`sudo apt install jq`).

## Usage

```bash
# Logout, login, and save as a named account (one step)
claude-account setup work

# Save your current login as a named account
claude-account save work

# Switch between them
claude-account use work
claude-account use personal

# Interactive selection (no name = pick from a list)
claude-account use

# See what's saved
claude-account list
claude-account current
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

- Manages `~/.claude/.credentials.json` and the `oauthAccount` section of `.claude.json`
- Account snapshots stored in `~/.claude/accounts/`
- Uses symlinks for zero-copy switching
- Requires `jq`
