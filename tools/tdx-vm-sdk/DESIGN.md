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

```python
from tdx import Build

# Typed builders for common toolchains
prover = Build.go(
    name="my-prover",
    src="./prover/",
    go_version="1.22",
    output="/usr/local/bin/my-prover",
)

raiko = Build.rust(
    name="raiko",
    src="./raiko/",
    toolchain="nightly-2024-12-01",
    features=["tdx", "sgx"],
    output="/usr/local/bin/raiko",
    build_deps=["libssl-dev", "pkg-config"],
)

nethermind = Build.dotnet(
    name="nethermind",
    src="./nethermind/",
    sdk_version="10.0",
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

## CLI

```bash
tdx build TDXfile                        # Build the image
tdx build TDXfile --profile dev          # Build with a profile
tdx build TDXfile --emit-mkosi ./out/    # Inspect generated mkosi configs
tdx build TDXfile --mkosi-override ./o/  # Layer custom mkosi.conf
tdx measure TDXfile                      # Compute expected measurements
tdx run TDXfile                          # Build + launch in QEMU
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
