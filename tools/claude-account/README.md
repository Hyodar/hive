# Claude Account Switcher

Switch between multiple Claude Code accounts without repeated logins. Linux-only.

Inspired by [cc-account-switcher](https://github.com/ming86/cc-account-switcher).

## Install

```bash
# From the repo
./install.sh

# Or directly (downloads the script)
curl -fsSL https://raw.githubusercontent.com/Hyodar/hive/master/tools/claude-account/install.sh | bash

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

# Switch for the current session (like nvm use)
claude-account use work
claude-account use personal

# Set the default for new shells (like nvm alias default)
claude-account default work

# Interactive selection (no name = pick from a list)
claude-account use

# See what's saved
claude-account list
claude-account current
```

### Shell init (recommended)

Add to `.bashrc` or `.zshrc` to enable per-session switching:

```bash
eval "$(claude-account init)"
```

This installs shell functions that make `use` truly per-session: each terminal
keeps its own account selection, and a `claude` wrapper lazily restores the right
credentials before each invocation. It also restores the `default` account on
shell startup. Without `init`, `use` changes the global symlink immediately
(affects all terminals).

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
- Manages `~/.claude/.credentials.json` and the `oauthAccount` section of `.claude.json`
- Account snapshots stored in `~/.claude/accounts/`
- Uses symlinks for zero-copy switching
- Requires `jq`
