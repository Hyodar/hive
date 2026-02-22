# TDX VM SDK — Module System Design

Modules are Python libraries that provide reusable components for TDX VM
images. A module separates **building** (compile the binary — happens once)
from **installing** (configure an instance — can happen many times).

## Table of Contents

1. [Goals](#1-goals)
2. [Concepts](#2-concepts)
3. [Module API](#3-module-api)
4. [Dependency Declarations](#4-dependency-declarations)
5. [Build Cache](#5-build-cache)
6. [Standard Builder Modules](#6-standard-builder-modules)
7. [Fetch Utility](#7-fetch-utility)
8. [Users & Secrets](#8-users--secrets)
9. [Module Distribution](#9-module-distribution)
10. [Lockfile](#10-lockfile)
11. [CLI Commands](#11-cli-commands)
12. [Worked Examples](#12-worked-examples)
13. [Design Decisions & Rationale](#13-design-decisions--rationale)

---

## 1. Goals

**Modules are Python libraries.** No custom file formats, no DSLs. A
module author writes Python code that calls the same `Image` API that
TDXfile authors use. If you can write a TDXfile, you can write a module.

**Build once, install many.** Building a binary and configuring an instance
are separate operations. Build the Nethermind binary once; install two
instances with different networks, data directories, and ports. The build
cache ensures the same build specification never runs twice — not within
one image, and not across images.

**Flexible building.** Reproducible builds mean different things to
different people. Some want a precompiled Go toolchain from go.dev. Others
want to build the compiler from source, all the way down. The SDK provides
standard builder modules for common languages, but they're just modules —
replace them, extend them, or ignore them.

**Explicit dependencies.** A module declares its runtime packages, its
build-time packages, and its dependencies on other modules. The Image
collects and deduplicates these across all modules. No implicit installs,
no hidden fetches.

**Verified fetches.** Any external resource (compiler tarball, firmware
binary, source archive) goes through `fetch()` with a mandatory content
hash. The hash is recorded in the lockfile.

**Users and secrets.** System users are first-class. Secrets are declared
at build time but injected *after* measurement — they never affect the
measured image.

---

## 2. Concepts

### Build vs. Install

A module like "Nethermind" has two distinct concerns:

| Concern | Happens | What it does |
|---------|---------|-------------|
| **Build** (setup) | Once per image | Compile the binary, install runtime apt packages |
| **Install** | Once per instance | Create user, write config, create service, set up data dir |

This separation is the core of the module API. The binary at
`/opt/nethermind/` is shared; the config at `/etc/nm-mainnet/config.json`
is per-instance.

### Module structure

A module is a Python class with three methods:

```python
class MyModule:
    def setup(self, image):    ...  # Build + packages (once, idempotent)
    def install(self, image):  ...  # Configure an instance (per-instance)
    def apply(self, image):    ...  # Convenience: setup + install
```

For simple modules that don't need multiple instances, a plain function
works too:

```python
def apply(image):  # Setup + install in one shot
    ...
```

### How modules compose

Modules compose through Python function calls. The image builder controls
the order:

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden

image = Image("my-node", base="debian/bookworm")

harden(image)

nm = Nethermind()
nm.setup(image)                                           # Build once
nm.install(image, name="nm-mainnet", network="mainnet")   # Instance 1
nm.install(image, name="nm-holesky", network="holesky")   # Instance 2
```

No implicit ordering. No dependency graph. No merge rules. The image
builder decides what to apply and when.

---

## 3. Module API

### 3.1 Full module example — Nethermind

This is the reference example. It shows build/install separation, multiple
instances, dependency declaration, and configuration.

```python
# tdx_nethermind/__init__.py

from importlib.resources import files
from tdx import Image, Build

def _data(name: str) -> str:
    """Resolve a data file bundled with this module."""
    return str(files("tdx_nethermind").joinpath("data", name))


class Nethermind:
    """Nethermind Ethereum execution client.

    Build the binary once, then install as many instances as you want
    with different networks, ports, and data directories.
    """

    def setup(self, image: Image):
        """Build the Nethermind binary and install runtime packages.

        Idempotent — safe to call multiple times. The build cache
        ensures the binary is compiled at most once.
        """
        image.install("ca-certificates", "libsnappy1v5")

        image.build(Build.dotnet(
            name="nethermind",
            src=".",
            sdk_version="10.0",
            project="src/Nethermind/Nethermind.Runner",
            output="/opt/nethermind/",
            self_contained=True,
            build_deps=["libsnappy-dev", "libgflags-dev"],
            env={"DOTNET_CLI_TELEMETRY_OPTOUT": "1"},
        ))

    def install(
        self,
        image: Image,
        *,
        name: str = "nethermind",
        network: str = "mainnet",
        datadir: str | None = None,
        rpc_port: int = 8545,
        rpc_host: str = "127.0.0.1",
        engine_port: int = 8551,
        p2p_port: int = 30303,
        memory_max: str = "8G",
        limit_nofile: int = 65535,
    ):
        """Install one Nethermind instance.

        Each call creates a separate user, config, data directory, and
        systemd service. Call multiple times with different names for
        multiple instances.
        """
        if datadir is None:
            datadir = f"/var/lib/{name}"

        # Per-instance user and data directory
        image.user(name, system=True, home=datadir)

        # Per-instance configuration
        image.template(
            src=_data("nethermind.cfg.j2"),
            dest=f"/etc/{name}/config.json",
            vars={
                "network": network,
                "datadir": datadir,
                "rpc_port": rpc_port,
                "rpc_host": rpc_host,
                "engine_port": engine_port,
                "p2p_port": p2p_port,
            },
        )

        # Per-instance service
        image.service(
            name=name,
            exec=f"/opt/nethermind/nethermind --config /etc/{name}/config.json --datadir {datadir}",
            after=["network-online.target"],
            restart="always",
            user=name,
            extra_unit={
                "Service": {
                    "MemoryMax": memory_max,
                    "LimitNOFILE": str(limit_nofile),
                },
            },
        )

    def apply(self, image: Image, **kwargs):
        """Convenience: setup + single install.

        For the common case of one instance. Equivalent to:
            self.setup(image)
            self.install(image, **kwargs)
        """
        self.setup(image)
        self.install(image, **kwargs)
```

### 3.2 Usage patterns

**Single instance (common case):**

```python
nm = Nethermind()
nm.apply(image, network="mainnet")
```

**Multiple instances:**

```python
nm = Nethermind()
nm.setup(image)  # Build binary + install packages (once)

nm.install(image, name="nm-mainnet",  network="mainnet",  rpc_port=8545, p2p_port=30303)
nm.install(image, name="nm-holesky",  network="holesky",  rpc_port=8546, p2p_port=30304)
nm.install(image, name="nm-sepolia",  network="sepolia",  rpc_port=8547, p2p_port=30305)
```

**Selective use (build only, custom config):**

```python
nm = Nethermind()
nm.setup(image)  # Build binary

# Skip nm.install — do my own configuration
image.file("/etc/nethermind/custom-config.json", src="./my-config.json")
image.service(
    name="nethermind",
    exec="/opt/nethermind/nethermind --config /etc/nethermind/custom-config.json",
    user="nethermind",
)
```

### 3.3 Simple module (function form)

For modules that don't need multiple instances — hardening, monitoring
agents, base configurations:

```python
# tdx_hardening/__init__.py
from tdx import Image

def apply(image: Image, strict: bool = True):
    """Standard TDX VM hardening."""
    image.install("iptables")
    image.file("/etc/sysctl.d/99-tdx-hardening.conf", src=_data("sysctl.conf"))

    image.run("rm -rf /usr/lib/systemd/system/getty*")
    image.run("rm -rf /usr/lib/systemd/system/serial-getty*")
    image.run("sysctl --system")

    if strict:
        image.run("rm -rf /usr/lib/systemd/system/systemd-homed*")
        image.run("rm -rf /usr/lib/systemd/system/systemd-userdbd*")
```

The function form is for modules that are apply-once by nature. The class
form with `setup()`/`install()` is for things that can have multiple
instances.

### 3.4 Module with sub-components

A single Python package can expose multiple related modules:

```python
# tdx_ethereum/__init__.py
from tdx_ethereum.nethermind import Nethermind
from tdx_ethereum.reth import Reth
from tdx_ethereum.lighthouse import Lighthouse
from tdx_ethereum.prysm import Prysm
```

### 3.5 Module packaging

A module is a standard Python package:

```
tdx-nethermind/
├── pyproject.toml
└── tdx_nethermind/
    ├── __init__.py         # Module class
    └── data/
        ├── nethermind.cfg.j2
        └── logging.xml.j2
```

```toml
# pyproject.toml
[project]
name = "tdx-nethermind"
version = "1.30.0"
description = "Nethermind Ethereum execution client for TDX VMs"
requires-python = ">=3.11"
dependencies = ["tdx-vm-sdk"]
```

Data files (config templates, scripts) are included via standard Python
packaging (`package_data` or `importlib.resources`).

---

## 4. Dependency Declarations

Modules need to express what they depend on. There are four kinds of
dependencies, each handled differently.

### 4.1 Runtime packages — `image.install()`

Apt packages that must be present in the final image:

```python
def setup(self, image):
    image.install("ca-certificates", "libsnappy1v5", "libc6")
```

The Image deduplicates these. If two modules both call
`image.install("ca-certificates")`, it appears once in the package list.

### 4.2 Build-time packages — `build_deps` on `Build`

Apt packages needed only during compilation. Installed in the build
overlay, **not** in the final image:

```python
image.build(Build.dotnet(
    name="nethermind",
    src=".",
    output="/opt/nethermind/",
    build_deps=["libsnappy-dev", "libgflags-dev"],  # Build sandbox only
))
```

mkosi installs these in the build sandbox and strips them from the
final image automatically.

### 4.3 Compiler / toolchain — builder modules

"I need Go 1.22 to build this" is a toolchain dependency, handled by
builder modules (see [Section 6](#6-standard-builder-modules)):

```python
from tdx.builders.go import GoBuild

# GoBuild handles fetching + verifying Go 1.22
image.build(GoBuild(
    version="1.22.5",
    src="./my-app/",
    output="/usr/local/bin/my-app",
))
```

The builder module decides how to source the compiler. The image builder
can override by providing `compiler=`.

### 4.4 Other modules — Python package dependencies

"My module depends on another module" is a Python package dependency:

```toml
# pyproject.toml
[project]
dependencies = [
    "tdx-vm-sdk",
    "tdx-dotnet-runtime>=10.0",
]
```

In the module code:

```python
from tdx_dotnet_runtime import DotnetRuntime

class Nethermind:
    def setup(self, image):
        # Ensure .NET runtime is set up first
        runtime = DotnetRuntime(version="10.0")
        runtime.setup(image)  # Idempotent — build cache handles dedup

        image.build(Build.dotnet(...))
```

Since `setup()` is idempotent (see [Section 5](#5-build-cache)), calling
it multiple times is safe.

### 4.5 Binary dependencies — "I need the output of another build"

Module A needs a binary that module B produces → module A depends on
module B as a Python package and calls `B.setup(image)`:

```python
class MyApp:
    def setup(self, image):
        from tdx_libcustom import LibCustom
        LibCustom().setup(image)  # Builds libcustom.so (idempotent)

        image.build(Build.script(
            name="my-app",
            src="./app/",
            build_script="make LDFLAGS='-L/usr/local/lib -lcustom'",
            output="/usr/local/bin/my-app",
        ))
```

### 4.6 Summary

| Dependency type | How to declare | Deduplicated by |
|----------------|---------------|-----------------|
| Runtime apt packages | `image.install("pkg")` | Package name |
| Build-time apt packages | `Build(..., build_deps=["pkg"])` | Package name |
| Compiler/toolchain | Builder module (`GoBuild(version=...)`) | Build cache |
| Another TDX module | Python dep + `module.setup(image)` | Build cache |
| Binary from another build | Python dep + `module.setup(image)` | Build cache |

---

## 5. Build Cache

The build cache ensures that the same build specification never executes
twice — within one image or across images.

### 5.1 Within one image — deduplication

When `image.build(spec)` is called, the Image computes a cache key from
the build specification. If the same key has already been registered, the
call is a no-op:

```python
nm = Nethermind()
nm.setup(image)   # Registers build for nethermind → /opt/nethermind/
nm.setup(image)   # Same build spec → no-op (already registered)
```

This makes `setup()` idempotent. Any module can call another module's
`setup()` without worrying about duplicate builds.

The cache key is a hash of:
- Builder type and version (e.g., `dotnet/10.0`)
- Source path or identifier
- Output path
- Build flags, dependencies, environment variables
- Compiler specification (if custom)

### 5.2 Across images — artifact cache

Built artifacts are cached in `~/.cache/tdx/builds/` keyed by content
hash. If a previous image build already produced the same artifact (same
source, same compiler, same flags), the cached result is reused without
recompilation:

```
~/.cache/tdx/builds/
├── sha256-a1b2c3.../
│   ├── manifest.toml          # Build spec that produced this
│   └── artifacts/
│       └── opt/nethermind/
│           ├── nethermind
│           └── ...
└── sha256-d4e5f6.../
    └── ...
```

The artifact cache is content-addressed: same inputs → same key → same
output. This means:

- Image A and image B both use Nethermind v1.30.0 with the same .NET SDK
  → binary compiles once.
- Change a flag, dependency, or compiler version → different cache key →
  fresh build.
- `tdx cache clean --builds` clears build artifacts.

### 5.3 Cache invalidation

The cache is conservative — when in doubt, it rebuilds:

- **Source changed**: Any file in `src` changed → new cache key.
- **Compiler changed**: Different compiler tarball hash → new key.
- **Flags changed**: Different `ldflags`, `features`, etc. → new key.
- **Build deps changed**: Different `build_deps` list → new key.
- **`--no-cache`**: Force rebuild, ignore cache entirely.

### 5.4 How `image.install()` deduplicates

Package installations are collected and deduplicated:

```python
image.install("ca-certificates", "libsnappy1v5")
image.install("ca-certificates", "curl")
# Result: install ca-certificates, curl, libsnappy1v5 (union, sorted)
```

The Image maintains a set of requested packages. The final list is the
sorted union of all requests.

---

## 6. Standard Builder Modules

The SDK ships standard builder modules for common languages. These handle
compiler sourcing, reproducibility flags, and artifact installation.

Each builder supports at least:
1. Download a precompiled official release (default)
2. Use a specific tarball provided via `fetch()` (airgapped/audited)
3. Build the compiler from source (maximum auditability)

### 6.1 Go — `tdx.builders.go`

```python
from tdx.builders.go import GoBuild, GoFromSource

# Default: precompiled official release
image.build(GoBuild(
    version="1.22.5",
    src="./my-app/",
    output="/usr/local/bin/my-app",
    ldflags="-s -w",
))

# Custom tarball
image.build(GoBuild(
    compiler=fetch("https://go.dev/dl/go1.22.5.linux-amd64.tar.gz", sha256="904b..."),
    src="./my-app/",
    output="/usr/local/bin/my-app",
))

# From source
image.build(GoBuild(
    compiler=GoFromSource(version="1.22.5", bootstrap_version="1.21.0"),
    src="./my-app/",
    output="/usr/local/bin/my-app",
))
```

### 6.2 Rust — `tdx.builders.rust`

```python
from tdx.builders.rust import RustBuild

image.build(RustBuild(
    toolchain="1.83.0",
    src="./raiko/",
    output="/usr/local/bin/raiko",
    features=["tdx", "sgx"],
    build_deps=["libssl-dev", "pkg-config"],
))
```

### 6.3 .NET — `tdx.builders.dotnet`

```python
from tdx.builders.dotnet import DotnetBuild

image.build(DotnetBuild(
    sdk_version="10.0",
    src="./nethermind/",
    project="src/Nethermind/Nethermind.Runner",
    output="/opt/nethermind/",
    self_contained=True,
))
```

### 6.4 C/C++ — `tdx.builders.c`

```python
from tdx.builders.c import CBuild

image.build(CBuild(
    src="./my-tool/",
    build_script="make release STATIC=1",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libssl-dev"],
))
```

### 6.5 Custom — `Build.script()`

Universal fallback:

```python
from tdx import Build

image.build(Build.script(
    name="my-tool",
    src="./tools/my-tool/",
    build_script="make release",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake"],
))
```

### 6.6 Reproducibility flags

All standard builders set these by default:

- `SOURCE_DATE_EPOCH=0` — deterministic timestamps
- `-trimpath` (Go), `--remap-path-prefix` (Rust), `-fdebug-prefix-map`
  (C/C++) — strip build paths
- Sorted file lists, deterministic linking order

Disable per-build with `reproducible=False`.

---

## 7. Fetch Utility

`fetch()` downloads a resource and verifies it against a known hash.

### 7.1 Usage

```python
from tdx import fetch

tarball = fetch(
    "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz",
    sha256="904b924d435eaea...",
)
# Returns Path to cached, verified file
```

### 7.2 Semantics

- **Content-addressed caching.** Cached in `~/.cache/tdx/fetch/<sha256>`.
- **Hash is mandatory.** `fetch()` without a hash is an error.
- **Lockfile recording.** Every `fetch()` is recorded in `tdx.lock`.
- **Hash mismatch is fatal.** Clear error with expected vs. actual.

### 7.3 Git source fetching

```python
from tdx import fetch_git

src = fetch_git(
    "https://github.com/golang/go",
    tag="go1.22.5",
    sha256="a1b2c3...",  # Hash of file tree contents (dirhash)
)
```

### 7.4 Hash helper

```bash
tdx fetch --hash https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
# sha256:904b924d...
```

---

## 8. Users & Secrets

### 8.1 System users

```python
image.user(
    name="nethermind",
    system=True,                   # System user (low UID)
    home="/var/lib/nethermind",     # Created and owned
    shell="/usr/sbin/nologin",
    groups=["disk"],
    uid=800,                       # Explicit UID (reproducibility)
)
```

Generates `useradd` commands in postinst. Duplicate user names are
detected and reported as errors.

### 8.2 Secrets — post-measurement injection

Secrets are declared at build time but injected after the VM boots and
has been measured. This keeps the measurement stable and the image
secret-free.

```python
image.secret("JWT_SECRET", dest="/etc/nethermind/jwt.hex", owner="nethermind")
image.secret("TLS_CERT", dest="/etc/ssl/certs/app.pem")
```

### 8.3 Secret delivery

```python
image.secret_delivery("ssh")     # Push via SSH after boot
image.secret_delivery("vsock")   # Push via vsock channel
image.secret_delivery("script", fetch_script="./fetch-secrets.sh")
```

Generates a `secrets-ready.target` that services can depend on:

```python
image.service(
    name="nethermind",
    exec="...",
    after=["secrets-ready.target"],
    requires=["secrets-ready.target"],
)
```

### 8.4 Why post-measurement?

- Measurement doesn't change when secrets rotate
- Secrets aren't extractable from the image file
- Secrets aren't in build logs, CI caches, or registries
- Attestation proves the image code; secrets go only to attested VMs

---

## 9. Module Distribution

Modules are standard Python packages:

| Source | Example |
|--------|---------|
| PyPI | `pip install tdx-nethermind` |
| Git repo | `pip install git+https://github.com/org/tdx-nethermind@v1.30` |
| Local path | `pip install -e ./modules/nethermind/` |
| pyproject.toml | `"tdx-nethermind>=1.30"` |

### Image project structure

```
my-image/
├── pyproject.toml        # Module dependencies
├── tdx.lock              # Pinned versions + hashes
├── TDXfile               # Image definition (Python)
├── configs/              # Local config files, templates
└── modules/              # Local modules (optional)
    └── my-prover/
        ├── pyproject.toml
        └── tdx_my_prover/__init__.py
```

---

## 10. Lockfile

The lockfile (`tdx.lock`) pins every module and fetched resource to a
content hash.

### 10.1 Format

```toml
# Auto-generated by tdx lock. Do not edit.
version = 1

[[module]]
name = "tdx-nethermind"
version = "1.30.0"
source = "pypi"
url = "https://files.pythonhosted.org/packages/.../tdx_nethermind-1.30.0.whl"
integrity = "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe..."

[[module]]
name = "tdx-hardening"
version = "1.0.0"
source = "git"
git = "https://github.com/org/tdx-hardening"
resolved_rev = "8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a"
integrity = "sha256:e3b0c44298fc1c149afbf4c8996fb924..."

[[fetch]]
url = "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz"
integrity = "sha256:904b924d435eaea086515c6fc840b4ab..."
```

### 10.2 Integrity

Module hashes use dirhash (like Go's approach — hash over sorted file
contents). Fetch hashes are `sha256(file_contents)`.

### 10.3 Commands

| Command | What happens |
|---------|-------------|
| `tdx lock` | Resolve all unlocked deps |
| `tdx lock --update` | Re-resolve everything |
| `tdx lock --update tdx-nethermind` | Re-resolve one module |
| `tdx build --frozen` | Fail if lockfile is stale (for CI) |

---

## 11. CLI Commands

```bash
# Build
tdx build                          # Build the image
tdx build --frozen                 # CI mode (strict lockfile)
tdx build --no-cache               # Force rebuild everything

# Lock
tdx lock                           # Resolve and lock dependencies
tdx lock --update                  # Update all
tdx lock --update tdx-nethermind   # Update one

# Fetch
tdx fetch --hash <url-or-path>     # Compute hash of a resource

# Cache
tdx cache clean                    # Clear all caches
tdx cache clean --builds           # Clear build artifacts only
tdx cache clean --fetches          # Clear fetch cache only

# Secrets
tdx secrets push --host <ip> --file ./secrets.env
tdx secrets push --vsock <cid> --file ./secrets.env
tdx secrets list                   # Show declared secrets

# Module development
tdx module hash ./path/            # Compute content hash
tdx module validate ./path/        # Check module structure
```

---

## 12. Worked Examples

### 12.1 Dual Nethermind instances

Running two Nethermind clients on different networks in one image:

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden

image = Image("dual-nethermind", base="debian/bookworm")

harden(image)

nm = Nethermind()
nm.setup(image)  # Build binary + install packages (once)

# Mainnet instance
nm.install(image,
    name="nm-mainnet",
    network="mainnet",
    datadir="/var/lib/nm-mainnet",
    rpc_port=8545,
    engine_port=8551,
    p2p_port=30303,
    memory_max="16G",
)

# Holesky testnet instance
nm.install(image,
    name="nm-holesky",
    network="holesky",
    datadir="/var/lib/nm-holesky",
    rpc_port=8546,
    engine_port=8552,
    p2p_port=30304,
    memory_max="4G",
)

# Result:
#   Binary:   /opt/nethermind/ (shared, built once)
#   Users:    nm-mainnet, nm-holesky
#   Configs:  /etc/nm-mainnet/config.json, /etc/nm-holesky/config.json
#   Data:     /var/lib/nm-mainnet/, /var/lib/nm-holesky/
#   Services: nm-mainnet.service, nm-holesky.service
```

### 12.2 Execution + consensus client pair

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_lighthouse import Lighthouse
from tdx_hardening import apply as harden

image = Image("eth-fullnode", base="debian/bookworm")

harden(image)

nm = Nethermind()
nm.apply(image, network="mainnet")

lh = Lighthouse()
lh.apply(image, network="mainnet", execution_endpoint="http://127.0.0.1:8551")

# JWT secret shared between EL and CL — injected post-measurement
image.secret("JWT_SECRET", dest="/etc/ethereum/jwt.hex", owner="root", mode="0440")
image.run("usermod -aG ethereum nethermind")
image.run("usermod -aG ethereum lighthouse")
image.secret_delivery("vsock")
```

### 12.3 Custom compiler from source

```python
from tdx import Image, fetch_git
from tdx.builders.go import GoBuild, GoFromSource

image = Image("audited-build", base="debian/bookworm")

go = GoFromSource(
    version="1.22.5",
    source=fetch_git(
        "https://go.googlesource.com/go",
        tag="go1.22.5",
        sha256="a1b2c3...",
    ),
    bootstrap_version="1.21.0",
)

image.build(GoBuild(
    compiler=go,
    src="./my-prover/",
    output="/usr/local/bin/my-prover",
    ldflags="-s -w",
))
```

### 12.4 Module depending on another module

```python
# tdx_monitoring/__init__.py
from tdx import Image, Build
from tdx_node_exporter import NodeExporter

class Monitoring:
    def setup(self, image: Image):
        NodeExporter().setup(image)  # Idempotent dep
        image.build(Build.go(
            name="metrics-agg", version="1.22.5",
            src=".", output="/usr/local/bin/metrics-agg",
        ))

    def install(self, image: Image, *, name: str = "monitoring", port: int = 9090):
        image.user(name, system=True)
        image.service(name=name, exec=f"/usr/local/bin/metrics-agg --port {port}", user=name)

    def apply(self, image: Image, **kwargs):
        self.setup(image)
        self.install(image, **kwargs)
```

### 12.5 Config-only module (no build)

```python
# tdx_hardening/__init__.py
from importlib.resources import files
from tdx import Image

def apply(image: Image, strict: bool = True):
    image.install("iptables")
    image.file("/etc/sysctl.d/99-tdx.conf", src=str(files("tdx_hardening").joinpath("data", "sysctl.conf")))
    image.run("rm -rf /usr/lib/systemd/system/getty*")
    image.run("sysctl --system")
    if strict:
        image.run("rm -rf /usr/lib/systemd/system/systemd-homed*")
```

No `setup()`/`install()` split — hardening is one-shot, not multi-instance.

---

## 13. Design Decisions & Rationale

### Why separate build from install?

The `apply()` pattern conflates two concerns:

1. **Building** — compile source code into a binary. Expensive,
   deterministic, same output regardless of configuration.
2. **Installing** — create a user, write config, set up a service.
   Cheap, varies per instance.

Two Nethermind instances on different networks share the same binary.
Separating `setup()` from `install()` makes this natural. For simple
modules (hardening, config-only), the function form `apply()` is
simpler and encouraged.

### Why an artifact cache?

Without caching, iterating on config requires recompiling everything.
With a content-addressed cache:

- Change a config file → instant rebuild (binary cache hit)
- Change compiler flags → fresh build (different cache key)
- Different image, same module version → cache hit

Same concept as ccache or Nix's binary cache. Builds are deterministic
functions: same inputs → same outputs → cache.

### Why idempotent setup()?

When module A depends on module B, both might call `B.setup(image)`. The
build cache makes this safe — the second call is a no-op. Modules can
declare and ensure their dependencies without coordination.

The alternative (topological sort of deps) adds complexity and takes
control away from the image builder.

### Why Python libraries and not config files?

- Full language expressiveness (conditionals, loops, dynamic config)
- One thing to learn (Python), not two (TOML schema + Python DSL)
- Standard tooling (editors, linters, type checkers, testing)
- Standard distribution (pip, PyPI, git)

### Why `fetch()` with mandatory hashes?

Every external input must be pinned for reproducible, measured builds.
A compiler downloaded today might differ tomorrow. The hash is explicit
and auditable.

### Why are secrets post-measurement?

If secrets were in the image: measurements change on rotation, secrets
are extractable from the file, secrets leak into build logs. Post-
measurement injection keeps the image deterministic and secret-free.

### Dependency resolution — explicit, not automatic

Modules call `setup()` on their dependencies explicitly. No solver, no
topological sort. The TDXfile controls order. This is intentional:

- Build order is visible in the TDXfile
- No diamond dependency problems (setup is idempotent)
- No version conflicts (Python package manager handles it)
- Image builder has full control
