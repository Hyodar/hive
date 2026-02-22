# TDX VM SDK — Design

A Python SDK for building reproducible, measured TDX virtual machine images.

## Design Principles

### 1. Full configurability, opinionated defaults

Every VM knob is exposed — kernel config, partitions, init system, firmware,
encryption, networking. The SDK provides sensible TDX defaults so you can start
with `Image("my-vm")` and get a working hardened image. But nothing is hidden
or locked: you can override any default down to raw kernel .config entries or
custom OVMF firmware paths.

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
- `--emit-mkosi` — inspect the generated mkosi configs directly
- `--mkosi-override` — layer your own mkosi.conf on top

The SDK is a **compiler from Python DSL to mkosi configs + build scripts**,
not a black box.

## mkosi Lifecycle Mapping

The SDK maps directly to mkosi's build phases. Every phase is exposed:

```
TDXfile (Python)
    |
    v
tdx build
    |                                           mkosi phase
    +-- image.skeleton()         ──────────►  mkosi.skeleton/
    +-- image.sync()             ──────────►  mkosi.sync
    +-- image.prepare()          ──────────►  mkosi.prepare
    +-- image.build()            ──────────►  mkosi.build.d/
    +-- image.file() / template()──────────►  mkosi.extra/
    +-- image.run()              ──────────►  mkosi.postinst
    +-- image.finalize()         ──────────►  mkosi.finalize
    +-- image.postoutput()       ──────────►  mkosi.postoutput
    +-- image.clean()            ──────────►  mkosi.clean
    +-- image.partitions()       ──────────►  mkosi.repart/
    +-- mkosi.conf               ◄──────────  Image(), Kernel(), install()
    +-- image.on_boot()          ──────────►  systemd oneshot service
```

### Phase execution order

| #  | mkosi phase    | SDK method               | Runs in        | Purpose |
|----|----------------|--------------------------|----------------|---------|
| 1  | skeleton/      | `image.skeleton()`       | (file copy)    | Base filesystem before package manager |
| 2  | mkosi.sync     | `image.sync()`           | Host           | Source synchronization |
| 3  | mkosi.prepare  | `image.prepare()`        | Image (nspawn) | pip, npm, etc. after base packages |
| 4  | mkosi.build.d/ | `image.build()`          | Build overlay  | Compile from source ($DESTDIR) |
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
TDXfile (Python)
    |
    v
tdx build
    |
    +-- parses TDXfile, evaluates Python
    +-- resolves Build declarations -> build scripts
    +-- generates mkosi.conf (from Image config)
    +-- generates mkosi.skeleton/ (from image.skeleton() calls)
    +-- generates mkosi.sync (from image.sync() calls)
    +-- generates mkosi.prepare (from image.prepare() calls)
    +-- generates mkosi.build.d/ (from Build.* declarations)
    +-- generates mkosi.extra/ tree (from image.file/template calls)
    +-- generates mkosi.postinst (from image.run() calls + service setup)
    +-- generates mkosi.finalize (from image.finalize() calls)
    +-- generates mkosi.postoutput (from image.postoutput() calls)
    +-- generates mkosi.clean (from image.clean() calls)
    +-- generates mkosi.repart/ (from image.partitions() calls)
    +-- generates kernel .config (from Kernel() config)
    +-- generates systemd .service units (from image.service() calls)
    +-- generates boot-time oneshot service (from image.on_boot() calls)
    +-- invokes mkosi (actual image build)
    +-- computes measurements (for attestation)
```

## API Surface

### Image — the root object

```python
from tdx import Image, Kernel

image = Image(
    name="my-prover",
    base="debian/bookworm",       # or "ubuntu/noble", "alpine/3.20"
)

# Kernel — opinionated TDX default, fully overridable
image.kernel = Kernel.tdx()                              # sensible defaults
image.kernel = Kernel.tdx(version="6.8", cmdline="...")  # override specific knobs
image.kernel = Kernel.tdx(config_file="./my.config")     # bring your own

# Full VM knobs
image.init = "systemd"              # or "busybox", or a custom binary path
image.default_target = "minimal.target"
image.firmware = "ovmf"             # or a custom OVMF path
image.locale = None                 # stripped by default
image.docs = False                  # no man pages

# Partitions (generates mkosi.repart/ configs)
image.partitions(
    Image.partition("/", fs="ext4", size="2G"),
    Image.partition("/var", fs="ext4", size="10G"),
)

# Encryption
image.encryption(type="luks2", key_source="tpm")

# Networking
image.network(
    vsock=True,
    firewall_rules=["ACCEPT tcp 8545", "DROP all"],
)

# SSH (dev only)
image.ssh(enabled=True, key_delivery="http")
```

### Build — reproducible package building

Builder modules provide flexible compiler sourcing — use precompiled
releases, custom tarballs via `fetch()`, or build compilers from source:

```python
from tdx.builders.go import GoBuild
from tdx.builders.rust import RustBuild
from tdx.builders.dotnet import DotnetBuild
from tdx import Build, fetch

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

image.build(prover, raiko, nethermind, custom)
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
API with a sensible default that matches the nethermind-tdx reference.

```python
# Apply the default TDX debloat (equivalent to nethermind-tdx's debloat-systemd.sh
# plus standard image stripping). This is the recommended starting point.
image.debloat()

# Equivalent to:
image.debloat(
    # Systemd services to remove (glob patterns)
    systemd_remove=[
        "getty*",
        "serial-getty*",
        "systemd-homed*",
        "systemd-userdbd*",
        "systemd-firstboot*",
        "systemd-resolved*",
        "systemd-networkd-wait-online*",
        "systemd-timesyncd*",
    ],
    # Additional paths to remove
    paths_remove=[
        "/usr/share/doc/*",
        "/usr/share/info/*",
        "/usr/share/man/*",
        "/usr/share/lintian/*",
        "/var/cache/apt/*",
        "/var/lib/apt/lists/*",
    ],
    # Strip ELF binaries
    strip_binaries=True,
    # Remove shell profiles (no interactive login on TDX VMs)
    shells=False,
)

# Customize: keep resolved and timesyncd, but remove everything else
image.debloat(
    systemd_keep=["systemd-resolved*", "systemd-timesyncd*"],
)

# Minimal debloat: only strip docs and caches, keep all services
image.debloat(
    systemd_remove=[],
    strip_binaries=False,
)

# Add extra removals on top of the default
image.debloat(
    systemd_remove_extra=["systemd-journald*"],
    paths_remove_extra=["/usr/share/zsh/"],
)
```

The `image.debloat()` method generates `image.run()` commands (postinst
phase). It always runs *after* package installation and service setup,
so it won't interfere with apt or systemctl operations.

Default behavior (what `image.debloat()` with no arguments does):

| Category | Action | Rationale |
|----------|--------|-----------|
| getty/serial-getty | Remove | No interactive terminals on TDX VMs |
| systemd-homed | Remove | No home directory management needed |
| systemd-userdbd | Remove | No user database service needed |
| systemd-firstboot | Remove | No first-boot wizard on headless VM |
| systemd-resolved | Remove | Static DNS in TDX images |
| systemd-timesyncd | Remove | Time comes from host or explicit NTP |
| /usr/share/doc,man,info | Remove | No humans reading docs inside the VM |
| apt caches | Remove | Saves space, packages already installed |
| ELF binaries | Strip debug symbols | Smaller image, faster boot |
| Shell profiles | Remove | No interactive shells |

```

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
# Use for enabling services, creating users, debloating
image.run("rm -rf /usr/lib/systemd/system/getty*")
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

### Profiles — same image, different targets

```python
with image.profile("dev"):
    image.ssh(enabled=True)
    image.install("strace", "gdb", "vim")

with image.profile("azure"):
    image.cloud = "azure"
    image.attestation_backend = "azure"
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

### Measurements — pre-launch verification

TDX images are measured by hardware (RTMRs for raw TDX, vTPM PCRs for
cloud TDX). The SDK computes expected measurements at build time so
operators can verify them before trusting a VM.

```python
from tdx import Image

image = Image("my-vm", base="debian/bookworm")
# ... full image definition ...

# After building, compute expected measurements:
# tdx measure TDXfile
# tdx measure TDXfile --backend azure
# tdx measure TDXfile --format json > measurements.json
```

Two measurement backends, matching the two TDX deployment models:

```python
# Raw TDX (bare-metal or QEMU): RTMR-based measurement
# The SDK replays the TDX module's measurement algorithm over the
# built image to produce expected RTMR values.
#
# RTMRs extend in order:
#   RTMR[0] — firmware (OVMF/TDVF) measurement
#   RTMR[1] — OS loader + kernel + initrd + cmdline
#   RTMR[2] — OS runtime (rootfs dm-verity hash)
#   RTMR[3] — application-defined (unused by default)

# Cloud TDX (Azure, GCP): vTPM PCR-based measurement
# Cloud providers wrap TDX in a vTPM. The SDK computes expected
# PCR values matching the provider's measurement policy.
#
# Azure CVM measurement chain:
#   PCR[0]  — firmware
#   PCR[4]  — boot loader
#   PCR[7]  — Secure Boot policy
#   PCR[9]  — kernel + initrd
#   PCR[11] — unified kernel image hash
#   PCR[15] — custom (dm-verity root hash)
```

CLI usage:

```bash
# Compute RTMRs for raw TDX deployment
tdx measure TDXfile
#   RTMR[0]: a1b2c3d4...
#   RTMR[1]: e5f6a7b8...
#   RTMR[2]: c9d0e1f2...

# Compute PCRs for Azure CVM deployment
tdx measure TDXfile --backend azure
#   PCR[0]:  1a2b3c4d...
#   PCR[4]:  5e6f7a8b...
#   ...

# Verify a running VM's quote against expected measurements
tdx verify --quote ./quote.bin --measurements ./measurements.json

# Machine-readable output for CI/CD
tdx measure TDXfile --format json > measurements.json
tdx measure TDXfile --format cbor > measurements.cbor
```

### Deployment — build, measure, deploy workflow

The SDK separates build, measure, and deploy into distinct steps.
Each step is independently scriptable.

```python
# Project build path — where build artifacts and the final image go.
# Defaults to ./build/ relative to the TDXfile.
image.output_dir = "build"              # default
image.output_dir = "/mnt/images/my-vm"  # absolute path for CI
```

```bash
# Step 1: Build the image
tdx build TDXfile --output ./build/
#   → ./build/my-vm.raw           (disk image)
#   → ./build/my-vm.vmlinuz       (kernel)
#   → ./build/my-vm.initrd        (initrd, if applicable)
#   → ./build/SHA256SUMS           (checksums)

# Step 2: Compute measurements
tdx measure TDXfile --output ./build/
#   → ./build/my-vm.measurements.json

# Step 3: Deploy
tdx deploy TDXfile --target qemu          # local QEMU/KVM
tdx deploy TDXfile --target azure         # Azure CVM
tdx deploy TDXfile --target gcp           # GCP Confidential VM
tdx deploy TDXfile --target ssh://host    # remote bare-metal via SSH
```

Deployment targets in the TDXfile:

```python
# Local QEMU — for development and testing
image.deploy(
    target="qemu",
    memory="4G",
    cpus=2,
    vsock_cid=3,
    # extra_args passed directly to qemu-system-x86_64
    extra_args=["-nographic"],
)

# Azure Confidential VM
image.deploy(
    target="azure",
    resource_group="my-rg",
    vm_size="Standard_DC4as_v5",
    location="eastus",
    # Azure-specific: the image is uploaded to a managed disk
)

# GCP Confidential VM
image.deploy(
    target="gcp",
    project="my-project",
    zone="us-central1-a",
    machine_type="n2d-standard-4",
)

# Remote bare-metal via SSH
image.deploy(
    target="ssh://root@10.0.0.1",
    image_path="/var/lib/vms/my-vm.raw",
)
```

The three steps are designed to be used independently:

```python
#!/usr/bin/env python3
"""build.py — Build the image."""
import subprocess
subprocess.run(["tdx", "build", "TDXfile", "--output", "build/"], check=True)
```

```python
#!/usr/bin/env python3
"""measure.py — Compute and store measurements."""
import subprocess, json
result = subprocess.run(
    ["tdx", "measure", "TDXfile", "--format", "json"],
    capture_output=True, text=True, check=True,
)
measurements = json.loads(result.stdout)
# Upload to attestation service, store in CI artifacts, etc.
print(f"RTMR[2] (rootfs): {measurements['rtmr'][2]}")
```

```python
#!/usr/bin/env python3
"""deploy.py — Deploy to target environment."""
import subprocess
subprocess.run(["tdx", "deploy", "TDXfile", "--target", "qemu"], check=True)
```

Or all in one:

```bash
tdx build TDXfile --output build/ && \
tdx measure TDXfile --output build/ && \
tdx deploy TDXfile --target qemu
```

## CLI

```bash
# Build
tdx build TDXfile                        # Build the image (output: ./build/)
tdx build TDXfile --profile dev          # Build with a profile
tdx build TDXfile --output /tmp/out/     # Custom output path
tdx build TDXfile --emit-mkosi ./out/    # Inspect generated mkosi configs
tdx build TDXfile --mkosi-override ./o/  # Layer custom mkosi.conf

# Measure
tdx measure TDXfile                      # RTMRs for raw TDX (default)
tdx measure TDXfile --backend azure      # PCRs for Azure CVM
tdx measure TDXfile --format json        # Machine-readable output
tdx verify --quote q.bin --measurements m.json  # Verify a live VM

# Deploy
tdx deploy TDXfile --target qemu         # Local QEMU/KVM
tdx deploy TDXfile --target azure        # Azure Confidential VM
tdx deploy TDXfile --target ssh://host   # Remote bare-metal

# Inspect
tdx inspect TDXfile                      # Show resolved config
```

## Generated output structure

After `tdx build --emit-mkosi ./out/`:

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
