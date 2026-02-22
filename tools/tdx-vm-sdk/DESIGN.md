# TDX VM SDK — Design

A Python SDK for building reproducible, measured TDX virtual machine images.

## Design Principles

### 1. Full configurability, opinionated defaults

Every VM knob is exposed — kernel config, partitions, init system, firmware,
encryption, networking. The SDK provides sensible TDX defaults so you can start
with `Image(build_dir="build")` and get a working hardened image. But nothing
is hidden or locked: you can override any default down to raw kernel .config
entries or custom OVMF firmware paths.

### 2. Build your own packages reproducibly

Users don't just `apt install` prebuilt binaries. They have Go, Rust, .NET, C
projects that need to be compiled from source, reproducibly, and placed into the
image. The `Build` system handles this: it pins compiler versions, sets
`SOURCE_DATE_EPOCH`, runs builds in isolated environments, and produces
deterministic artifacts. `Build.script()` is the universal fallback for anything
the typed builders don't cover.

### 3. Escape hatches everywhere

The declarative API covers the common cases. For everything else:
- `image.run("shell commands")` — arbitrary commands during postinst
- `image.run_script("./script.sh")` — run a script file during postinst
- `image.prepare("commands")` — run before the build phase (pip, npm)
- `image.finalize("commands")` — run on HOST after image assembly
- `image.on_boot("commands")` — run commands at VM boot time
- `image.skeleton()` — files placed before the package manager runs
- `image.file()` / `image.template()` — drop arbitrary files into the image
- `image.emit_mkosi("./out/")` — inspect the generated mkosi configs directly

The SDK is a **compiler from Python DSL to mkosi configs + build scripts**,
not a black box.

### 4. SDK, not CLI

There is no CLI. Everything is a Python method on `Image`. Users who want a
CLI can trivially build one from the SDK. The three core operations — build,
measure, deploy — are all methods on the same `Image` object:

```python
from tdx import Image

img = Image(build_dir="build")
# ... configure ...
img.build()                              # build the image
img.measure(backend="rtmr")             # compute measurements from build artifacts
img.deploy(target="qemu", memory="4G")  # deploy the built image
```

### 5. Profiles scope everything

The `with image.profile("name")` context manager scopes all operations —
configuration, build, measure, deploy. Outside any profile block, you're
operating on the default profile (configurable via `Image(default_profile=...)`).

```python
img = Image(build_dir="build")
img.install("ca-certificates")          # → default profile
img.build()                              # → builds default profile

with img.profile("dev"):
    img.install("strace", "gdb")        # → dev profile only
    img.build()                          # → builds dev profile only
    img.deploy(target="qemu")           # → deploys dev profile
```

## mkosi Lifecycle Mapping

The SDK maps directly to mkosi's build phases. Every phase is exposed.
When you call `image.build()`, the SDK generates mkosi configs and
invokes mkosi:

```
image.build()
    |
    +-- generates mkosi.conf      ◄──────────  Image(), Kernel(), install()
    |                                           mkosi phase
    +-- image.skeleton()         ──────────►  mkosi.skeleton/
    +-- image.sync()             ──────────►  mkosi.sync
    +-- image.prepare()          ──────────►  mkosi.prepare
    +-- image.add_build()        ──────────►  mkosi.build.d/
    +-- image.file() / template()──────────►  mkosi.extra/
    +-- image.run()              ──────────►  mkosi.postinst
    +-- image.finalize()         ──────────►  mkosi.finalize
    +-- image.debloat()          ──────────►  mkosi.finalize (appended)
    +-- image.postoutput()       ──────────►  mkosi.postoutput
    +-- image.clean()            ──────────►  mkosi.clean
    +-- image.partitions()       ──────────►  mkosi.repart/
    +-- image.on_boot()          ──────────►  systemd oneshot service
    +-- invokes mkosi
```

### Phase execution order

| #  | mkosi phase    | SDK method               | Runs in        | Purpose |
|----|----------------|--------------------------|----------------|---------|
| 1  | skeleton/      | `image.skeleton()`       | (file copy)    | Base filesystem before package manager |
| 2  | mkosi.sync     | `image.sync()`           | Host           | Source synchronization |
| 3  | mkosi.prepare  | `image.prepare()`        | Image (nspawn) | pip, npm, etc. after base packages |
| 4  | mkosi.build.d/ | `image.add_build()`      | Build overlay  | Compile from source ($DESTDIR) |
| 5  | mkosi.extra/   | `image.file()`           | (file copy)    | Static files into image |
| 6  | mkosi.postinst | `image.run()`            | Image (nspawn) | Configure image, enable services |
| 7  | mkosi.finalize | `image.finalize()`       | Host           | Host-side post-processing ($BUILDROOT) |
| 8  | mkosi.repart/  | `image.partitions()`     | Host           | systemd-repart partition layout |
| 9  | (image output) |                          |                | Disk image written |
| 10 | mkosi.postoutput | `image.postoutput()`   | Host           | Sign, measure, upload |
| 11 | mkosi.clean    | `image.clean()`          | Host           | Cleanup on `mkosi clean` |
| —  | (VM boot)      | `image.on_boot()`        | VM             | Runtime init (not a build phase) |

### Environment variables available in scripts

| Variable | Available in | Purpose |
|----------|-------------|---------|
| `$SRCDIR` | prepare, build, postinst, finalize | Build sources mount |
| `$BUILDDIR` | build | Out-of-tree build directory |
| `$DESTDIR` | build | Artifacts destined for final image |
| `$BUILDROOT` | all scripts | Image root filesystem |
| `$OUTPUTDIR` | build, postinst, finalize | Build artifacts staging |
| `$PACKAGEDIR` | all scripts | Local package repository |
| `$SOURCE_DATE_EPOCH` | all scripts | Reproducibility timestamp |

## Architecture

```
img = Image(build_dir="build")
# ... configuration calls ...
img.build()
    |
    +-- resolves Build declarations → build scripts
    +-- generates mkosi.conf (from Image config)
    +-- generates mkosi.skeleton/ (from image.skeleton() calls)
    +-- generates mkosi.sync (from image.sync() calls)
    +-- generates mkosi.prepare (from image.prepare() calls)
    +-- generates mkosi.build.d/ (from Build.* declarations)
    +-- generates mkosi.extra/ tree (from image.file/template calls)
    +-- generates mkosi.postinst (from image.run() calls + service setup)
    +-- generates mkosi.finalize (from image.finalize() + debloat() calls)
    +-- generates mkosi.postoutput (from image.postoutput() calls)
    +-- generates mkosi.clean (from image.clean() calls)
    +-- generates mkosi.repart/ (from image.partitions() calls)
    +-- generates kernel .config (from Kernel() config)
    +-- generates systemd .service units (from image.service() calls)
    +-- generates boot-time oneshot service (from image.on_boot() calls)
    +-- invokes mkosi (actual image build)
    +-- returns BuildResult

img.measure(backend="rtmr")
    |
    +-- reads build artifacts from build_dir
    +-- replays TDX measurement algorithm over firmware + kernel + rootfs
    +-- returns Measurements (indexable, serializable)

img.deploy(target="qemu", memory="4G")
    |
    +-- reads build artifacts from build_dir
    +-- launches VM / uploads image to cloud provider
```

## API Surface

### Image — the root object

```python
from tdx import Image, Kernel

img = Image(
    build_dir="build",               # where build artifacts go (default: ./build/)
    base="debian/bookworm",          # or "ubuntu/noble", "alpine/3.20"
    default_profile="default",       # name of the default profile
)

# Kernel — opinionated TDX default, fully overridable
img.kernel = Kernel.tdx()                              # sensible defaults
img.kernel = Kernel.tdx(version="6.8", cmdline="...")  # override specific knobs
img.kernel = Kernel.tdx(config_file="./my.config")     # bring your own

# Full VM knobs
img.init = "systemd"              # or "busybox", or a custom binary path
img.default_target = "minimal.target"
img.firmware = "ovmf"             # or a custom OVMF path
img.locale = None                 # stripped by default
img.docs = False                  # no man pages

# Partitions (generates mkosi.repart/ configs)
img.partitions(
    Image.partition("/", fs="ext4", size="2G"),
    Image.partition("/var", fs="ext4", size="10G"),
)

# Encryption
img.encryption(type="luks2", key_source="tpm")

# Networking
img.network(
    vsock=True,
    firewall_rules=["ACCEPT tcp 8545", "DROP all"],
)

# SSH (dev only)
img.ssh(enabled=True, key_delivery="http")
```

### add_build — reproducible package building

`image.add_build()` registers build steps (compiled from source).
These run in the mkosi build overlay phase.

Builder modules provide flexible compiler sourcing — use precompiled
releases, custom tarballs via `fetch()`, or build compilers from source:

```python
from tdx.builders.go import GoBuild
from tdx.builders.rust import RustBuild
from tdx.builders.dotnet import DotnetBuild
from tdx import Image, Build, fetch

img = Image(build_dir="build")

# Go: precompiled official release (default)
prover = GoBuild(
    version="1.22.5",
    src="./prover/",
    output="/usr/local/bin/my-prover",
    ldflags="-s -w -X main.version=1.0.0",
)

# Rust: specific toolchain
raiko = RustBuild(
    toolchain="1.83.0",
    src="./raiko/",
    output="/usr/local/bin/raiko",
    features=["tdx", "sgx"],
    build_deps=["libssl-dev", "pkg-config"],
)

# .NET
nethermind = DotnetBuild(
    sdk_version="10.0",
    src="./nethermind/",
    project="src/Nethermind/Nethermind.Runner",
    output="/opt/nethermind/",
)

# Universal fallback — any build system
custom = Build.script(
    name="my-tool",
    src="./tools/my-tool/",
    build_script="make release",
    artifacts={"build/my-tool": "/usr/local/bin/my-tool"},
    build_deps=["cmake", "libfoo-dev"],
)

img.add_build(prover, raiko, nethermind, custom)
```

### Fetch — verified resource downloads

```python
from tdx import fetch, fetch_git

# Download and verify a tarball (returns Path to cached file)
tarball = fetch(
    "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz",
    sha256="904b924d435eaea086515c6fc840b4ab...",
)

# Fetch a git repo at a specific tag
src = fetch_git(
    "https://github.com/golang/go",
    tag="go1.22.5",
    sha256="a1b2c3d4e5f6...",  # Hash of file tree contents
)
```

### Users

```python
# System users — created in the image at build time
image.user("nethermind", system=True, home="/var/lib/nethermind")
image.user("monitoring", system=True, uid=999)
```

### Secrets — post-measurement injection

Secrets are declared at build time but injected after the VM boots and
has been measured. They never affect the TDX measurement.

```python
# Declare secrets (not baked into the image)
image.secret("JWT_SECRET", dest="/etc/nethermind/jwt.hex", owner="nethermind")
image.secret("TLS_CERT", dest="/etc/ssl/certs/app.pem")

# Configure how secrets are delivered after boot
image.secret_delivery("vsock")  # or "ssh", or "script"
```

### Services — full systemd control

```python
image.service(
    name="nethermind",
    exec="/opt/nethermind/nethermind --config mainnet",
    after=["network-online.target"],
    restart="always",
    user="nethermind",
    extra_unit={
        "Service": {"MemoryMax": "8G", "LimitNOFILE": "65535"},
    },
)
```

### Debloat — image stripping and hardening

TDX images should be minimal. The SDK provides a declarative debloat
API with defaults matching nethermind-tdx's `debloat.sh` and
`debloat-systemd.sh`.

The debloat has two parts, mirroring the nethermind-tdx approach:

1. **Path stripping** — removes docs, caches, locales, unnecessary
   systemd data, and other paths from `$BUILDROOT`. Runs in the
   **finalize** phase (host-side, with `$BUILDROOT` access).

2. **Systemd minimization** — whitelist-based. Only essential units
   and binaries are kept; everything else is masked (symlinked to
   `/dev/null`). Also runs in **finalize**.

```python
# Apply the default TDX debloat. This is the recommended starting point.
image.debloat()

# The default is equivalent to:
image.debloat(
    # Paths to remove from $BUILDROOT (matches nethermind-tdx debloat.sh)
    paths_remove=[
        "/etc/machine-id",
        "/etc/*-",
        "/etc/ssh/ssh_host_*_key*",
        "/usr/share/doc",
        "/usr/share/man",
        "/usr/share/info",
        "/usr/share/locale",
        "/usr/share/gcc",
        "/usr/share/gdb",
        "/usr/share/lintian",
        "/usr/share/perl5/debconf",
        "/usr/share/debconf",
        "/usr/share/initramfs-tools",
        "/usr/share/polkit-1",
        "/usr/share/bug",
        "/usr/share/menu",
        "/usr/share/systemd",
        "/usr/share/zsh",
        "/usr/share/mime",
        "/usr/share/bash-completion",
        "/usr/lib/modules",
        "/usr/lib/udev/hwdb.d",
        "/usr/lib/udev/hwdb.bin",
        "/usr/lib/systemd/catalog",
        "/usr/lib/systemd/user",
        "/usr/lib/systemd/user-generators",
        "/usr/lib/systemd/network",
        "/usr/lib/pcrlock.d",
        "/usr/lib/tmpfiles.d",
        "/etc/systemd/network",
        "/etc/credstore",
    ],
    # Also: /var/log/* and /var/cache/* files are deleted (dirs kept)

    # Whitelist-based systemd minimization (matches nethermind-tdx debloat-systemd.sh).
    # Only these units are kept; everything else from the systemd package is
    # masked by symlinking to /dev/null.
    systemd_units_keep=[
        "minimal.target",
        "basic.target",
        "sysinit.target",
        "sockets.target",
        "local-fs.target",
        "local-fs-pre.target",
        "network-online.target",
        "slices.target",
        "systemd-journald.service",
        "systemd-journald.socket",
        "systemd-journald-dev-log.socket",
        "systemd-remount-fs.service",
        "systemd-sysctl.service",
    ],
    # Only these systemd binaries in /usr/bin are kept; others are removed.
    systemd_bins_keep=[
        "systemctl",
        "journalctl",
        "systemd",
        "systemd-tty-ask-password-agent",
    ],
)
```

Customization:

```python
# Keep resolved for DNS (add to the whitelist)
image.debloat(
    systemd_units_keep_extra=[
        "systemd-resolved.service",
        "systemd-resolved.socket",
    ],
)

# Keep bash-completion in dev profile (remove from paths_remove)
with image.profile("dev"):
    image.debloat(
        paths_skip=["/usr/share/bash-completion"],
    )

# No debloat at all (for debugging)
image.debloat(enabled=False)

# Path stripping only, keep systemd intact
image.debloat(systemd_minimize=False)

# Add extra paths to remove on top of the default
image.debloat(
    paths_remove_extra=["/usr/share/fonts", "/usr/lib/python3"],
)
```

The debloat runs in the **finalize** phase because it operates on
`$BUILDROOT` from the host side. This means it runs after postinst
(service enablement, user creation), so `systemctl enable` has already
recorded the unit symlinks before debloat masks the unused units.

### Skeleton — files before the package manager

```python
# Skeleton files are placed BEFORE apt/dnf runs.
# Use for custom apt sources, resolv.conf for build DNS, base dirs.
image.skeleton("/etc/apt/sources.list.d/custom.list",
    content="deb http://my-repo.example.com/debian bookworm main\n")
image.skeleton("/etc/resolv.conf",
    content="nameserver 1.1.1.1\n")
```

### Files, templates, and lifecycle hooks

```python
# Static files (mkosi.extra/ — copied after build)
image.file("/etc/motd", content="Trust domain.\n")
image.file("/etc/app/config.toml", src="./configs/app.toml")

# Templated configs
image.template(
    src="./configs/nethermind.cfg.j2",
    dest="/etc/nethermind/config.json",
    vars={"network": "mainnet", "rpc_port": 8545},
)

# --- mkosi lifecycle hooks ---

# Sync: source preparation before build
image.sync("git submodule update --init --recursive")

# Prepare: runs after base packages, before build phase
# Use for pip, npm, or other non-distro package managers
image.prepare("pip install --root $BUILDROOT pyyaml requests")

# Postinst: runs after build artifacts installed (the default "run" target)
# Use for enabling services, creating users, custom configuration
image.run("sysctl --system")
image.run_script("./scripts/harden.sh")

# Finalize: runs on HOST with $BUILDROOT access
# Use for host-side operations, foreign arch builds
image.finalize("du -sh $BUILDROOT > /tmp/image-size.txt")

# Post-output: runs after disk image is written
# Use for signing, measurements, checksums
image.postoutput("sha256sum $OUTPUTDIR/*.raw > $OUTPUTDIR/SHA256SUMS")
image.postoutput_script("./scripts/sign-image.sh")

# Clean: runs on `mkosi clean`
image.clean("rm -rf ./build-cache/")

# Boot-time: runs when VM actually boots (not a build phase)
image.on_boot("/usr/local/bin/tdx-init --format on_initialize --key tpm")
```

### System packages

```python
image.install("prometheus", "dropbear", "iptables")
```

### Profiles — scope everything

The `with image.profile("name")` context manager scopes all operations.
Configuration calls inside a profile block only apply to that profile.
Build, measure, and deploy inside a profile block operate on that profile.

Outside any profile block, you operate on the default profile (name
configurable via `Image(default_profile="...")`).

```python
img = Image(build_dir="build", base="debian/bookworm")

# These apply to the default profile
img.install("ca-certificates", "iptables")
img.debloat()

# Dev profile: adds packages, keeps bash-completion
with img.profile("dev"):
    img.ssh(enabled=True)
    img.install("strace", "gdb", "vim")
    img.debloat(paths_skip=["/usr/share/bash-completion"])

# Azure profile: changes cloud-specific settings
with img.profile("azure"):
    img.cloud = "azure"
    img.secure_boot = True
    img.attestation_backend = "azure"

# Build the default profile
img.build()

# Build only the dev profile
with img.profile("dev"):
    img.build()

# Measure the default profile
measurements = img.measure(backend="rtmr")

# Measure the azure profile
with img.profile("azure"):
    pcrs = img.measure(backend="azure")

# Deploy the default profile
img.deploy(target="qemu", memory="4G")

# Deploy the dev profile
with img.profile("dev"):
    img.deploy(target="qemu", memory="4G")
```

### Repositories — custom package sources

```python
# High-level: adds apt sources + keyring via skeleton
image.repository(
    url="https://packages.microsoft.com/debian/12/prod",
    suite="bookworm",
    components=["main"],
    keyring="./keys/microsoft.gpg",
)
# Now dotnet packages are available during package install
image.install("dotnet-sdk-10.0")

# Low-level: same thing via skeleton() directly
image.skeleton(
    "/etc/apt/trusted.gpg.d/microsoft.gpg",
    src="./keys/microsoft.gpg",
)
image.skeleton(
    "/etc/apt/sources.list.d/microsoft.sources",
    content="""\
Types: deb
URIs: https://packages.microsoft.com/debian/12/prod
Suites: bookworm
Components: main
Signed-By: /etc/apt/trusted.gpg.d/microsoft.gpg
""",
)
```

### build — execute the image build

`image.build()` generates mkosi configs from all the configuration
registered on the image, then invokes mkosi to produce the disk image.

```python
img = Image(build_dir="build", base="debian/bookworm")
# ... configuration ...

# Build the (default profile) image
result = img.build()
# result.image_path  → Path("build/my-vm.raw")
# result.kernel_path → Path("build/my-vm.vmlinuz")
# result.build_dir   → Path("build/")

# Build a specific profile
with img.profile("dev"):
    result = img.build()

# Inspect the generated mkosi configs without building
img.emit_mkosi("./out/")
```

If `build()` is called without a prior `build()` having been run, it
builds. If build artifacts already exist in `build_dir`, `measure()` and
`deploy()` use them directly — they do not require `build()` to be
called in the same script.

### measure — compute expected measurements

`image.measure()` reads the build artifacts from `build_dir` and computes
expected hardware measurements. Fails if no build artifacts exist.

Two measurement backends match the two TDX deployment models:

**Raw TDX** (bare-metal or QEMU) — RTMR-based:

```
RTMR[0] — firmware (OVMF/TDVF) measurement
RTMR[1] — OS loader + kernel + initrd + cmdline
RTMR[2] — OS runtime (rootfs dm-verity hash)
RTMR[3] — application-defined (unused by default)
```

**Cloud TDX** (Azure, GCP) — vTPM PCR-based:

```
PCR[0]  — firmware
PCR[4]  — boot loader
PCR[7]  — Secure Boot policy
PCR[9]  — kernel + initrd
PCR[11] — unified kernel image hash
PCR[15] — custom (dm-verity root hash)
```

```python
img = Image(build_dir="build", base="debian/bookworm")
# ... configuration + build ...

# Raw TDX: compute RTMRs
rtmrs = img.measure(backend="rtmr")
print(rtmrs[0])  # RTMR[0] firmware hash
print(rtmrs[2])  # RTMR[2] rootfs dm-verity hash

# Azure CVM: compute vTPM PCRs
with img.profile("azure"):
    pcrs = img.measure(backend="azure")
    print(pcrs[11])  # PCR[11] UKI hash

# Export for CI/CD
rtmrs.to_json("build/measurements.json")
rtmrs.to_cbor("build/measurements.cbor")

# Verify a running VM's quote against expected measurements
rtmrs.verify(quote=Path("./quote.bin"))
```

### deploy — launch or upload the image

`image.deploy()` reads build artifacts from `build_dir` and launches a
VM or uploads the image to a cloud provider. Parameters vary by target.

```python
img = Image(build_dir="build", base="debian/bookworm")
# ... configuration + build ...

# Local QEMU — for development and testing
img.deploy(target="qemu", memory="4G", cpus=2, vsock_cid=3)

# Azure Confidential VM
img.deploy(target="azure",
    resource_group="my-rg",
    vm_size="Standard_DC4as_v5",
    location="eastus",
)

# GCP Confidential VM
img.deploy(target="gcp",
    project="my-project",
    zone="us-central1-a",
    machine_type="n2d-standard-4",
)

# Remote bare-metal via SSH
img.deploy(target="ssh",
    host="root@10.0.0.1",
    image_path="/var/lib/vms/my-vm.raw",
)

# Deploy a specific profile
with img.profile("dev"):
    img.deploy(target="qemu", memory="4G")
```

### Full pipeline example

```python
#!/usr/bin/env python3
from tdx import Image, Build, Kernel

img = Image(build_dir="build", base="debian/bookworm")
img.kernel = Kernel.tdx(version="6.8")
img.install("ca-certificates")
img.debloat()
img.add_build(Build.go(
    name="my-prover", src="./prover/",
    go_version="1.22", output="/usr/local/bin/my-prover",
))
img.service(name="my-prover", exec="/usr/local/bin/my-prover")

# Build, measure, deploy
img.build()
rtmrs = img.measure(backend="rtmr")
rtmrs.to_json("build/measurements.json")
img.deploy(target="qemu", memory="4G", cpus=2)
```

## Generated output structure

After `image.emit_mkosi("./out/")`:

```
./out/
├── mkosi.conf                  # Distribution, packages, output format
├── mkosi.skeleton/             # Files before package manager (image.skeleton())
├── mkosi.kernel/
│   └── .config                 # Kernel config with TDX defaults
├── mkosi.sync                  # Source sync script (image.sync())
├── mkosi.prepare               # Prepare script (image.prepare())
├── mkosi.build.d/
│   ├── 00-nethermind.sh        # Build scripts from Build.* declarations
│   ├── 01-my-prover.sh
│   └── 02-raiko.sh
├── mkosi.extra/                # Files copied into image
│   ├── etc/
│   │   ├── kernel/cmdline
│   │   ├── motd
│   │   ├── nethermind/config.json
│   │   └── systemd/system/
│   │       ├── nethermind.service
│   │       ├── my-prover.service
│   │       └── tdx-boot-init.service
│   └── usr/local/lib/tdx/
│       └── on-boot.sh          # Boot-time script
├── mkosi.postinst              # Post-installation script (image.run())
├── mkosi.finalize              # Finalize script (image.finalize())
├── mkosi.postoutput            # Post-output script (image.postoutput())
├── mkosi.clean                 # Clean script (image.clean())
└── mkosi.repart/               # Partition layout
    ├── 00-root.conf            # Root partition
    └── 01-var.conf             # /var partition
```
