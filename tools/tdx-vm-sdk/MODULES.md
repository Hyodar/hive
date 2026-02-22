# TDX VM SDK — Module & Package System Design

A module system for composing TDX VM images from reusable, versioned,
integrity-verified components.

## Table of Contents

1. [Goals](#1-goals)
2. [Concepts](#2-concepts)
3. [Module Definition — `module.toml`](#3-module-definition--moduletoml)
4. [Image Manifest — `tdx.toml`](#4-image-manifest--tdxtoml)
5. [Lockfile — `tdx.lock`](#5-lockfile--tdxlock)
6. [Module Sources](#6-module-sources)
7. [Resolution & Integrity](#7-resolution--integrity)
8. [Python DSL Integration](#8-python-dsl-integration)
9. [CLI Commands](#9-cli-commands)
10. [Module Composition & Conflicts](#10-module-composition--conflicts)
11. [Module Store Layout](#11-module-store-layout)
12. [Worked Examples](#12-worked-examples)
13. [Registry (Future)](#13-registry-future)
14. [Design Decisions & Rationale](#14-design-decisions--rationale)

---

## 1. Goals

**Make modules trivially easy to create.** A module author should be able to go
from "I have a Nethermind build" to "I have a publishable module" in under five
minutes. A single `module.toml` file is all you need.

**Reproducibility by default.** Every remote module is pinned to an exact git
commit and verified by content hash. The lockfile ensures that the same `tdx
build` invocation today produces the same image tomorrow.

**Local-first, remote-capable.** Modules can be a directory on your filesystem.
When you're ready to share, push it to a git repo and reference it by tag. No
registry needed (though one can be added later).

**Composability.** An image is built by stacking modules. Each module contributes
builds, files, services, lifecycle hooks, and packages. Conflicts are detected
early and reported clearly.

**Escape hatches.** The module system sits on top of the existing Python DSL. You
can use `tdx.toml` alone (pure declarative), `TDXfile` alone (pure Python), or
both (modules from `tdx.toml`, custom logic in `TDXfile`). The module format
itself supports inline scripts for anything the declarative surface doesn't
cover.

---

## 2. Concepts

### The three files

| File | Who writes it | Purpose | Analogy |
|------|--------------|---------|---------|
| `module.toml` | Module author | Defines what a module provides | npm's `package.json` (for a library) |
| `tdx.toml` | Image builder | Declares which modules to compose | npm's `package.json` (for an app) |
| `tdx.lock` | Generated | Pins exact commits & content hashes | npm's `package-lock.json` |

### What a module provides

A module is a self-contained component that can contribute any combination of:

- **Build artifacts** — compiled binaries (Go, Rust, .NET, custom)
- **System packages** — distro packages to `apt install`
- **Configuration files** — static files or Jinja2 templates
- **Systemd services** — unit files with hardening, dependencies, users
- **Lifecycle hooks** — commands for any mkosi phase (prepare, postinst, etc.)
- **Variables** — configurable parameters with defaults and descriptions
- **Dependencies** — other modules this module requires

### Module identity

Every module has a **name** (short, kebab-case identifier) and an optional
**version** (semver). When fetched from a git repo, the module is additionally
identified by its **source** (repo URL + path within repo) and **resolved ref**
(exact commit SHA).

---

## 3. Module Definition — `module.toml`

This is the file a module author creates. It lives at the root of a module
directory (which can be a standalone repo, a subdirectory in a monorepo, or a
local folder in your project).

### 3.1 Minimal example

The simplest possible module — a static binary with a service:

```toml
[module]
name = "my-agent"
version = "0.1.0"
description = "A simple monitoring agent"

[build]
type = "go"
src = "."
go_version = "1.22"
output = "/usr/local/bin/my-agent"

[service]
exec = "/usr/local/bin/my-agent"
restart = "always"
```

That's it. This module, when included in an image, will:
1. Compile the Go project in the module directory
2. Install the binary at `/usr/local/bin/my-agent`
3. Create a systemd service that runs it
4. Create a service user (auto-derived from module name)

### 3.2 Full schema

```toml
# ─── Module identity ───────────────────────────────────────────────
[module]
name = "nethermind"                     # Required. Kebab-case identifier.
version = "1.30.0"                      # Semver. Used for display & lockfile.
description = "Nethermind Ethereum execution client"
license = "LGPL-3.0"
authors = ["Nethermind <hello@nethermind.io>"]

# Module-level dependencies on other modules (resolved transitively).
# Values use the same source syntax as tdx.toml [modules.*] entries.
dependencies = [
    "dotnet-runtime",       # Bare name = resolved from registry or parent manifest
]

# ─── Build ─────────────────────────────────────────────────────────
# A module has exactly one [build] section, or none (for config-only modules).
[build]
type = "dotnet"                         # "go" | "rust" | "dotnet" | "script"
src = "."                               # Path relative to module root
sdk_version = "10.0"                    # Builder-specific config
project = "src/Nethermind/Nethermind.Runner"
output = "/opt/nethermind/"
self_contained = true
build_deps = ["libsnappy-dev", "libgflags-dev"]

# Environment variables set during build
[build.env]
DOTNET_CLI_TELEMETRY_OPTOUT = "1"

# ─── Packages ─────────────────────────────────────────────────────
[packages]
runtime = ["ca-certificates", "libsnappy1v5"]   # Installed in the final image
build = ["libsnappy-dev", "libgflags-dev"]       # Available during build only

# ─── Configuration files ──────────────────────────────────────────
[[config.files]]
src = "files/nethermind-defaults"
dest = "/etc/default/nethermind"

[[config.templates]]
src = "templates/nethermind.cfg.j2"
dest = "/etc/nethermind/config.json"

[[config.templates]]
src = "templates/logging.j2"
dest = "/etc/nethermind/NLog.config"

# ─── Skeleton files (before package manager) ──────────────────────
[[skeleton]]
dest = "/etc/apt/apt.conf.d/99nethermind"
content = """
APT::Install-Recommends "false";
APT::Install-Suggests "false";
"""

# ─── Service ──────────────────────────────────────────────────────
# A module can define zero or more services.
[service]
exec = "/opt/nethermind/nethermind --config $NETHERMIND_CONFIG_PATH"
after = ["network-online.target"]
requires = []
restart = "always"
user = "nethermind"                     # Auto-created if doesn't exist

# Systemd hardening (maps to unit file directives)
[service.hardening]
protect_system = "strict"
read_write_paths = ["/var/lib/nethermind"]
memory_max = "8G"
limit_nofile = 65535
private_tmp = true
no_new_privileges = true

# Multiple services: use [[services]] array instead of [service]
# [[services]]
# name = "nethermind-pruner"
# exec = "/opt/nethermind/nethermind prune --datadir /var/lib/nethermind"
# type = "oneshot"

# ─── Variables ────────────────────────────────────────────────────
# Configurable parameters. Image builders set these in tdx.toml.
# Used in templates (Jinja2 {{ var }}) and service exec lines ($VAR).

[variables.NETHERMIND_NETWORK]
default = "mainnet"
description = "Ethereum network (mainnet, holesky, sepolia)"
allowed = ["mainnet", "holesky", "sepolia"]

[variables.NETHERMIND_CONFIG_PATH]
default = "/etc/nethermind/config.json"
description = "Path to Nethermind JSON config file"

[variables.NETHERMIND_DATADIR]
default = "/var/lib/nethermind"
description = "Path to chain data directory"

[variables.NETHERMIND_RPC_PORT]
default = "8545"
description = "JSON-RPC port"

# ─── Lifecycle hooks ─────────────────────────────────────────────
# Commands or scripts to run at specific mkosi phases.

[lifecycle]
# Each phase is an array of commands (strings) or script references.
prepare = [
    "pip install --root $BUILDROOT web3",
]

postinst = [
    "mkdir -p /var/lib/nethermind",
    "chown nethermind:nethermind /var/lib/nethermind",
    "chmod 750 /var/lib/nethermind",
]

finalize = []
clean = ["rm -rf ./obj ./bin"]

# For longer scripts, reference a file in the module directory:
# postinst_scripts = ["scripts/setup.sh", "scripts/harden.sh"]

# ─── Boot-time initialization ────────────────────────────────────
[boot]
commands = []
# on_boot_scripts = ["scripts/init-data.sh"]
```

### 3.3 Builder-specific `[build]` fields

Each `type` value enables different fields under `[build]`:

**`type = "go"`**
```toml
[build]
type = "go"
src = "."
go_version = "1.22"
output = "/usr/local/bin/my-app"
ldflags = "-s -w -X main.version=1.0.0"
```

**`type = "rust"`**
```toml
[build]
type = "rust"
src = "."
toolchain = "nightly-2024-12-01"
features = ["tdx", "sgx"]
output = "/usr/local/bin/raiko"
build_deps = ["libssl-dev", "pkg-config"]
```

**`type = "dotnet"`**
```toml
[build]
type = "dotnet"
src = "."
sdk_version = "10.0"
project = "src/Nethermind/Nethermind.Runner"
output = "/opt/nethermind/"
self_contained = true
```

**`type = "script"`**
```toml
[build]
type = "script"
src = "."
build_script = "make release STATIC=1"
build_deps = ["cmake", "libssl-dev"]

# For script builds, artifacts maps build paths to image paths
[build.artifacts]
"build/my-tool" = "/usr/local/bin/my-tool"
"build/default.conf" = "/etc/my-tool/config.toml"
```

**No build (config-only module):**
```toml
[build]
type = "none"
```
Or simply omit the `[build]` section entirely. Config-only modules are useful
for shared hardening profiles, base configurations, or template collections.

### 3.4 Config-only module example

A reusable hardening profile with no build step:

```toml
[module]
name = "tdx-hardening"
version = "1.0.0"
description = "Standard TDX VM hardening: sysctl, systemd debloat, firewall"

[packages]
runtime = ["iptables"]

[[config.files]]
src = "files/99-tdx-hardening.conf"
dest = "/etc/sysctl.d/99-tdx-hardening.conf"

[lifecycle]
postinst = [
    # Debloat systemd
    "rm -rf /usr/lib/systemd/system/getty*",
    "rm -rf /usr/lib/systemd/system/serial-getty*",
    "rm -rf /usr/lib/systemd/system/systemd-homed*",
    "rm -rf /usr/lib/systemd/system/systemd-userdbd*",
    "rm -rf /usr/lib/systemd/system/systemd-firstboot*",
    # Lock down kernel parameters
    "sysctl --system",
]
```

---

## 4. Image Manifest — `tdx.toml`

This is the file an image builder creates at the root of their project. It
declares the base image settings and which modules to compose.

### 4.1 Full schema

```toml
# ─── Image identity ───────────────────────────────────────────────
[image]
name = "nethermind-prover"
base = "debian/bookworm"

# ─── Kernel ───────────────────────────────────────────────────────
[kernel]
version = "6.8"
cmdline = "console=hvc0 root=/dev/vda2 ro quiet mitigations=auto,nosmt"

[kernel.extra_config]
CONFIG_VHOST_VSOCK = "y"

# ─── Partitions ───────────────────────────────────────────────────
[[partitions]]
mountpoint = "/"
fs = "ext4"
size = "2G"

[[partitions]]
mountpoint = "/var"
fs = "ext4"
size = "20G"

# ─── Encryption ───────────────────────────────────────────────────
[encryption]
type = "luks2"
key_source = "tpm"

# ─── Network ──────────────────────────────────────────────────────
[network]
vsock = true
firewall_rules = [
    "ACCEPT tcp 8545",
    "ACCEPT tcp 30303",
    "DROP all",
]

# ─── System packages (in addition to what modules declare) ────────
[packages]
runtime = ["busybox", "curl"]

# ─── Modules ──────────────────────────────────────────────────────
# Each key under [modules] is the local name for a module dependency.
# The value specifies the source and any variable overrides.

# Remote module: git repo with a tag
[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"

# Remote module: git repo with a specific commit (most precise)
[modules.raiko]
git = "https://github.com/example/raiko-tdx-module"
rev = "a1b2c3d4e5f6"

# Remote module: subdirectory of a monorepo
[modules.monitoring]
git = "https://github.com/org/tdx-modules"
path = "modules/monitoring"
branch = "main"

# Local module: a directory in your project
[modules.prover]
path = "./modules/prover"

# Config-only module: just hardening scripts
[modules.hardening]
git = "https://github.com/org/tdx-base-modules"
path = "hardening"
tag = "v1.0.0"

# ─── Variable overrides ──────────────────────────────────────────
# Override module-declared variables. These flow into templates,
# service exec lines, and lifecycle scripts.

[modules.nethermind.vars]
NETHERMIND_NETWORK = "holesky"
NETHERMIND_RPC_PORT = "8547"

[modules.raiko.vars]
RAIKO_CHAIN_ID = "17000"

# ─── Profiles ─────────────────────────────────────────────────────
[profiles.dev]
extra_packages = ["strace", "gdb", "vim", "htop"]

[profiles.dev.ssh]
enabled = true
key_delivery = "http"

# Profile-specific module additions
[profiles.dev.modules.debug-tools]
path = "./modules/debug-tools"

[profiles.azure]
cloud = "azure"
attestation_backend = "azure"

# ─── Extra lifecycle hooks (image-level, not module-level) ────────
[lifecycle]
sync = ["git submodule update --init --recursive"]
postoutput = ["sha256sum $OUTPUTDIR/*.raw > $OUTPUTDIR/SHA256SUMS"]
clean = ["rm -rf ./build-cache/"]

# ─── Boot-time (image-level) ─────────────────────────────────────
[boot]
commands = ["/usr/local/bin/tdx-init --format on_initialize --key tpm"]
```

### 4.2 Module source syntax

The `[modules.<name>]` section supports these source fields:

| Field | Description | Example |
|-------|-------------|---------|
| `path` | Local filesystem path (relative to tdx.toml) | `"./modules/prover"` |
| `git` | Git repository URL | `"https://github.com/org/repo"` |
| `tag` | Git tag (preferred for releases) | `"v1.30.0"` |
| `branch` | Git branch (resolved to commit at lock time) | `"main"` |
| `rev` | Exact git commit SHA | `"a1b2c3d4e5f6..."` |
| `path` (with `git`) | Subdirectory within the git repo | `"modules/nethermind"` |

**Priority rules for git refs:**
1. `rev` (exact commit) takes highest priority — branch and tag are ignored
2. `tag` takes priority over `branch`
3. `branch` is resolved to its HEAD commit at lock time
4. If none are specified with `git`, defaults to the repo's default branch

**Local modules** use only `path` (no `git`). For local modules, the lockfile
stores a content hash rather than a git commit.

---

## 5. Lockfile — `tdx.lock`

The lockfile is generated by `tdx lock` (or automatically by `tdx build` on
first run). It records the exact resolved state of every module dependency.

### 5.1 Format

TOML, to match the manifest. Human-readable but not meant to be hand-edited.

```toml
# Auto-generated by tdx lock. Do not edit manually.
# To update, run: tdx lock --update [module-name]

version = 1

[[module]]
name = "nethermind"
source = "git"
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"
resolved_rev = "8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a"
integrity = "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
resolved_at = "2026-02-22T10:30:00Z"

[[module]]
name = "raiko"
source = "git"
git = "https://github.com/example/raiko-tdx-module"
resolved_rev = "a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4"
integrity = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
resolved_at = "2026-02-22T10:30:00Z"

[[module]]
name = "monitoring"
source = "git"
git = "https://github.com/org/tdx-modules"
path = "modules/monitoring"
branch = "main"
resolved_rev = "1a2b3c4d5e6f7890abcdef1234567890abcdef12"
integrity = "sha256:f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2"
resolved_at = "2026-02-22T10:30:00Z"

[[module]]
name = "prover"
source = "local"
path = "./modules/prover"
integrity = "sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
resolved_at = "2026-02-22T10:30:00Z"

[[module]]
name = "hardening"
source = "git"
git = "https://github.com/org/tdx-base-modules"
path = "hardening"
tag = "v1.0.0"
resolved_rev = "deadbeef1234567890abcdef1234567890abcdef"
integrity = "sha256:7d865e959b2466918c9863afca942d0fb89d7c9ac0c99bafc3749504ded97730"
resolved_at = "2026-02-22T10:30:00Z"
```

### 5.2 What gets locked

| Module source | What's pinned | Integrity covers |
|---------------|--------------|-----------------|
| `git` + `tag` | Resolved commit SHA | Hash of module directory contents |
| `git` + `branch` | Resolved commit SHA | Hash of module directory contents |
| `git` + `rev` | The rev itself | Hash of module directory contents |
| `path` (local) | Nothing (always current) | Hash of module directory contents |

### 5.3 Integrity computation

The `integrity` field is a SHA-256 hash of the module's content, computed as:

```
1. List all files in the module directory (respecting .gitignore)
2. Sort filenames lexicographically
3. For each file: hash(relative_path + "\0" + file_contents)
4. Hash the concatenation of all per-file hashes
```

This is similar to Go's `go.sum` approach — it's a content hash, not a commit
hash. Two different commits with identical module contents produce the same
integrity hash. This means:
- Integrity verification catches tampering even if the git host is compromised
- Locally cached modules can be verified without network access
- Rebased or cherry-picked commits that don't change content still validate

### 5.4 Lock update semantics

| Command | What happens |
|---------|-------------|
| `tdx lock` | Resolve all unlocked modules. Locked modules are not touched. |
| `tdx lock --update` | Re-resolve ALL modules from their sources. |
| `tdx lock --update nethermind` | Re-resolve only `nethermind`. |
| `tdx lock --update nethermind raiko` | Re-resolve specific modules. |
| `tdx build` (no lockfile exists) | Implicitly runs `tdx lock` first. |
| `tdx build` (lockfile exists) | Uses locked versions. Fails if manifest has unlocked modules. |
| `tdx build --frozen` | Fails if lockfile is missing or out of date. For CI. |

---

## 6. Module Sources

### 6.1 Local modules

```toml
[modules.prover]
path = "./modules/prover"
```

- Resolved relative to the directory containing `tdx.toml`
- Must contain a `module.toml` at its root
- Lockfile stores a content hash (for integrity checking) but no git ref
- Content hash is always recomputed — local modules are "always fresh"
- Useful during development before publishing to a git repo

### 6.2 Git modules

```toml
[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"
```

- Cloned/fetched into a local store (`~/.cache/tdx/modules/`)
- The `path` field (optional, default `"."`) specifies the subdirectory within
  the repo that contains the `module.toml`
- Supports HTTPS and SSH URLs
- Authentication: uses the system's git credential helpers

**Monorepo support:**
```toml
[modules.nethermind]
git = "https://github.com/org/tdx-modules"
path = "nethermind"                          # Subdir within repo
tag = "nethermind-v1.30.0"                   # Tag can be module-specific
```

Multiple modules can reference the same git repo with different `path` values.
The repo is only cloned once.

### 6.3 Git ref resolution

| In `tdx.toml` | What `tdx lock` does |
|----------------|---------------------|
| `tag = "v1.0"` | `git ls-remote --tags` → resolve to commit SHA |
| `branch = "main"` | `git ls-remote --heads` → resolve HEAD to commit SHA |
| `rev = "abc123..."` | Used directly (must be full 40-char SHA) |
| (none specified) | Resolve default branch HEAD to commit SHA |

After resolution, the lockfile always contains the full 40-character commit SHA
in `resolved_rev`. The original `tag`/`branch` is also preserved for human
readability.

### 6.4 Registry modules (future)

```toml
[modules.nethermind]
version = "^1.30"
```

See [Section 13: Registry](#13-registry-future) for the future design. When no
`git` or `path` is specified and only a `version` is given, the module is
resolved from the registry.

---

## 7. Resolution & Integrity

### 7.1 Resolution flow

```
tdx build
  │
  ├─ Parse tdx.toml
  │    └─ Extract [modules.*] declarations
  │
  ├─ Check tdx.lock
  │    ├─ Lockfile exists & up to date → use locked versions
  │    ├─ Lockfile exists but stale → error (run tdx lock --update)
  │    └─ No lockfile → run resolution (tdx lock)
  │
  ├─ For each module:
  │    ├─ Resolve source (local path or git fetch)
  │    ├─ Locate module.toml in the resolved directory
  │    ├─ Parse module.toml
  │    ├─ Compute content hash
  │    ├─ Verify against lockfile integrity (if locked)
  │    │    └─ Mismatch → error: "integrity check failed for 'nethermind'"
  │    └─ Resolve transitive dependencies
  │
  ├─ Detect conflicts (see Section 10)
  │
  ├─ Merge all modules into a single ResolvedImage
  │    ├─ Builds: ordered by module dependency graph
  │    ├─ Packages: union of all runtime packages
  │    ├─ Files: merged (conflict = error)
  │    ├─ Services: merged (name conflict = error)
  │    ├─ Lifecycle hooks: concatenated per phase, ordered by dependency graph
  │    └─ Variables: module defaults, overridden by tdx.toml [modules.*.vars]
  │
  └─ Compile to mkosi (existing MkosiCompiler)
```

### 7.2 Integrity verification

On every `tdx build`:

1. **Locked modules**: Content hash is compared against `integrity` in
   `tdx.lock`. If they differ, the build fails with a clear error message:
   ```
   Error: integrity check failed for module 'nethermind'
     Expected: sha256:b94d27b9...
     Got:      sha256:e3b0c442...

   The module contents have changed since the lockfile was generated.
   If this is expected, run: tdx lock --update nethermind
   ```

2. **Local modules**: Content hash is recomputed and stored in the lockfile.
   A warning is shown if the hash changed since the last lock:
   ```
   Warning: local module 'prover' has changed since last lock
     Previous: sha256:d7a8fbb3...
     Current:  sha256:a1b2c3d4...
   ```

3. **`--frozen` mode** (CI): Any hash mismatch or missing lock entry is a hard
   error. No network access is attempted.

### 7.3 Staleness detection

The lockfile is considered stale if:
- A module in `tdx.toml` has no corresponding entry in `tdx.lock`
- A module in `tdx.lock` is no longer referenced in `tdx.toml`
- The source fields (git URL, path) changed in `tdx.toml` but `tdx.lock`
  still has the old source

---

## 8. Python DSL Integration

The module system integrates with the existing TDXfile Python DSL. Both can
coexist: `tdx.toml` for dependency management, `TDXfile` for custom logic.

### 8.1 Using modules from Python

When both `tdx.toml` and a `TDXfile` exist, the resolved modules are available
as Python objects:

```python
from tdx import Image, modules

image = Image(
    name="nethermind-prover",
    base="debian/bookworm",
)

# Import resolved modules (declared in tdx.toml)
nethermind = modules.nethermind
prover = modules.prover

# Use module builds
image.build(nethermind.build, prover.build)

# Override a module's service config programmatically
nethermind.service.extra_unit["Service"]["MemoryMax"] = "16G"
image.apply(nethermind, prover)

# Or apply all modules declared in tdx.toml at once
image.apply_all()

# You can still add image-level customization
image.run("echo 'custom setup'")
```

### 8.2 Inline module definition in Python

For modules that don't need a separate `module.toml`, you can define them
inline:

```python
from tdx import Image, Module, Build

monitoring = Module(
    name="monitoring",
    build=Build.go(
        name="monitoring-agent",
        src="./monitoring/",
        go_version="1.22",
        output="/usr/local/bin/monitoring-agent",
    ),
    service={
        "exec": "/usr/local/bin/monitoring-agent",
        "restart": "always",
    },
    packages=["ca-certificates"],
)

image = Image(name="my-image", base="debian/bookworm")
image.apply(monitoring)
```

### 8.3 Precedence

When both `tdx.toml` and `TDXfile` exist:

1. `tdx.toml` is parsed first — module sources are resolved and locked
2. `TDXfile` is evaluated with resolved modules available via `tdx.modules`
3. If `TDXfile` calls `image.apply_all()`, all `tdx.toml` modules are applied
4. `TDXfile` can override anything — it has the final say
5. If no `TDXfile` exists, `tdx.toml` modules are applied automatically

### 8.4 Pure Python mode (no tdx.toml)

You can reference remote modules directly from Python:

```python
from tdx import Image, RemoteModule

nethermind = RemoteModule(
    git="https://github.com/NethermindEth/nethermind-tdx-module",
    tag="v1.30.0",
)

image = Image(name="my-image", base="debian/bookworm")
image.apply(nethermind)
```

This still generates lockfile entries. The lockfile is always the source of
truth for reproducibility.

---

## 9. CLI Commands

### 9.1 Module management commands

```bash
# ─── Lock / resolve ──────────────────────────────────────────────

# Resolve all module sources and create/update tdx.lock
tdx lock

# Re-resolve all modules (update everything)
tdx lock --update

# Re-resolve specific modules
tdx lock --update nethermind raiko

# Show what would change without writing
tdx lock --dry-run

# ─── Build (unchanged, but now module-aware) ─────────────────────

# Build: resolves modules, compiles, invokes mkosi
tdx build

# Build with frozen lockfile (CI mode — no network, no resolution)
tdx build --frozen

# Emit mkosi configs (now includes module-contributed configs)
tdx build --emit-mkosi ./out/

# ─── Inspect ─────────────────────────────────────────────────────

# Show resolved image config including all modules
tdx inspect

# Show only module information
tdx modules list

# Show details for a specific module
tdx modules show nethermind

# Show the dependency graph
tdx modules graph

# ─── Module development ──────────────────────────────────────────

# Initialize a new module in a directory
tdx modules init ./my-module/

# Validate a module.toml
tdx modules validate ./my-module/

# Compute the content hash for a module
tdx modules hash ./my-module/
```

### 9.2 `tdx modules init` — scaffolding

Interactive scaffolding for new modules:

```
$ tdx modules init ./nethermind-module/

Module name: nethermind
Description: Nethermind Ethereum execution client
Build type (go/rust/dotnet/script/none): dotnet

Created ./nethermind-module/
  ├── module.toml       # Module manifest
  ├── templates/        # Config templates directory
  ├── files/            # Static files directory
  └── scripts/          # Lifecycle scripts directory

Edit module.toml to configure your module.
```

### 9.3 `tdx modules list` — overview

```
$ tdx modules list

Module          Source                                    Version   Locked
─────────────── ───────────────────────────────────────── ───────── ──────
nethermind      git:NethermindEth/nethermind-tdx-module   v1.30.0   ✓ 8f3a2b1
raiko           git:example/raiko-tdx-module              -         ✓ a1b2c3d
monitoring      git:org/tdx-modules#modules/monitoring    -         ✓ 1a2b3c4
prover          local:./modules/prover                    0.1.0     ✓ (local)
hardening       git:org/tdx-base-modules#hardening        v1.0.0    ✓ deadbee

5 modules (4 remote, 1 local)
```

### 9.4 `tdx modules graph` — dependency visualization

```
$ tdx modules graph

nethermind-prover
├── nethermind (git:NethermindEth/nethermind-tdx-module@v1.30.0)
│   └── dotnet-runtime (git:org/tdx-base-modules#dotnet-runtime@v10.0)
├── raiko (git:example/raiko-tdx-module@a1b2c3d)
├── monitoring (git:org/tdx-modules#modules/monitoring@main)
├── prover (local:./modules/prover)
└── hardening (git:org/tdx-base-modules#hardening@v1.0.0)
```

---

## 10. Module Composition & Conflicts

When multiple modules are composed into one image, their contributions are
merged. Some merges are straightforward (union of packages), others need
conflict detection.

### 10.1 Merge rules

| Contribution | Merge strategy | On conflict |
|-------------|---------------|-------------|
| Packages (runtime) | Union, deduplicate | Never conflicts |
| Packages (build) | Union, deduplicate | Never conflicts |
| Build artifacts | Ordered by dependency graph | Error if two modules produce same output path |
| Files (config.files) | Merged | Error if two modules write to same `dest` path |
| Templates | Merged | Error if two modules write to same `dest` path |
| Skeleton files | Merged | Error if two modules write to same `dest` path |
| Services | Merged by name | Error if two modules define service with same name |
| Lifecycle hooks | Concatenated per phase | Order determined by dependency graph |
| Variables | Merged by name | Error if two modules define same variable with different defaults |

### 10.2 Conflict resolution

When a conflict is detected, the build fails with a clear message:

```
Error: file conflict between modules 'nethermind' and 'monitoring'
  Both write to: /etc/default/node-config

Resolution options:
  1. Remove the conflicting file from one module
  2. Use [modules.nethermind.exclude] to skip specific files
  3. Use a post-install hook to merge the files
```

**Exclude mechanism:**

```toml
# In tdx.toml — exclude specific contributions from a module
[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"
exclude_files = ["/etc/default/node-config"]
exclude_services = ["nethermind-pruner"]
```

### 10.3 Ordering

Module contributions are applied in dependency-graph order:

1. Modules with no dependencies are applied first
2. If module A depends on module B, B is applied before A
3. Within the same dependency level, modules are applied in the order they
   appear in `tdx.toml`
4. Lifecycle hooks within the same phase follow the same ordering

This means a module's postinst hooks can rely on files and users created by
its dependencies' postinst hooks.

---

## 11. Module Store Layout

Fetched modules are cached locally to avoid re-downloading:

```
~/.cache/tdx/
├── modules/                              # Module cache
│   ├── github.com/
│   │   ├── NethermindEth/
│   │   │   └── nethermind-tdx-module/
│   │   │       └── 8f3a2b1c.../         # Keyed by commit SHA
│   │   │           ├── module.toml
│   │   │           ├── templates/
│   │   │           └── ...
│   │   └── org/
│   │       └── tdx-modules/
│   │           └── 1a2b3c4d.../
│   │               ├── modules/
│   │               │   └── monitoring/
│   │               │       └── module.toml
│   │               └── ...
│   └── gitlab.com/
│       └── ...
└── git/                                  # Bare git repos for efficient fetching
    ├── github.com-NethermindEth-nethermind-tdx-module.git
    ├── github.com-org-tdx-modules.git
    └── ...
```

**Cache behavior:**
- Bare git repos are kept in `~/.cache/tdx/git/` for efficient incremental
  fetches (only fetch new commits, not full clones each time)
- Module checkouts are extracted into `~/.cache/tdx/modules/` keyed by commit
  SHA — these are immutable once extracted
- `tdx cache clean` removes everything
- `tdx cache clean --modules` removes only module checkouts (keeps bare repos)
- Cache location can be overridden with `$TDX_CACHE_DIR` or in `~/.config/tdx/config.toml`

---

## 12. Worked Examples

### 12.1 Creating a Nethermind module

Starting from scratch — publishing a module for Nethermind:

```bash
# Scaffold the module
$ tdx modules init ./nethermind-module/
Module name: nethermind
Description: Nethermind Ethereum execution client
Build type: dotnet
```

Edit `nethermind-module/module.toml`:

```toml
[module]
name = "nethermind"
version = "1.30.0"
description = "Nethermind Ethereum execution client for TDX VMs"
license = "LGPL-3.0"

[build]
type = "dotnet"
src = "."
sdk_version = "10.0"
project = "src/Nethermind/Nethermind.Runner"
output = "/opt/nethermind/"
self_contained = true
build_deps = ["libsnappy-dev", "libgflags-dev"]

[build.env]
DOTNET_CLI_TELEMETRY_OPTOUT = "1"

[packages]
runtime = ["ca-certificates", "libsnappy1v5"]

[[config.templates]]
src = "templates/nethermind.cfg.j2"
dest = "/etc/nethermind/config.json"

[service]
exec = "/opt/nethermind/nethermind --config /etc/nethermind/config.json --datadir $NETHERMIND_DATADIR"
after = ["network-online.target"]
restart = "always"
user = "nethermind"

[service.hardening]
protect_system = "strict"
read_write_paths = ["/var/lib/nethermind"]
memory_max = "8G"
limit_nofile = 65535

[variables.NETHERMIND_NETWORK]
default = "mainnet"
description = "Ethereum network"
allowed = ["mainnet", "holesky", "sepolia"]

[variables.NETHERMIND_DATADIR]
default = "/var/lib/nethermind"
description = "Chain data directory"

[lifecycle]
postinst = [
    "mkdir -p /var/lib/nethermind",
    "chown nethermind:nethermind /var/lib/nethermind",
    "chmod 750 /var/lib/nethermind",
]
```

Add a config template at `nethermind-module/templates/nethermind.cfg.j2`:

```json
{
  "Init": {
    "ChainSpecPath": "chainspec/{{ NETHERMIND_NETWORK }}.json",
    "BaseDbPath": "{{ NETHERMIND_DATADIR }}/db",
    "LogFileName": "/var/log/nethermind/nethermind.log"
  },
  "JsonRpc": {
    "Enabled": true,
    "Host": "127.0.0.1",
    "Port": 8545
  }
}
```

Validate and push:

```bash
$ tdx modules validate ./nethermind-module/
✓ module.toml is valid
✓ Build type 'dotnet' config is complete
✓ Template 'templates/nethermind.cfg.j2' exists
✓ All variables referenced in templates are declared
✓ Service config is valid

$ cd nethermind-module && git init && git add -A && git commit -m "v1.30.0"
$ git tag v1.30.0
$ git remote add origin https://github.com/NethermindEth/nethermind-tdx-module
$ git push origin main --tags
```

### 12.2 Consuming the Nethermind module in an image

Create `tdx.toml` in your image project:

```toml
[image]
name = "nethermind-prover-node"
base = "debian/bookworm"

[kernel]
version = "6.8"
cmdline = "console=hvc0 root=/dev/vda2 ro quiet"

[[partitions]]
mountpoint = "/"
fs = "ext4"
size = "2G"

[[partitions]]
mountpoint = "/var"
fs = "ext4"
size = "20G"

[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"

[modules.nethermind.vars]
NETHERMIND_NETWORK = "holesky"

[modules.prover]
path = "./modules/prover"

[modules.hardening]
git = "https://github.com/org/tdx-base-modules"
path = "hardening"
tag = "v1.0.0"

[lifecycle]
postoutput = ["sha256sum $OUTPUTDIR/*.raw > $OUTPUTDIR/SHA256SUMS"]

[boot]
commands = ["/usr/local/bin/tdx-init --format on_initialize --key tpm"]
```

Build:

```bash
$ tdx lock
Resolving modules...
  nethermind: git:NethermindEth/nethermind-tdx-module@v1.30.0 → 8f3a2b1c
  prover: local:./modules/prover
  hardening: git:org/tdx-base-modules#hardening@v1.0.0 → deadbeef

Wrote tdx.lock (3 modules locked)

$ tdx build
Loading tdx.toml...
Verifying module integrity...
  ✓ nethermind (sha256:b94d27b9...)
  ✓ prover (sha256:d7a8fbb3...)
  ✓ hardening (sha256:7d865e95...)
Compiling image 'nethermind-prover-node'...
  Generating mkosi.conf
  Generating mkosi.build.d/00-nethermind.sh
  Generating mkosi.build.d/01-prover.sh
  Generating mkosi.extra/ (5 files from 3 modules)
  Generating mkosi.postinst (hooks from 3 modules + image)
  Generating mkosi.repart/ (2 partitions)
Running mkosi build...
```

### 12.3 Monorepo of modules

A single git repo hosting multiple modules:

```
tdx-modules/
├── nethermind/
│   ├── module.toml
│   └── templates/
├── reth/
│   ├── module.toml
│   └── templates/
├── besu/
│   ├── module.toml
│   └── files/
├── hardening/
│   ├── module.toml
│   └── files/
├── monitoring/
│   ├── module.toml
│   └── templates/
└── README.md
```

Consumed in `tdx.toml`:

```toml
[modules.nethermind]
git = "https://github.com/org/tdx-modules"
path = "nethermind"
tag = "v2024.12"

[modules.monitoring]
git = "https://github.com/org/tdx-modules"
path = "monitoring"
tag = "v2024.12"

[modules.hardening]
git = "https://github.com/org/tdx-modules"
path = "hardening"
tag = "v2024.12"
```

The repo is cloned once. Each module is extracted from its subdirectory.

### 12.4 Development workflow — local → remote transition

During development, start with local modules:

```toml
# tdx.toml — development
[modules.nethermind]
path = "./nethermind-module"
```

When ready to publish:

```toml
# tdx.toml — production
[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"
```

Run `tdx lock --update nethermind` to resolve the new source and update the
lockfile.

### 12.5 Mixed declarative + programmatic

`tdx.toml` handles module deps:

```toml
[image]
name = "advanced-node"
base = "debian/bookworm"

[modules.nethermind]
git = "https://github.com/NethermindEth/nethermind-tdx-module"
tag = "v1.30.0"

[modules.nethermind.vars]
NETHERMIND_NETWORK = "mainnet"
```

`TDXfile` adds custom logic:

```python
from tdx import Image, Build, modules, env

image = Image(name="advanced-node", base="debian/bookworm")

# Apply all modules from tdx.toml
image.apply_all()

# Conditionally adjust based on environment
if env("ENABLE_METRICS", default="false") == "true":
    image.install("prometheus-node-exporter")
    image.service(
        name="node-exporter",
        exec="/usr/bin/prometheus-node-exporter",
        restart="always",
    )

# Dynamic file content
image.file(
    "/etc/node-id",
    content=f"node-{env('NODE_INDEX', default='0')}\n",
)
```

---

## 13. Registry (Future)

A centralized registry is not needed for the initial implementation. Git repos
provide all the versioning and distribution infrastructure needed. However, the
design leaves room for a registry in the future.

### 13.1 What a registry would add

- **Discovery**: `tdx search nethermind` instead of knowing the git URL
- **Semver resolution**: `version = "^1.30"` resolves to the latest compatible
  version
- **Trust**: Signed module publications with author verification
- **Stats**: Download counts, compatibility information

### 13.2 How it would integrate

```toml
# Future syntax — registry source (no git URL needed)
[modules.nethermind]
version = "^1.30"

# Still works — git source is always available as an alternative
[modules.custom-tool]
git = "https://github.com/me/my-tool-module"
tag = "v1.0.0"
```

The registry would return a git URL + commit SHA, so it's really just a
discovery layer on top of the same git-based resolution.

### 13.3 Registry index format

If implemented, the registry would be a git repo itself (like Cargo's
crates.io-index or Go's module proxy):

```
registry-index/
├── ne/
│   └── nethermind
│       ├── v1.28.0.toml
│       ├── v1.29.0.toml
│       └── v1.30.0.toml
└── ra/
    └── raiko
        └── v1.0.0.toml
```

Each version file:

```toml
git = "https://github.com/NethermindEth/nethermind-tdx-module"
rev = "8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a"
integrity = "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
yanked = false
```

---

## 14. Design Decisions & Rationale

### Why TOML and not JSON or YAML?

- **TOML** is designed for config files — comments, clear section headers, no
  indentation sensitivity
- JSON has no comments (critical for config files) and is verbose
- YAML has subtle gotchas (Norway problem, implicit typing, indentation)
- TOML is used by Cargo (Rust), pyproject.toml (Python), and Hugo — well
  understood by the target audience
- The TDXfile Python DSL already exists for complex cases — TOML covers the
  simple/declarative case

### Why git-based rather than registry-first?

- **Zero infrastructure** — no server to run, no auth to configure
- **Familiar** — everyone already has git
- **Free hosting** — GitHub, GitLab, Gitea all work
- **Built-in versioning** — tags, branches, and commit SHAs
- **Monorepo support** — multiple modules in one repo, no extra tooling
- A registry can be layered on top later (Section 13) without changing the
  core model

### Why content hashes instead of just commit SHAs?

- A commit SHA identifies a snapshot of a whole repo, but we may only use a
  subdirectory (monorepo case)
- Content hashes verify what we actually use, not what the repo contains
- If a module is moved to a different repo but the content is identical, the
  hash still matches
- Protects against git host compromise — even if someone force-pushes to a
  tag, the content hash will catch it

### Why a lockfile?

- **Reproducibility**: Same lockfile = same modules = same image (with the
  same base packages). This is critical for TDX attestation — you need to know
  exactly what went into the image.
- **Speed**: No network requests needed when building with a lockfile.
- **Auditability**: The lockfile is a complete manifest of exactly what
  versions and commits were used. Check it into version control.
- **CI safety**: `--frozen` mode ensures CI builds use exactly what was tested
  locally.

### Why not Nix flakes?

Nix flakes solve a similar problem, but:
- Nix requires learning a new language and ecosystem
- The TDX SDK already has a Python DSL — adding Nix would be a second DSL
- Nix's hermetic builds are valuable but the mkosi sandbox already provides
  isolation
- The lockfile approach gives us the reproducibility benefits of Nix without
  the complexity

### Module granularity — one module per component

The recommended granularity is **one module per deployable software component**:
- `nethermind` = one module (build + config + service)
- `reth` = one module
- `tdx-hardening` = one module (config only, no build)
- `monitoring-agent` = one module

Avoid making modules too fine-grained (e.g., separate modules for "nethermind
binary" and "nethermind config") or too coarse (e.g., one module for "all
Ethereum clients"). The module boundary should match what an operator thinks of
as a single "thing" they're adding to their image.

### Relationship to mkosi's own include system

mkosi has its own `Include=` directive for composing configurations. The TDX
module system operates at a higher level:
- mkosi includes are raw config fragments — no variables, no dependency
  tracking, no integrity verification
- TDX modules are semantic components with typed builds, templated configs,
  declared variables, and transitive dependencies
- The TDX module system compiles down to mkosi configs — it's a layer on top,
  not a replacement
