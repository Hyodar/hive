# Repo Transfer

Transfer git repositories between machines using git bundles over SSH. Automatically uses incremental bundles when possible to minimize transfer size.

## Commands

### `repo-send`

Send a git branch to a remote machine.

```bash
repo-send <host> [branch]
repo-send agent-vm main
repo-send agent-vm feature/login -p ~/projects/myapp
repo-send user@10.0.0.5 dev --full
```

| Option | Description |
|--------|-------------|
| `-p, --path <path>` | Remote repo path (overrides remote config) |
| `-f, --full` | Force full bundle (skip incremental) |

### `repo-fetch`

Fetch a git branch back from a remote machine.

```bash
repo-fetch <host> [branch]
repo-fetch agent-vm main
repo-fetch agent-vm feature/login -p ~/projects/myapp
repo-fetch user@10.0.0.5 dev --full
```

| Option | Description |
|--------|-------------|
| `-p, --path <path>` | Remote repo path (overrides remote config) |
| `-f, --full` | Force full bundle (skip incremental) |

### `repo-apply`

Apply a git bundle to a local repository. Used internally by `repo-send` via SSH, but can also be run standalone.

Branch spec: `<bundle-branch>[:<local-branch>]` — maps the bundle's branch to a different local name.

```bash
repo-apply <bundle-file> <branch-spec>
repo-apply /tmp/myrepo.bundle main
repo-apply /tmp/myrepo.bundle main:dev
repo-apply /tmp/myrepo.bundle feature/auth -p ~/projects/myrepo
```

| Option | Description |
|--------|-------------|
| `-p, --path <path>` | Target repo path (default: `<base_path>/<repo-name>`) |

## Remote Config

The remote machine's `~/.repo-transfer/config` controls the default destination:

```ini
base_path=~/projects    # Base directory for repos (default: ~)
```

## How It Works

1. **Send** creates a git bundle (incremental if possible) from the local branch
2. Transfers the bundle to the remote via `scp`
3. **Apply** applies the bundle on the remote — cloning if the repo doesn't exist, or updating the branch if it does
4. **Fetch** reverses the flow — the remote creates a bundle and sends it back
5. State is tracked in `~/.repo-transfer/send/` so subsequent sends are incremental
