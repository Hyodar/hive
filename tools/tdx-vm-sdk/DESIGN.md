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
- `image.run("shell commands")` — arbitrary commands during image build
- `image.run_script("./script.sh")` — run a script file during build
- `image.on_boot("commands")` — run commands at VM boot time (initrd/init)
- `image.file()` / `image.template()` — drop arbitrary files into the image
- `--emit-mkosi` — inspect the generated mkosi configs directly
- `--mkosi-override` — layer your own mkosi.conf on top

The SDK is a **compiler from Python DSL to mkosi configs + build scripts**,
not a black box.

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
    +-- generates mkosi.build (from Build.* declarations)
    +-- generates systemd .service units (from image.service() calls)
    +-- generates mkosi.extra/ tree (from image.file/template calls)
    +-- injects image.run() commands as mkosi.postinst scripts
    +-- generates kernel .config (from Kernel() config)
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

# Partitions
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

### Files, templates, and escape hatches

```python
# Static files
image.file("/etc/motd", content="Trust domain.\n")
image.file("/etc/app/config.toml", src="./configs/app.toml")

# Templated configs
image.template(
    src="./configs/nethermind.cfg.j2",
    dest="/etc/nethermind/config.json",
    vars={"network": "mainnet", "rpc_port": 8545},
)

# Arbitrary build-time commands
image.run("rm -rf /usr/lib/systemd/system/getty*")
image.run_script("./scripts/harden.sh")

# Boot-time commands (in initrd/init)
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
