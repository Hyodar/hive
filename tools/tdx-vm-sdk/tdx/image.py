"""Image — the root object for TDX VM image definitions."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from tdx.build import BuildArtifact
from tdx.kernel import Kernel
from tdx.service import Service


@dataclass
class Partition:
    mountpoint: str
    fs: str = "ext4"
    size: str = "2G"
    readonly: bool = False


@dataclass
class EncryptionConfig:
    type: str = "luks2"
    key_source: str = "tpm"
    cipher: str = "aes-xts-plain64"
    key_size: int = 512


@dataclass
class NetworkConfig:
    interfaces: list[str] = field(default_factory=lambda: ["virtio-net"])
    vsock: bool = True
    firewall_rules: list[str] = field(default_factory=list)


@dataclass
class SSHConfig:
    enabled: bool = False
    key_delivery: str = "http"
    restrictions: list[str] = field(
        default_factory=lambda: ["no-port-forwarding", "no-agent-forwarding"]
    )


@dataclass
class FileEntry:
    dest: str
    src: str | None = None
    content: str | None = None


@dataclass
class TemplateEntry:
    src: str
    dest: str
    vars: dict[str, Any] = field(default_factory=dict)


@dataclass
class SkeletonEntry:
    """A file to place in mkosi.skeleton/ (copied BEFORE package manager runs)."""
    dest: str
    src: str | None = None
    content: str | None = None


@dataclass
class RunCommand:
    """A shell command or script to run at a specific mkosi lifecycle phase.

    Phases map directly to mkosi's script hooks, in execution order:

        sync       → mkosi.sync        Source synchronization before build
        prepare    → mkosi.prepare     After base packages, before build (pip, npm, etc.)
        build      → mkosi.build       Compile from source ($DESTDIR for artifacts)
        postinst   → mkosi.postinst    After artifacts installed, configure image
        finalize   → mkosi.finalize    Runs on HOST with $BUILDROOT access
        postoutput → mkosi.postoutput  After image generated (signing, upload)
        clean      → mkosi.clean       Cleanup on `mkosi clean`
        boot       → systemd service   Runs at VM boot time (not an mkosi phase)
    """
    command: str | None = None
    script: str | None = None
    phase: str = "postinst"


class Profile:
    """Captures configuration overrides for a named profile (dev, azure, etc.)."""

    def __init__(self, name: str):
        self.name = name
        self.packages: list[str] = []
        self.services: list[Service] = []
        self.files: list[FileEntry] = []
        self.run_commands: list[RunCommand] = []
        self.overrides: dict[str, Any] = {}


class Image:
    """Root object for defining a TDX VM image.

    Provides opinionated defaults for a hardened TDX guest, but every
    knob is exposed for full control.
    """

    def __init__(
        self,
        name: str,
        base: str = "debian/bookworm",
    ):
        self.name = name
        self.base = base

        # Kernel — sensible TDX defaults
        self.kernel = Kernel.tdx()

        # Init system
        self.init: str = "systemd"
        self.default_target: str = "minimal.target"

        # Firmware
        self.firmware: str = "ovmf"
        self.secure_boot: bool = False

        # Image content flags
        self.locale: str | None = None
        self.docs: bool = False

        # Cloud / attestation
        self.cloud: str | None = None
        self.attestation_backend: str | None = None

        # Internal state
        self._partitions: list[Partition] = [
            Partition("/", fs="ext4", size="2G"),
        ]
        self._encryption: EncryptionConfig | None = None
        self._network: NetworkConfig = NetworkConfig()
        self._ssh: SSHConfig = SSHConfig()
        self._packages: list[str] = []
        self._builds: list[BuildArtifact] = []
        self._services: list[Service] = []
        self._files: list[FileEntry] = []
        self._templates: list[TemplateEntry] = []
        self._skeleton: list[SkeletonEntry] = []
        self._run_commands: list[RunCommand] = []
        self._profiles: dict[str, Profile] = {}
        self._active_profile: Profile | None = None

    # --- Partitions ---

    @staticmethod
    def partition(mountpoint: str, fs: str = "ext4", size: str = "2G", readonly: bool = False) -> Partition:
        return Partition(mountpoint=mountpoint, fs=fs, size=size, readonly=readonly)

    def partitions(self, *parts: Partition) -> None:
        self._partitions = list(parts)

    # --- Encryption ---

    def encryption(
        self,
        type: str = "luks2",
        key_source: str = "tpm",
        cipher: str = "aes-xts-plain64",
        key_size: int = 512,
    ) -> None:
        self._encryption = EncryptionConfig(
            type=type, key_source=key_source, cipher=cipher, key_size=key_size
        )

    # --- Network ---

    def network(
        self,
        interfaces: list[str] | None = None,
        vsock: bool = True,
        firewall_rules: list[str] | None = None,
    ) -> None:
        self._network = NetworkConfig(
            interfaces=interfaces or ["virtio-net"],
            vsock=vsock,
            firewall_rules=firewall_rules or [],
        )

    # --- SSH ---

    def ssh(
        self,
        enabled: bool = True,
        key_delivery: str = "http",
        restrictions: list[str] | None = None,
    ) -> None:
        self._ssh = SSHConfig(
            enabled=enabled,
            key_delivery=key_delivery,
            restrictions=restrictions or ["no-port-forwarding", "no-agent-forwarding"],
        )

    # --- Packages ---

    def install(self, *packages: str) -> None:
        target = self._active_profile or self
        if isinstance(target, Profile):
            target.packages.extend(packages)
        else:
            self._packages.extend(packages)

    # --- Builds ---

    def build(self, *artifacts: BuildArtifact) -> None:
        self._builds.extend(artifacts)

    # --- Services ---

    def service(
        self,
        name: str,
        exec: str,
        after: list[str] | None = None,
        requires: list[str] | None = None,
        restart: str = "on-failure",
        user: str | None = None,
        extra_unit: dict[str, Any] | None = None,
    ) -> None:
        svc = Service(
            name=name,
            exec_start=exec,
            after=after or [],
            requires=requires or [],
            restart=restart,
            user=user,
            extra_unit=extra_unit or {},
        )
        target = self._active_profile or self
        if isinstance(target, Profile):
            target.services.append(svc)
        else:
            self._services.append(svc)

    # --- Files ---

    def file(self, dest: str, src: str | None = None, content: str | None = None) -> None:
        if src is None and content is None:
            raise ValueError("file() requires either src= or content=")
        target = self._active_profile or self
        entry = FileEntry(dest=dest, src=src, content=content)
        if isinstance(target, Profile):
            target.files.append(entry)
        else:
            self._files.append(entry)

    # --- Templates ---

    def template(self, src: str, dest: str, vars: dict[str, Any] | None = None) -> None:
        self._templates.append(TemplateEntry(src=src, dest=dest, vars=vars or {}))

    # --- Skeleton (files placed BEFORE package manager) ---

    def skeleton(self, dest: str, src: str | None = None, content: str | None = None) -> None:
        """Add a file to the skeleton tree (copied before package manager runs).

        Use for base filesystem layout: custom apt sources, resolv.conf for
        build-time DNS, base directory structure, etc.
        """
        if src is None and content is None:
            raise ValueError("skeleton() requires either src= or content=")
        self._skeleton.append(SkeletonEntry(dest=dest, src=src, content=content))

    # --- mkosi lifecycle: sync ---

    def sync(self, command: str) -> None:
        """Run commands during the sync phase (source synchronization).

        mkosi.sync runs before anything else. Use for fetching sources,
        submodules, or other pre-build source preparation.
        """
        self._append_run(RunCommand(command=command, phase="sync"))

    def sync_script(self, path: str) -> None:
        """Run a script file during the sync phase."""
        self._run_commands.append(RunCommand(script=path, phase="sync"))

    # --- mkosi lifecycle: prepare ---

    def prepare(self, command: str) -> None:
        """Run commands during the prepare phase (after base packages installed).

        mkosi.prepare runs after the base packages are installed but before
        the build phase. Use for pip install, npm install, or other package
        managers that need the base system in place.

        Runs inside the image namespace with network access.
        """
        self._append_run(RunCommand(command=command, phase="prepare"))

    def prepare_script(self, path: str) -> None:
        """Run a script file during the prepare phase."""
        self._run_commands.append(RunCommand(script=path, phase="prepare"))

    # --- mkosi lifecycle: postinst (the default "run" target) ---

    def run(self, command: str) -> None:
        """Run arbitrary shell commands in the postinst phase.

        mkosi.postinst runs after build artifacts are installed into the
        image. This is the right place for most image customization:
        creating users, enabling services, debloating, hardening, etc.

        Runs inside the image namespace.
        """
        self._append_run(RunCommand(command=command, phase="postinst"))

    def run_script(self, path: str) -> None:
        """Run a script file in the postinst phase."""
        self._run_commands.append(RunCommand(script=path, phase="postinst"))

    # --- mkosi lifecycle: finalize ---

    def finalize(self, command: str) -> None:
        """Run commands during the finalize phase (runs on HOST).

        mkosi.finalize runs on the host system (not inside the image)
        after postinst. It has access to $BUILDROOT pointing to the image
        root. Use for host-side operations like foreign architecture builds
        or operations that need host tools not available in the image.
        """
        self._append_run(RunCommand(command=command, phase="finalize"))

    def finalize_script(self, path: str) -> None:
        """Run a script file during the finalize phase."""
        self._run_commands.append(RunCommand(script=path, phase="finalize"))

    # --- mkosi lifecycle: postoutput ---

    def postoutput(self, command: str) -> None:
        """Run commands after the image has been generated.

        mkosi.postoutput runs on the host after the final disk image is
        written. Use for signing images, computing measurements, uploading
        artifacts, generating checksums, etc.
        """
        self._append_run(RunCommand(command=command, phase="postoutput"))

    def postoutput_script(self, path: str) -> None:
        """Run a script file during the postoutput phase."""
        self._run_commands.append(RunCommand(script=path, phase="postoutput"))

    # --- mkosi lifecycle: clean ---

    def clean(self, command: str) -> None:
        """Run commands during the clean phase.

        mkosi.clean runs when `mkosi clean` is invoked. Use for cleaning
        up extra build outputs that mkosi doesn't know about.
        """
        self._append_run(RunCommand(command=command, phase="clean"))

    def clean_script(self, path: str) -> None:
        """Run a script file during the clean phase."""
        self._run_commands.append(RunCommand(script=path, phase="clean"))

    # --- Boot-time commands (not an mkosi phase) ---

    def on_boot(self, command: str) -> None:
        """Run commands at VM boot time (generated as a systemd oneshot service).

        This is NOT an mkosi build phase. These commands run when the VM
        actually boots — use for disk encryption setup, key fetching,
        attestation initialization, etc.
        """
        self._run_commands.append(RunCommand(command=command, phase="boot"))

    def _append_run(self, cmd: RunCommand) -> None:
        """Append a run command, respecting active profile."""
        target = self._active_profile or self
        if isinstance(target, Profile):
            target.run_commands.append(cmd)
        else:
            self._run_commands.append(cmd)

    # --- Profiles ---

    @contextmanager
    def profile(self, name: str):
        """Define a named profile (dev, azure, production, etc.).

        Usage:
            with image.profile("dev"):
                image.ssh(enabled=True)
                image.install("strace", "gdb")
        """
        prof = Profile(name)
        self._profiles[name] = prof
        self._active_profile = prof
        try:
            yield prof
        finally:
            self._active_profile = None

    # --- Compilation to mkosi ---

    def resolve(self, profile: str | None = None) -> ResolvedImage:
        """Resolve all config (base + optional profile) into a flat structure."""
        resolved = ResolvedImage(
            name=self.name,
            base=self.base,
            kernel=self.kernel,
            init=self.init,
            default_target=self.default_target,
            firmware=self.firmware,
            secure_boot=self.secure_boot,
            locale=self.locale,
            docs=self.docs,
            cloud=self.cloud,
            attestation_backend=self.attestation_backend,
            partitions=list(self._partitions),
            encryption=self._encryption,
            network=self._network,
            ssh=self._ssh,
            packages=list(self._packages),
            builds=list(self._builds),
            services=list(self._services),
            files=list(self._files),
            templates=list(self._templates),
            skeleton=list(self._skeleton),
            run_commands=list(self._run_commands),
        )

        if profile and profile in self._profiles:
            p = self._profiles[profile]
            resolved.packages.extend(p.packages)
            resolved.services.extend(p.services)
            resolved.files.extend(p.files)
            resolved.run_commands.extend(p.run_commands)
            for k, v in p.overrides.items():
                setattr(resolved, k, v)

        return resolved


@dataclass
class ResolvedImage:
    """Flat, fully-resolved image configuration ready for mkosi generation."""

    name: str
    base: str
    kernel: Kernel
    init: str
    default_target: str
    firmware: str
    secure_boot: bool
    locale: str | None
    docs: bool
    cloud: str | None
    attestation_backend: str | None
    partitions: list[Partition]
    encryption: EncryptionConfig | None
    network: NetworkConfig
    ssh: SSHConfig
    packages: list[str]
    builds: list[BuildArtifact]
    services: list[Service]
    files: list[FileEntry]
    templates: list[TemplateEntry]
    skeleton: list[SkeletonEntry]
    run_commands: list[RunCommand]
