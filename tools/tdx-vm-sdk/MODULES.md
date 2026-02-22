# TDX VM SDK — Module System Design

Modules are Python libraries that provide reusable components for TDX VM
images. A module separates **building** (compile the binary — happens once)
from **installing** (configure an instance — can happen many times).

## Table of Contents

1. [Goals](#1-goals)
2. [Concepts](#2-concepts)
3. [Module API](#3-module-api)
4. [mkosi Lifecycle Mapping](#4-mkosi-lifecycle-mapping)
5. [Dependency Declarations](#5-dependency-declarations)
6. [Build Cache](#6-build-cache)
7. [Standard Builder Modules](#7-standard-builder-modules)
8. [Fetch Utility](#8-fetch-utility)
9. [Users & Secrets](#9-users--secrets)
10. [Module Distribution](#10-module-distribution)
11. [Lockfile](#11-lockfile)
12. [SDK Operations](#12-sdk-operations)
13. [Worked Examples](#13-worked-examples)
14. [Design Decisions & Rationale](#14-design-decisions--rationale)

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

image = Image(build_dir="build", base="debian/bookworm")

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
            target="x86_64",  # build target architecture
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

    # Whitelist-based debloat (finalize phase, operates on $BUILDROOT)
    if strict:
        image.debloat()  # full TDX default: whitelist systemd, strip paths
    else:
        image.debloat(systemd_minimize=False)  # path stripping only

    image.run("sysctl --system")
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

## 4. mkosi Lifecycle Mapping

The Image object is a **declarative collector** — calls like
`image.install()`, `image.build()`, and `image.run()` don't execute
immediately. They record what should happen. The SDK compiler then sorts
everything into the correct mkosi phase. Module authors need to understand
which phase each method targets, because it determines what's available
at that point (base packages? build artifacts? other images?).

### 4.1 mkosi phases and Image methods

mkosi builds images through a fixed sequence of phases. Each Image method
maps to exactly one phase:

```
Phase               mkosi artifact          Image methods that target it
─────────────────── ─────────────────────── ─────────────────────────────────────
1. sync             mkosi.sync              image.sync()
2. skeleton         mkosi.skeleton/         image.skeleton()
3. package install  mkosi.conf [Content]    image.install()          ← Packages=
                                            image.build(build_deps=) ← BuildPackages=
                                            image.repository()       ← Repositories=
4. prepare          mkosi.prepare           image.prepare()
5. build            mkosi.build.d/          image.build()
6. extra files      mkosi.extra/            image.file(), image.template(), image.service()
7. postinst         mkosi.postinst          image.user(), image.service(), image.run()
8. finalize         mkosi.finalize          image.finalize()
9. (image written)
10. postoutput      mkosi.postoutput        image.postoutput()
11. clean           mkosi.clean             image.clean()
──── not mkosi ──── ──────────────────────  ─────────────────────────────────────
VM boot             systemd oneshot         image.on_boot()
```

### 4.2 What each phase does

**sync** (`image.sync()`) — Runs on the **host** before any image
operations. Use for `git submodule update`, fetching source tarballs, etc.

**skeleton** (`image.skeleton()`) — Files placed in the image
*before* the package manager runs. Use for custom apt sources, base
`/etc/resolv.conf` for build-time DNS, or directory structure that
packages expect to exist.

There is no "pre-install script" phase — before packages are installed
there is no userspace (no shell, no libc). The skeleton is the only
mechanism to influence what the package manager sees. For apt, this
means:

```python
# Add a custom repo so apt can see it during package install
image.skeleton(
    "/etc/apt/sources.list.d/custom.list",
    content="deb [signed-by=/etc/apt/trusted.gpg.d/custom.gpg] https://repo.example.com bookworm main",
)
image.skeleton("/etc/apt/trusted.gpg.d/custom.gpg", src="./keys/custom.gpg")

# Now packages from this repo are available to image.install()
image.install("custom-package")
```

For common cases, `image.repository()` provides a higher-level API
that handles both the skeleton file and mkosi's `Repositories=`
directive:

```python
image.repository(
    url="https://repo.example.com",
    suite="bookworm",
    components=["main"],
    keyring="./keys/custom.gpg",
)
```

**package install** — mkosi runs the package manager. Two separate
package lists, installed in different scopes:

- `Packages=` (from `image.install()`) → installed in the **final image**
- `BuildPackages=` (from `build_deps=`) → installed in a **build overlay**
  that is discarded after the build phase. Never in the final image.

This separation is enforced by mkosi, not by the SDK. Build dependencies
like `libsnappy-dev` or `cmake` are genuinely absent from the final
image — the overlay is thrown away after compilation.

**prepare** (`image.prepare()`) — Runs **inside** the image namespace
after base packages are installed, before the build phase. Has network
access. Use for `pip install`, `npm install`, or other package managers
that need the base system in place.

**build** (`image.build()`) — Each `BuildArtifact` generates a script
in `mkosi.build.d/`. Runs in a **build overlay** with:
- `$DESTDIR` — where artifacts must be placed to reach the final image
- `$SRCDIR` — mounted source trees
- `BuildPackages` installed (but not in the final image)

This is where compilers run. The overlay is discarded after — only
files written to `$DESTDIR` survive into the final image.

**extra files** (`image.file()`, `image.template()`, `image.service()`)
— Static files and rendered templates are placed into `mkosi.extra/`,
which mkosi copies into the image **after** build scripts complete.
Service unit files go here too (`mkosi.extra/etc/systemd/system/`).

**postinst** (`image.run()`, `image.user()`, `image.service()`) — Runs
**inside** the image namespace after build artifacts and extra files are
installed. The postinst script is generated in a specific order
(see [Section 4.4](#44-postinst-ordering)).

**finalize** (`image.finalize()`) — Runs on the **host** (not inside
the image) with `$BUILDROOT` pointing to the image filesystem. Use for
host-side tools, foreign architecture operations, or anything that needs
tools not available inside the image.

**postoutput** (`image.postoutput()`) — Runs on the host after the
disk image file is written. Use for computing checksums, signing,
measurements, upload.

**boot** (`image.on_boot()`) — NOT a build phase. Generates a systemd
oneshot service that runs when the VM actually boots. Use for TDX
attestation initialization, disk encryption key fetching, runtime setup.

### 4.3 Why module authors need to care

The phase matters because it determines what's available:

| In this phase... | Base packages? | Build overlay? | Build artifacts? | Extra files? |
|-----------------|---------------|---------------|-----------------|-------------|
| skeleton | No | No | No | No |
| prepare | Yes | No | No | No |
| build | Yes | Yes (build_deps) | Being created | No |
| postinst | Yes | No (stripped) | Yes | Yes |
| finalize | (host) | No | Yes | Yes |

A module that calls `image.run("nethermind --version")` works because
`image.run()` targets postinst, which happens after the build phase
installs the binary. But `image.prepare("/opt/nethermind/nethermind --version")`
would fail — the binary doesn't exist yet during prepare.

### 4.4 Postinst ordering

The postinst script is assembled from multiple sources. The compiler
generates it in this order:

```
mkosi.postinst script:
  1. Users from image.user()          ← useradd, mkdir home, chown
  2. Service users from image.service() ← conditional useradd fallback
  3. Service enablement               ← systemctl enable
  4. Secret directory setup           ← mkdir -p for secret destinations
  5. systemctl set-default            ← default boot target
  6. image.run() commands             ← in call order
```

**Users are created before services are enabled.** This means
`image.user()` always runs before `image.service()` setup commands.
If a module declares a user via `image.user()` AND references the same
user in `image.service(user=...)`, the service's fallback user creation
(`id -u || useradd -r`) is a no-op because the user already exists.
The `image.user()` version is authoritative — it sets home directory,
groups, UID, and shell.

**`image.run()` commands always run last in postinst.** This means
module `image.run()` commands can reference any user, service, or
secret directory — they're all set up by the time `image.run()`
commands execute. Between multiple `image.run()` calls, order is
preserved — first registered, first executed.

Example of the generated postinst for a two-instance Nethermind setup:

```bash
#!/bin/bash
set -euo pipefail

# 1. Users from image.user()
id -u nm-mainnet &>/dev/null || useradd -r -m -d /var/lib/nm-mainnet -s /usr/sbin/nologin nm-mainnet
mkdir -p /var/lib/nm-mainnet
chown nm-mainnet:nm-mainnet /var/lib/nm-mainnet
id -u nm-holesky &>/dev/null || useradd -r -m -d /var/lib/nm-holesky -s /usr/sbin/nologin nm-holesky
mkdir -p /var/lib/nm-holesky
chown nm-holesky:nm-holesky /var/lib/nm-holesky

# 2-3. Service users (no-op, users exist) + enable
id -u nm-mainnet &>/dev/null || useradd -r -s /usr/sbin/nologin nm-mainnet
systemctl enable nm-mainnet.service
id -u nm-holesky &>/dev/null || useradd -r -s /usr/sbin/nologin nm-holesky
systemctl enable nm-holesky.service

# 4-5. Secrets + default target
systemctl set-default multi-user.target

# 6. User image.run() commands
sysctl --system
```

### 4.5 Phase mapping in the Nethermind module

Here's which phase each call in the Nethermind module targets:

```python
class Nethermind:
    def setup(self, image):
        # Phase: package install (Packages= in mkosi.conf)
        image.install("ca-certificates", "libsnappy1v5")

        # Phase: build (mkosi.build.d/ script)
        # build_deps → BuildPackages= (overlay only, stripped from final image)
        image.build(Build.dotnet(
            name="nethermind",
            src=".",
            output="/opt/nethermind/",
            build_deps=["libsnappy-dev", "libgflags-dev"],
        ))

    def install(self, image, *, name="nethermind", ...):
        # Phase: postinst step 1 (user creation commands auto-generated)
        image.user(name, system=True, home=datadir)

        # Phase: extra files (rendered template → mkosi.extra/)
        image.template(src=_data("nethermind.cfg.j2"), dest=f"/etc/{name}/config.json", ...)

        # Phase: extra files (unit file → mkosi.extra/etc/systemd/system/)
        # Phase: postinst steps 2-3 (service user fallback + systemctl enable)
        image.service(name=name, exec="...", user=name)
```

Note: `image.service()` spans two phases — the unit file goes to
`mkosi.extra/` (extra files phase), while `systemctl enable` and the
service user fallback are auto-generated in the postinst script.

### 4.6 The Image is a declarative collector

Call order within a module doesn't matter for cross-phase operations.
These two are equivalent:

```python
# Order A                           # Order B
image.run("echo configured")        image.build(Build.go(...))
image.build(Build.go(...))          image.install("curl")
image.install("curl")               image.run("echo configured")
```

Both produce the same mkosi output: `curl` in `Packages=`, the Go build
in `mkosi.build.d/`, and "echo configured" in `mkosi.postinst`. The
compiler sorts methods into their phases regardless of call order.

**Within a single phase**, order is preserved. If a module calls
`image.run("A")` then `image.run("B")`, the postinst script runs A
before B. The TDXfile author controls cross-module ordering by choosing
which module methods to call first.

### 4.7 Advanced phases for module authors

Most modules only need `image.install()`, `image.build()`, `image.run()`,
`image.file()`, `image.template()`, `image.service()`, and `image.user()`.
The advanced lifecycle methods (`sync`, `prepare`, `finalize`,
`postoutput`, `on_boot`) are available for modules that need them:

```python
class SpecialModule:
    def setup(self, image):
        # Fetch sources before build
        image.sync("git submodule update --init --recursive")

        # Install Python deps needed by build scripts
        image.prepare("pip install meson ninja")

        # Compile
        image.build(Build.script(name="special", src=".", build_script="meson compile"))

    def install(self, image, *, name="special"):
        image.user(name, system=True)
        image.service(name=name, exec="/usr/local/bin/special")

        # Run attestation init on every VM boot
        image.on_boot("/usr/local/bin/special --init-attestation")
```

---

## 5. Dependency Declarations

Modules need to express what they depend on. There are four kinds of
dependencies, each handled differently.

### 5.1 Runtime packages — `image.install()`

Apt packages that must be present in the final image:

```python
def setup(self, image):
    image.install("ca-certificates", "libsnappy1v5", "libc6")
```

The Image deduplicates these. If two modules both call
`image.install("ca-certificates")`, it appears once in the package list.

### 5.2 Build-time packages — `build_deps` on `Build`

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

### 5.3 Compiler / toolchain — builder modules

"I need Go 1.22 to build this" is a toolchain dependency, handled by
builder modules (see [Section 7](#7-standard-builder-modules)):

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

### 5.4 Other modules — Python package dependencies

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

Since `setup()` is idempotent (see [Section 6](#6-build-cache)), calling
it multiple times is safe.

### 5.5 Binary dependencies — "I need the output of another build"

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

### 5.6 Summary

| Dependency type | How to declare | Deduplicated by |
|----------------|---------------|-----------------|
| Runtime apt packages | `image.install("pkg")` | Package name |
| Build-time apt packages | `Build(..., build_deps=["pkg"])` | Package name |
| Compiler/toolchain | Builder module (`GoBuild(version=...)`) | Build cache |
| Another TDX module | Python dep + `module.setup(image)` | Build cache |
| Binary from another build | Python dep + `module.setup(image)` | Build cache |

---

## 6. Build Cache

The build cache ensures that the same build specification never executes
twice — within one image or across images.

### 6.1 Within one image — deduplication

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

### 6.2 Across images — artifact cache

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
- `clean_cache(builds_only=True)` clears build artifacts.

### 6.3 Cache invalidation

The cache is conservative — when in doubt, it rebuilds:

- **Source changed**: Any file in `src` changed → new cache key.
- **Compiler changed**: Different compiler tarball hash → new key.
- **Flags changed**: Different `ldflags`, `features`, etc. → new key.
- **Build deps changed**: Different `build_deps` list → new key.
- **`no_cache=True`**: Force rebuild, ignore cache entirely.

### 6.4 How `image.install()` deduplicates

Package installations are collected and deduplicated:

```python
image.install("ca-certificates", "libsnappy1v5")
image.install("ca-certificates", "curl")
# Result: install ca-certificates, curl, libsnappy1v5 (union, sorted)
```

The Image maintains a set of requested packages. The final list is the
sorted union of all requests.

---

## 7. Standard Builder Modules

The SDK ships standard builder modules for common languages. These handle
compiler sourcing, reproducibility flags, and artifact installation.

Each builder supports at least:
1. Download a precompiled official release (default)
2. Use a specific tarball provided via `fetch()` (airgapped/audited)
3. Build the compiler from source (maximum auditability)

All builders accept a `target` parameter specifying the build target
architecture (e.g. `"x86_64"`, `"aarch64"`). Defaults to the host
architecture if omitted. The Image-level default can be set with
`Image(target="x86_64")`.

### 7.1 Go — `tdx.builders.go`

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

### 7.2 Rust — `tdx.builders.rust`

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

### 7.3 .NET — `tdx.builders.dotnet`

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

### 7.4 C/C++ — `tdx.builders.c`

```python
from tdx.builders.c import CBuild

image.build(CBuild(
    src="./my-tool/",
    build_script="make release STATIC=1",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libssl-dev"],
))
```

### 7.5 Custom — `Build.script()`

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

### 7.6 Reproducibility flags

All standard builders set these by default:

- `SOURCE_DATE_EPOCH=0` — deterministic timestamps
- `-trimpath` (Go), `--remap-path-prefix` (Rust), `-fdebug-prefix-map`
  (C/C++) — strip build paths
- Sorted file lists, deterministic linking order

Disable per-build with `reproducible=False`.

---

## 8. Fetch Utility

`fetch()` downloads a resource and verifies it against a known hash.

### 8.1 Usage

```python
from tdx import fetch

tarball = fetch(
    "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz",
    sha256="904b924d435eaea...",
)
# Returns Path to cached, verified file
```

### 8.2 Semantics

- **Content-addressed caching.** Cached in `~/.cache/tdx/fetch/<sha256>`.
- **Hash is mandatory.** `fetch()` without a hash is an error.
- **Lockfile recording.** Every `fetch()` is recorded in `tdx.lock`.
- **Hash mismatch is fatal.** Clear error with expected vs. actual.

### 8.3 Git source fetching

```python
from tdx import fetch_git

src = fetch_git(
    "https://github.com/golang/go",
    tag="go1.22.5",
    sha256="a1b2c3...",  # Hash of file tree contents (dirhash)
)
```

### 8.4 Hash helper

```python
from tdx import fetch_hash

hash = fetch_hash("https://go.dev/dl/go1.22.5.linux-amd64.tar.gz")
# "sha256:904b924d..."
```

---

## 9. Users & Secrets

### 9.1 System users

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

### 9.2 Secrets — post-measurement injection

Secrets are declared at build time but injected after the VM boots and
has been measured. This keeps the measurement stable and the image
secret-free.

```python
image.secret("JWT_SECRET", dest="/etc/nethermind/jwt.hex", owner="nethermind")
image.secret("TLS_CERT", dest="/etc/ssl/certs/app.pem")
```

### 9.3 Secret delivery

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

### 9.4 Why post-measurement?

- Measurement doesn't change when secrets rotate
- Secrets aren't extractable from the image file
- Secrets aren't in build logs, CI caches, or registries
- Attestation proves the image code; secrets go only to attested VMs

---

## 10. Module Distribution

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

## 11. Lockfile

The lockfile (`tdx.lock`) pins every module and fetched resource to a
content hash.

### 11.1 Format

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

### 11.2 Integrity

Module hashes use dirhash (like Go's approach — hash over sorted file
contents). Fetch hashes are `sha256(file_contents)`.

### 11.3 Commands

| Method | What happens |
|--------|-------------|
| `img.lock()` | Resolve all unlocked deps |
| `img.lock(update=True)` | Re-resolve everything |
| `img.lock(update="tdx-nethermind")` | Re-resolve one module |
| `img.bake(frozen=True)` | Fail if lockfile is stale (for CI) |

---

## 12. SDK Operations

All operations are methods on `Image`. There is no CLI.

```python
from tdx import Image

img = Image(build_dir="build", base="debian/bookworm")
# ... configuration ...

# Bake (produce the VM image via lima-vm)
img.bake()                          # Bake the image
img.bake(frozen=True)               # CI mode (strict lockfile)
img.bake(no_cache=True)             # Force rebuild everything

# Measure
rtmrs = img.measure(backend="rtmr")         # Raw TDX measurements
pcrs = img.measure(backend="azure")          # Azure CVM measurements
rtmrs.to_json("build/measurements.json")     # Export
rtmrs.verify(quote=Path("./quote.bin"))      # Verify a running VM

# Deploy
img.deploy(target="qemu", memory="4G")       # Local QEMU
img.deploy(target="azure", resource_group="my-rg", vm_size="Standard_DC4as_v5")

# Profile-scoped operations
with img.profile("dev"):
    img.bake()
    img.measure(backend="rtmr")
    img.deploy(target="qemu", memory="4G")

# Batch profile operations
img.profiles("dev", "prod").bake()           # Bake multiple profiles (single lima-vm execution)
img.all_profiles().bake()                    # Bake all defined profiles
img.all_profiles().measure(backend="rtmr")   # Measure all profiles

# Lock
img.lock()                          # Resolve and lock dependencies
img.lock(update=True)               # Re-resolve everything
img.lock(update="tdx-nethermind")   # Re-resolve one module

# Inspect
img.emit_mkosi("./out/")           # Dump generated mkosi configs

# Cache management
from tdx.cache import clean_cache
clean_cache()                       # Clear all caches
clean_cache(builds_only=True)       # Clear build artifacts only
clean_cache(fetches_only=True)      # Clear fetch cache only
```

---

## 13. Worked Examples

### 13.1 Dual Nethermind instances

Running two Nethermind clients on different networks in one image:

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden

image = Image(build_dir="build", base="debian/bookworm")

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

### 13.2 Execution + consensus client pair

```python
from tdx import Image
from tdx_nethermind import Nethermind
from tdx_lighthouse import Lighthouse
from tdx_hardening import apply as harden

image = Image(build_dir="build", base="debian/bookworm")

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

### 13.3 Custom compiler from source

```python
from tdx import Image, fetch_git
from tdx.builders.go import GoBuild, GoFromSource

image = Image(build_dir="build", base="debian/bookworm")

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

### 13.4 Module depending on another module

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

### 13.5 Config-only module (no build)

```python
# tdx_hardening/__init__.py
from importlib.resources import files
from tdx import Image

def apply(image: Image, strict: bool = True):
    image.install("iptables")
    image.file("/etc/sysctl.d/99-tdx.conf", src=str(files("tdx_hardening").joinpath("data", "sysctl.conf")))
    image.debloat() if strict else image.debloat(systemd_minimize=False)
    image.run("sysctl --system")
```

No `setup()`/`install()` split — hardening is one-shot, not multi-instance.

### 13.6 Full pipeline with profiles

```python
from tdx import Image, Kernel
from tdx_nethermind import Nethermind
from tdx_hardening import apply as harden

img = Image(build_dir="build", base="debian/bookworm", target="x86_64")
img.kernel = Kernel.tdx(version="6.8")

harden(img)

nm = Nethermind()
nm.apply(img, network="mainnet")

# Dev profile: add debugging tools
with img.profile("dev"):
    img.ssh(enabled=True)
    img.install("strace", "gdb")
    img.debloat(enabled=False)

# Bake all profiles in a single lima-vm execution
results = img.all_profiles().bake()

# Measure all profiles
measurements = img.all_profiles().measure(backend="rtmr")
for name, m in measurements.items():
    m.to_json(f"build/{name}/measurements.json")

# Deploy the dev profile locally
with img.profile("dev"):
    img.deploy(target="qemu", memory="4G")
```

---

## 14. Design Decisions & Rationale

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

### Why `build()` vs `bake()`?

`build()` registers compilation steps — "compile this Go project," "build
this .NET app." `bake()` produces the final VM image. The names reflect
the conceptual difference: `build()` is about individual artifacts,
`bake()` is about the whole image. `bake()` runs inside lima-vm to
provide a reproducible Linux build environment regardless of the host OS.

### Why lima-vm for baking?

mkosi needs a Linux environment with specific tooling (systemd-nspawn,
package managers). lima-vm provides this consistently on macOS, Windows
WSL, and Linux. The SDK controls the lima-vm instance lifecycle — it
starts the VM, mounts the necessary directories, runs mkosi, and collects
the output. For multi-profile bakes, the same lima-vm instance is reused,
and the shared build cache means common compilation steps run only once.

### Why `profiles()` and `all_profiles()`?

The `with img.profile("name"):` context manager works well for single-profile
operations, but batch operations like "bake all profiles" need a different
API. `img.profiles("dev", "prod").bake()` is clearer than a loop, and it
enables the SDK to optimize — using a single lima-vm instance and sharing
the build cache across all profiles in one execution.
