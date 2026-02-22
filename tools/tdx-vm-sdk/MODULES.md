# TDX VM SDK — Module System Design

Modules are Python libraries that contribute reusable components to TDX VM
images. A module can provide build logic, configuration files, services,
lifecycle hooks, or any combination — it's just Python code that operates on
an `Image`.

## Table of Contents

1. [Goals](#1-goals)
2. [Concepts](#2-concepts)
3. [Module API](#3-module-api)
4. [Standard Builder Modules](#4-standard-builder-modules)
5. [Fetch Utility](#5-fetch-utility)
6. [Users & Secrets](#6-users--secrets)
7. [Module Distribution & Dependencies](#7-module-distribution--dependencies)
8. [Lockfile](#8-lockfile)
9. [CLI Commands](#9-cli-commands)
10. [Worked Examples](#10-worked-examples)
11. [Design Decisions & Rationale](#11-design-decisions--rationale)

---

## 1. Goals

**Modules are just Python libraries.** No custom file formats, no new DSLs.
A module author writes Python code that calls the same `Image` API that
everyone already uses. If you can write a TDXfile, you can write a module.

**Building flexibility.** Reproducible builds mean different things to
different people. Some want a precompiled Go toolchain downloaded from
go.dev. Others want to build the compiler from source, all the way down.
The SDK provides standard builder modules for common languages, but they're
just modules — you can replace them, extend them, or ignore them entirely.

**Verified fetches.** Any external resource (compiler tarball, firmware
binary, source archive) is downloaded through a `fetch()` utility that
requires a content hash. The hash is recorded in the lockfile. No
unverified downloads in the build.

**Users and secrets.** System users are first-class. Secrets (API keys,
private keys, credentials) are declared in the image definition but
injected *after* measurement — they never affect the measured image, and
they never appear in the build output.

**Composability.** An image is built by calling module functions. Modules
compose naturally through Python: call one module, then another. Conflicts
are just Python errors — a file written twice, a port claimed twice.
No magic merge rules.

---

## 2. Concepts

### What is a module?

A module is a Python package that exports functions (or classes) which
operate on an `Image`. That's it. There is no `module.toml`, no special
directory structure, no registration step. If it's importable and it calls
`Image` methods, it's a module.

```python
# tdx_nethermind/__init__.py
from tdx import Image, Build

def apply(image: Image, network: str = "mainnet", datadir: str = "/var/lib/nethermind"):
    """Add Nethermind to a TDX VM image."""
    image.build(Build.dotnet(
        name="nethermind",
        src=".",
        sdk_version="10.0",
        project="src/Nethermind/Nethermind.Runner",
        output="/opt/nethermind/",
    ))

    image.user("nethermind", system=True, home=datadir)

    image.service(
        name="nethermind",
        exec=f"/opt/nethermind/nethermind --config /etc/nethermind/config.json --datadir {datadir}",
        after=["network-online.target"],
        restart="always",
        user="nethermind",
    )

    image.file("/etc/nethermind/config.json", src="configs/nethermind.json")
    image.run(f"chmod 750 {datadir}")
```

### How modules compose

Modules compose through normal Python function calls. The image builder
(the person writing the TDXfile) controls the order and parameterization:

```python
from tdx import Image
from tdx_nethermind import apply as nethermind
from tdx_hardening import apply as hardening
from tdx_monitoring import apply as monitoring

image = Image("my-node", base="debian/bookworm")

hardening(image)
nethermind(image, network="holesky")
monitoring(image, metrics_port=9090)
```

There is no implicit ordering, no dependency graph to resolve, no merge
rules. The image builder decides what gets applied and in what order.
If two modules write to the same path, the second write wins (or raises
an error, depending on the `Image` method).

### What a module can provide

Since modules are just Python code calling `Image` methods, they can
contribute anything the `Image` API supports:

- **Build artifacts** — compiled binaries via `image.build()`
- **System packages** — distro packages via `image.install()`
- **Configuration files** — static files or templates via `image.file()` / `image.template()`
- **Systemd services** — via `image.service()`
- **System users** — via `image.user()`
- **Secrets** — declared via `image.secret()`, injected post-measurement
- **Lifecycle hooks** — commands at any mkosi phase via `image.run()`, `image.prepare()`, etc.
- **Kernel config** — via `image.kernel`
- **Anything else** — it's Python; you can do whatever you want

### Module packaging

A module is a standard Python package. It uses `pyproject.toml` for
metadata and distribution, just like any other Python library:

```toml
# pyproject.toml for a TDX module
[project]
name = "tdx-nethermind"
version = "1.30.0"
description = "Nethermind Ethereum execution client for TDX VMs"
requires-python = ">=3.11"
dependencies = ["tdx-vm-sdk"]

[project.optional-dependencies]
dev = ["pytest"]
```

Data files (config templates, scripts, etc.) are included via standard
Python packaging mechanisms (`package_data`, `include_package_data`, or
the `importlib.resources` API).

---

## 3. Module API

### 3.1 Module as a function

The simplest module is a single function:

```python
# tdx_hardening/__init__.py
from tdx import Image

def apply(image: Image):
    """Standard TDX VM hardening."""
    image.install("iptables")
    image.file("/etc/sysctl.d/99-tdx-hardening.conf", src=_data("sysctl.conf"))

    image.run("rm -rf /usr/lib/systemd/system/getty*")
    image.run("rm -rf /usr/lib/systemd/system/serial-getty*")
    image.run("sysctl --system")


def _data(name: str) -> str:
    """Resolve a data file bundled with this module."""
    from importlib.resources import files
    return str(files("tdx_hardening").joinpath("data", name))
```

### 3.2 Module as a class

For more complex modules with multiple related components:

```python
# tdx_nethermind/__init__.py
from tdx import Image, Build, fetch

class Nethermind:
    """Nethermind Ethereum execution client."""

    def __init__(self, network: str = "mainnet", datadir: str = "/var/lib/nethermind"):
        self.network = network
        self.datadir = datadir

    def apply(self, image: Image):
        """Apply the full Nethermind stack."""
        self.build(image)
        self.configure(image)
        self.service(image)

    def build(self, image: Image):
        """Just the build step — useful if you want to customize the rest."""
        image.build(Build.dotnet(
            name="nethermind",
            src=".",
            sdk_version="10.0",
            project="src/Nethermind/Nethermind.Runner",
            output="/opt/nethermind/",
            self_contained=True,
        ))

    def configure(self, image: Image):
        """Configuration files and users."""
        image.user("nethermind", system=True, home=self.datadir)
        image.template(
            src=_data("nethermind.cfg.j2"),
            dest="/etc/nethermind/config.json",
            vars={"network": self.network, "datadir": self.datadir},
        )
        image.run(f"mkdir -p {self.datadir}")
        image.run(f"chown nethermind:nethermind {self.datadir}")

    def service(self, image: Image):
        """Systemd service definition."""
        image.service(
            name="nethermind",
            exec="/opt/nethermind/nethermind --config /etc/nethermind/config.json",
            after=["network-online.target"],
            restart="always",
            user="nethermind",
            extra_unit={"Service": {"MemoryMax": "8G", "LimitNOFILE": "65535"}},
        )
```

Usage:

```python
from tdx import Image
from tdx_nethermind import Nethermind

image = Image("my-node", base="debian/bookworm")

nm = Nethermind(network="holesky")
nm.apply(image)

# Or selectively:
nm.build(image)
nm.configure(image)
# Skip the service — I'll define my own
```

### 3.3 Module with sub-components

A single Python package can expose multiple related modules:

```python
# tdx_ethereum/__init__.py
from tdx_ethereum.nethermind import Nethermind
from tdx_ethereum.reth import Reth
from tdx_ethereum.lighthouse import Lighthouse

# tdx_ethereum/nethermind.py
class Nethermind: ...

# tdx_ethereum/reth.py
class Reth: ...
```

Usage:

```python
from tdx_ethereum import Nethermind, Lighthouse

nethermind = Nethermind(network="mainnet")
lighthouse = Lighthouse(checkpoint_sync="https://...")

nethermind.apply(image)
lighthouse.apply(image)
```

---

## 4. Standard Builder Modules

The SDK ships standard builder modules for common languages. These are
regular modules — you can use them, extend them, or replace them entirely.

The key design principle: **people have different requirements for how
compilers are sourced.** Some are fine downloading a precompiled binary
from the language's official release page. Others need to build the
compiler from source for auditability. The builder modules support both
approaches.

### 4.1 Go builder — `tdx.builders.go`

```python
from tdx.builders.go import GoBuild

# Option 1: Use official precompiled release (default)
# Downloads from go.dev, verified by hash
build = GoBuild(
    version="1.22.5",
    src="./my-app/",
    output="/usr/local/bin/my-app",
    ldflags="-s -w -X main.version=1.0.0",
)
image.build(build)

# Option 2: Use a specific compiler tarball
build = GoBuild(
    compiler=fetch(
        "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz",
        sha256="904b924d435eaea086515c6fc840b4...",
    ),
    src="./my-app/",
    output="/usr/local/bin/my-app",
)

# Option 3: Build Go from source
from tdx.builders.go import GoFromSource

go_compiler = GoFromSource(
    version="1.22.5",
    bootstrap_version="1.21.0",  # Uses Go 1.21 to build Go 1.22
)
build = GoBuild(
    compiler=go_compiler,
    src="./my-app/",
    output="/usr/local/bin/my-app",
)
```

### 4.2 Rust builder — `tdx.builders.rust`

```python
from tdx.builders.rust import RustBuild

# Use official rustup toolchain (default)
build = RustBuild(
    toolchain="1.83.0",
    src="./raiko/",
    output="/usr/local/bin/raiko",
    features=["tdx", "sgx"],
    build_deps=["libssl-dev", "pkg-config"],
)

# Use a specific compiler tarball
from tdx import fetch

build = RustBuild(
    compiler=fetch(
        "https://static.rust-lang.org/dist/rust-1.83.0-x86_64-unknown-linux-gnu.tar.xz",
        sha256="f1b5e8c8...",
    ),
    src="./raiko/",
    output="/usr/local/bin/raiko",
)
```

### 4.3 .NET builder — `tdx.builders.dotnet`

```python
from tdx.builders.dotnet import DotnetBuild

build = DotnetBuild(
    sdk_version="10.0",
    src="./nethermind/",
    project="src/Nethermind/Nethermind.Runner",
    output="/opt/nethermind/",
    self_contained=True,
)
```

### 4.4 C/C++ builder — `tdx.builders.c`

```python
from tdx.builders.c import CBuild

# Default: use distro GCC
build = CBuild(
    src="./my-tool/",
    build_script="make release STATIC=1",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libssl-dev"],
)

# Specific GCC version
from tdx import fetch

gcc = fetch(
    "https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz",
    sha256="a7b2e3...",
)
build = CBuild(compiler=gcc, ...)
```

### 4.5 Reproducibility flags

All standard builder modules set common reproducibility flags by default:

- `SOURCE_DATE_EPOCH=0` — deterministic timestamps
- `-trimpath` (Go) — strip build machine paths from binaries
- `--remap-path-prefix` (Rust) — same
- `-fdebug-prefix-map` (C/C++) — same
- Sorted file lists, deterministic linking order where possible

These can be disabled per-build:

```python
build = GoBuild(
    version="1.22.5",
    src="./app/",
    output="/usr/local/bin/app",
    reproducible=False,  # Disable reproducibility flags
)
```

### 4.6 Custom builder — `Build.script()`

For anything the typed builders don't cover, `Build.script()` remains the
universal fallback:

```python
from tdx import Build

custom = Build.script(
    name="my-tool",
    src="./tools/my-tool/",
    build_script="make release",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libfoo-dev"],
)
image.build(custom)
```

---

## 5. Fetch Utility

`fetch()` downloads a resource from a URL and verifies it against a known
hash. This is the primitive that builder modules use internally, and that
module authors can use directly for any external resource.

### 5.1 Basic usage

```python
from tdx import fetch

# Download and verify — returns a Path to the cached file
tarball = fetch(
    "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz",
    sha256="904b924d435eaea086515c6fc840b4ab3336c5ba780356e20a4d7ab3c9f2...",
)

# Use the result
image.run(f"tar -C /usr/local -xzf {tarball}")
```

### 5.2 Semantics

- **Content-addressed caching.** Downloads are cached by their hash in
  `~/.cache/tdx/fetch/<sha256>`. If the file exists and matches, no
  download occurs.

- **Hash is mandatory.** `fetch()` without a hash is an error. This is a
  deliberate design choice — every external resource must be verified.

- **Lockfile recording.** Every `fetch()` call is recorded in the lockfile
  with its URL, hash, and the timestamp of first resolution. This creates
  an auditable manifest of every external resource used in the build.

- **Hash mismatch is fatal.** If the downloaded content doesn't match the
  expected hash, the build fails immediately with a clear error:

  ```
  Error: hash mismatch for https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
    Expected: sha256:904b924d...
    Got:      sha256:e3b0c442...

  The remote content has changed. Verify the new content and update the hash.
  ```

### 5.3 Helper: `hash_of()`

To compute the expected hash for a new resource:

```bash
# CLI
tdx fetch --hash https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
# sha256:904b924d435eaea086515c6fc840b4ab3336c5ba...
```

```python
# Python
from tdx import hash_of

h = hash_of("https://go.dev/dl/go1.22.5.linux-amd64.tar.gz")
print(h)  # sha256:904b924d...
```

### 5.4 Git source fetching

For fetching git repositories (e.g., to build a compiler from source):

```python
from tdx import fetch_git

# Fetch a specific tag
src = fetch_git(
    "https://github.com/golang/go",
    tag="go1.22.5",
    sha256="a1b2c3...",  # Hash of the tree contents at that tag
)

# Fetch a specific commit
src = fetch_git(
    "https://github.com/example/repo",
    rev="a1b2c3d4e5f67890...",
    sha256="d4e5f6...",
)
```

The hash covers the file tree contents (not the git metadata), similar to
Go's module hash. This means the same source tree produces the same hash
regardless of git history, rebases, or re-tags.

---

## 6. Users & Secrets

### 6.1 System users

`image.user()` creates system users in the image. This is the standard way
to set up service accounts:

```python
image.user("nethermind", system=True, home="/var/lib/nethermind")
image.user("monitoring", system=True, shell="/usr/sbin/nologin")
```

**API:**

```python
image.user(
    name: str,
    system: bool = True,          # Create as system user (low UID)
    home: str | None = None,      # Home directory (created if specified)
    shell: str = "/usr/sbin/nologin",
    groups: list[str] | None = None,  # Additional groups
    uid: int | None = None,       # Explicit UID (for reproducibility)
)
```

Under the hood, this generates `useradd` commands in the postinst phase.
If `home` is specified, the directory is created and owned by the user.

### 6.2 Secrets

Secrets are values that must not be baked into the image at build time.
If a secret were included in the image, it would affect the TDX
measurement — meaning the measurement would change every time the secret
changes, and the secret would be extractable from the image file.

Instead, secrets are **declared** at build time but **injected** after the
VM boots and has been measured. The image contains a placeholder or a
service that fetches the secret at runtime.

```python
image.secret(
    "API_KEY",
    description="API key for monitoring service",
    dest="/etc/app/api-key",         # Where the secret will be placed at runtime
)

image.secret(
    "SSH_AUTHORIZED_KEYS",
    description="SSH public keys for admin access",
    dest="/root/.ssh/authorized_keys",
)

image.secret(
    "TLS_CERT",
    description="TLS certificate for HTTPS endpoint",
    dest="/etc/ssl/certs/app.pem",
)
```

### 6.3 Secret delivery mechanisms

The image needs a way to receive secrets after boot. The SDK provides
pluggable delivery mechanisms:

```python
# SSH-based delivery (default for dev/staging)
# After the VM boots, secrets are pushed via SSH/vsock
image.secret_delivery("ssh")

# Vsock-based delivery (recommended for production)
# Host pushes secrets through a vsock channel
image.secret_delivery("vsock")

# Custom delivery
# A user-provided script that runs at boot and fetches secrets
image.secret_delivery("script", fetch_script="./scripts/fetch-secrets.sh")
```

The delivery mechanism generates:
1. A systemd service that waits for secrets on the chosen channel
2. A target (`secrets-ready.target`) that other services can depend on
3. Proper file permissions on the secret destinations

Services that depend on secrets can declare that dependency:

```python
image.service(
    name="my-app",
    exec="/usr/local/bin/my-app",
    after=["secrets-ready.target"],
    requires=["secrets-ready.target"],
)
```

### 6.4 Why not just use environment variables?

Environment variables are visible in `/proc/PID/environ`, logged by some
init systems, and inherited by child processes. File-based secrets with
restrictive permissions (mode 0400, owned by the service user) are more
secure and easier to audit.

---

## 7. Module Distribution & Dependencies

### 7.1 Module sources

Since modules are Python packages, they can come from anywhere Python
packages come from:

**PyPI (or private index):**
```bash
pip install tdx-nethermind
```

**Git repository:**
```bash
pip install git+https://github.com/NethermindEth/tdx-nethermind@v1.30.0
```

**Local path (during development):**
```bash
pip install -e ./modules/nethermind/
```

**Direct dependency in pyproject.toml:**
```toml
[project]
dependencies = [
    "tdx-vm-sdk",
    "tdx-nethermind>=1.30",
    "tdx-hardening~=1.0",
]
```

### 7.2 Image project structure

An image project is itself a Python package. Its `pyproject.toml` declares
module dependencies, and its TDXfile imports and uses them:

```
my-image/
├── pyproject.toml        # Declares module dependencies
├── tdx.lock              # Pins exact versions + hashes
├── TDXfile               # Image definition (Python)
├── configs/              # Local config files, templates
│   ├── nethermind.cfg.j2
│   └── monitoring.yml
└── modules/              # Local modules (optional)
    └── my-prover/
        ├── pyproject.toml
        └── tdx_my_prover/
            └── __init__.py
```

```toml
# pyproject.toml
[project]
name = "my-tdx-image"
version = "1.0.0"
dependencies = [
    "tdx-vm-sdk",
    "tdx-nethermind>=1.30",
    "tdx-hardening~=1.0",
    "tdx-monitoring>=0.5",
]
```

```python
# TDXfile
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden
from tdx_monitoring import apply as monitoring

image = Image("nethermind-prover", base="debian/bookworm")

harden(image)

nm = Nethermind(network="holesky")
nm.apply(image)

monitoring(image)

image.secret("GRAFANA_API_KEY", dest="/etc/monitoring/api-key")
image.secret_delivery("vsock")
```

### 7.3 Version pinning

Standard Python version specifiers apply:

| Specifier | Meaning |
|-----------|---------|
| `tdx-nethermind==1.30.0` | Exact version |
| `tdx-nethermind>=1.30` | Minimum version |
| `tdx-nethermind~=1.30` | Compatible release (>=1.30, <2.0) |
| `tdx-nethermind>=1.30,<1.35` | Bounded range |

The lockfile (see [Section 8](#8-lockfile)) pins exact versions with
content hashes, regardless of the specifier used in `pyproject.toml`.

---

## 8. Lockfile

The lockfile (`tdx.lock`) ensures reproducible builds by pinning the exact
version of every module and every fetched resource to a content hash.

### 8.1 What gets locked

| Resource | What's recorded | How it's verified |
|----------|----------------|-------------------|
| PyPI module | Package name, version, source URL | SHA-256 of wheel/sdist |
| Git module | Repo URL, resolved commit SHA | SHA-256 of file tree (dirhash) |
| Local module | Relative path | SHA-256 of file tree |
| `fetch()` resource | URL, content hash | SHA-256 of downloaded file |
| `fetch_git()` resource | Repo URL, resolved commit | SHA-256 of file tree |

### 8.2 Format

TOML, to match `pyproject.toml` conventions. Human-readable for auditing
and VCS-friendly for diffs.

```toml
# Auto-generated by tdx lock. Do not edit manually.
# To update, run: tdx lock --update [module-name]

version = 1

[[module]]
name = "tdx-nethermind"
version = "1.30.0"
source = "pypi"
url = "https://files.pythonhosted.org/packages/.../tdx_nethermind-1.30.0-py3-none-any.whl"
integrity = "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

[[module]]
name = "tdx-hardening"
version = "1.0.0"
source = "git"
git = "https://github.com/org/tdx-hardening"
resolved_rev = "8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a"
integrity = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

[[module]]
name = "tdx-my-prover"
version = "0.1.0"
source = "local"
path = "./modules/my-prover"
integrity = "sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"

[[fetch]]
url = "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz"
integrity = "sha256:904b924d435eaea086515c6fc840b4ab3336c5ba780356e20a4d7ab3c9f2cafe"
resolved_at = "2026-02-22T10:30:00Z"

[[fetch]]
url = "https://static.rust-lang.org/dist/rust-1.83.0-x86_64-unknown-linux-gnu.tar.xz"
integrity = "sha256:f1b5e8c8a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0"
resolved_at = "2026-02-22T10:30:00Z"
```

### 8.3 Integrity computation

Module integrity hashes are computed over file contents, not archive
metadata:

```
1. List all files in the module (respecting .gitignore)
2. Sort filenames lexicographically
3. For each file: sha256(relative_path + "\0" + file_contents)
4. Hash the concatenation of all per-file hashes
```

This is a content hash (like Go's dirhash). Two different git commits
with identical file contents produce the same hash. A module moved to a
different repo still validates if the content is unchanged.

For `fetch()` resources, the hash is simply `sha256(file_contents)`.

### 8.4 Lock commands

| Command | What happens |
|---------|-------------|
| `tdx lock` | Resolve all unlocked dependencies. Locked ones are not touched. |
| `tdx lock --update` | Re-resolve ALL dependencies. |
| `tdx lock --update tdx-nethermind` | Re-resolve a specific module. |
| `tdx lock --dry-run` | Show what would change without writing. |
| `tdx build` (no lockfile) | Implicitly runs `tdx lock` first. |
| `tdx build` (lockfile exists) | Uses locked versions. Fails if dependencies changed. |
| `tdx build --frozen` | Fails if lockfile is missing or stale. For CI. |

### 8.5 Frozen builds

In CI, use `--frozen` to ensure the build uses exactly what was tested:

```bash
tdx build --frozen
```

This mode:
- Refuses to resolve any new dependencies
- Refuses to download anything not already in the lockfile
- Fails if any integrity hash doesn't match
- Fails if the lockfile is stale (dependencies changed in `pyproject.toml`)

---

## 9. CLI Commands

### 9.1 Fetch utilities

```bash
# Compute the hash of a remote resource
tdx fetch --hash https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
# sha256:904b924d435eaea086515c6fc840b4ab3336c5ba...

# Compute the hash of a local file
tdx fetch --hash ./go1.22.5.linux-amd64.tar.gz

# Download and cache a resource (for pre-populating the cache)
tdx fetch https://go.dev/dl/go1.22.5.linux-amd64.tar.gz \
    --sha256 904b924d435eaea086515c6fc840b4ab3336c5ba...
```

### 9.2 Lock management

```bash
# Resolve and lock all dependencies
tdx lock

# Update all dependencies
tdx lock --update

# Update a specific module
tdx lock --update tdx-nethermind

# Show what would change
tdx lock --dry-run
```

### 9.3 Module development

```bash
# Compute the content hash of a module directory
tdx module hash ./modules/my-prover/

# Validate a module (check that it exports the expected API)
tdx module validate ./modules/my-prover/
```

### 9.4 Secret management

```bash
# Push secrets to a running VM via SSH
tdx secrets push --host <vm-ip> --key ./secrets.env

# Push secrets via vsock (when running on the same host)
tdx secrets push --vsock <cid> --key ./secrets.env

# List declared secrets for an image
tdx secrets list
```

---

## 10. Worked Examples

### 10.1 Creating a simple module

A monitoring agent module:

```
tdx-monitoring/
├── pyproject.toml
└── tdx_monitoring/
    ├── __init__.py
    └── data/
        └── prometheus.yml.j2
```

```toml
# pyproject.toml
[project]
name = "tdx-monitoring"
version = "0.5.0"
dependencies = ["tdx-vm-sdk"]
```

```python
# tdx_monitoring/__init__.py
from importlib.resources import files
from tdx import Image, Build

def apply(image: Image, metrics_port: int = 9090):
    """Add Prometheus node exporter and monitoring agent."""
    image.install("prometheus-node-exporter")

    image.user("monitoring", system=True)

    image.template(
        src=str(files("tdx_monitoring").joinpath("data", "prometheus.yml.j2")),
        dest="/etc/prometheus/prometheus.yml",
        vars={"metrics_port": metrics_port},
    )

    image.service(
        name="node-exporter",
        exec="/usr/bin/prometheus-node-exporter",
        restart="always",
        user="monitoring",
    )
```

### 10.2 Custom compiler build

Building with a specific GCC version compiled from source:

```python
from tdx import Image, fetch, fetch_git
from tdx.builders.c import CBuild

# Fetch GCC source
gcc_src = fetch_git(
    "https://gcc.gnu.org/git/gcc.git",
    tag="releases/gcc-14.2.0",
    sha256="a7b2e3c4d5e6f7...",
)

image = Image("custom-build", base="debian/bookworm")

# Build our tool with this specific GCC
build = CBuild(
    compiler_source=gcc_src,
    src="./my-tool/",
    build_script="make release STATIC=1 CC=/opt/gcc-14/bin/gcc",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libssl-dev"],
)
image.build(build)
```

### 10.3 Full image with secrets

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden

image = Image("production-node", base="debian/bookworm")

# Hardening first
harden(image)

# Nethermind
nm = Nethermind(network="mainnet", datadir="/var/lib/nethermind")
nm.apply(image)

# Secrets — declared but not baked into the image
image.secret(
    "NETHERMIND_JWT",
    description="JWT secret for engine API authentication",
    dest="/etc/nethermind/jwt.hex",
    owner="nethermind",
    mode="0400",
)

image.secret(
    "SSH_HOST_KEY",
    description="SSH host private key",
    dest="/etc/ssh/ssh_host_ed25519_key",
    owner="root",
    mode="0600",
)

# Secrets delivered via vsock from the host
image.secret_delivery("vsock")

# Make nethermind wait for secrets
image.service(
    name="nethermind",
    exec="/opt/nethermind/nethermind --config /etc/nethermind/config.json",
    after=["secrets-ready.target", "network-online.target"],
    requires=["secrets-ready.target"],
    restart="always",
    user="nethermind",
)
```

### 10.4 Module that wraps a builder

A module that provides a specific compiler version as a reusable component:

```python
# tdx_go122/__init__.py
"""Go 1.22 toolchain module — provides a verified Go compiler."""

from tdx import Image, fetch

_GO_URL = "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz"
_GO_SHA256 = "904b924d435eaea086515c6fc840b4ab3336c5ba..."

def apply(image: Image):
    """Install Go 1.22.5 into the build environment."""
    tarball = fetch(_GO_URL, sha256=_GO_SHA256)
    image.prepare(f"tar -C /usr/local -xzf {tarball}")
    image.prepare("ln -sf /usr/local/go/bin/go /usr/local/bin/go")
```

Then other modules can depend on it:

```toml
# pyproject.toml for a module that needs Go
[project]
dependencies = ["tdx-vm-sdk", "tdx-go122"]
```

```python
# TDXfile
from tdx_go122 import apply as install_go
from tdx import Image, Build

image = Image("my-go-app", base="debian/bookworm")
install_go(image)
image.build(Build.script(
    name="my-app",
    src="./app/",
    build_script="go build -trimpath -o $DESTDIR/usr/local/bin/my-app .",
    output="/usr/local/bin/my-app",
))
```

### 10.5 Development workflow

During development, keep modules local:

```
my-project/
├── pyproject.toml
├── TDXfile
└── modules/
    └── my-agent/
        ├── pyproject.toml
        └── tdx_my_agent/
            └── __init__.py
```

```toml
# pyproject.toml
[project]
dependencies = [
    "tdx-vm-sdk",
    "tdx-my-agent @ file:./modules/my-agent",
]
```

When ready to publish, push the module to a git repo or PyPI and update
the dependency:

```toml
[project]
dependencies = [
    "tdx-vm-sdk",
    "tdx-my-agent>=1.0",
]
```

---

## 11. Design Decisions & Rationale

### Why Python libraries and not custom config files?

The previous design used `module.toml` — a custom declarative format.
This worked for simple cases but had fundamental limitations:

- **Limited expressiveness.** Any conditional logic, loops, or dynamic
  behavior required escape hatches (inline scripts, lifecycle hooks).
  With Python, the full language is available.
- **Learning curve.** Module authors had to learn both the TOML schema
  *and* the Python DSL. Now there's just one thing to learn.
- **Tooling.** Python has editors, linters, type checkers, formatters,
  testing frameworks. Custom TOML schemas get none of this.
- **Distribution.** Python has pip, PyPI, virtual environments, and
  decades of packaging infrastructure. No need to build our own registry
  or distribution system.
- **Composition.** Python's import system handles namespacing, versioning,
  and dependency resolution. Modules compose through function calls,
  not through magic merge rules.

### Why `fetch()` with mandatory hashes?

For reproducible, measured builds, every input must be pinned. A compiler
downloaded today might be different from one downloaded tomorrow (supply
chain attack, CDN cache inconsistency, etc.). The `fetch()` utility makes
this explicit: you must declare what you expect, and the build fails if
reality doesn't match.

This is the same principle as Go's `go.sum`, Nix's `narHash`, and
Cargo's `checksum` — but applied to arbitrary external resources, not just
package manager artifacts.

### Why are secrets post-measurement?

TDX measures the VM image at boot time to produce an attestation report.
If secrets were baked into the image:

1. **The measurement changes** every time a secret rotates. This breaks
   attestation policies that expect a stable measurement.
2. **The secret is in the image file** on disk, extractable by anyone
   with access to the host filesystem.
3. **The secret is in the build log**, the CI cache, the container
   registry, etc.

By injecting secrets after measurement (via SSH or vsock), the measured
image is deterministic and secret-free. The attestation report proves
the VM is running the expected code; the secrets are delivered only to
VMs that pass attestation.

### Why not Nix?

Nix solves many of the same problems (reproducible builds, content-addressed
storage, declarative composition). But:

- Nix requires learning a new language and a large ecosystem
- The TDX SDK already has a Python DSL — adding Nix would be a second
  paradigm
- Python's packaging ecosystem is larger and more familiar to the target
  audience (Ethereum infra operators, cloud teams)
- The `fetch()` + lockfile approach gives the reproducibility benefits
  without the complexity

### Why standard builder modules instead of hardcoded builders?

The original `Build.go()`, `Build.rust()`, etc. hardcoded how compilers
are obtained. But in practice:

- Some teams require building compilers from source for audit compliance
- Some need specific compiler patches or configurations
- Some operate in airgapped environments with pre-staged tarballs
- Some are fine with `apt install golang` and don't need any of this

Making builders into modules means each team can choose their approach.
The standard builders cover the common case (download official release,
verify hash). Teams with stricter requirements bring their own.

### Why not `tdx.toml` for module declarations?

Since modules are Python packages declared in `pyproject.toml`, there's
no need for a separate `tdx.toml` manifest. The image project's
`pyproject.toml` declares its module dependencies using standard Python
dependency syntax. The `tdx.lock` file pins exact versions.

This eliminates one file and one concept from the system. Image builders
already need `pyproject.toml` for their project metadata; adding module
dependencies there is natural.
