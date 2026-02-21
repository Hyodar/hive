"""Kernel configuration for TDX VM images."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


# Minimal kconfig for a TDX guest kernel.
_TDX_KCONFIG_DEFAULTS: dict[str, str] = {
    "CONFIG_INTEL_TDX_GUEST": "y",
    "CONFIG_TDX_GUEST_DRIVER": "y",
    "CONFIG_X86_X2APIC": "y",
    "CONFIG_VSOCK": "m",
    "CONFIG_VIRTIO_VSOCKETS": "m",
    "CONFIG_VHOST_VSOCK": "y",
    "CONFIG_CRYPTO_DEV_VIRTIO": "m",
    "CONFIG_HW_RANDOM_VIRTIO": "m",
    "CONFIG_VIRTIO_NET": "y",
    "CONFIG_VIRTIO_BLK": "y",
    "CONFIG_VIRTIO_CONSOLE": "y",
    "CONFIG_EFI": "y",
    "CONFIG_EFI_STUB": "y",
    "CONFIG_DMI": "y",
    "CONFIG_DMIID": "y",
    # Hardening
    "CONFIG_RANDOMIZE_BASE": "y",
    "CONFIG_RANDOMIZE_MEMORY": "y",
    "CONFIG_STACKPROTECTOR_STRONG": "y",
    "CONFIG_SECURITY": "y",
    "CONFIG_SECURITY_LOCKDOWN_LSM": "y",
}

_DEFAULT_CMDLINE = "console=hvc0 root=/dev/vda2 ro quiet"


@dataclass
class Kernel:
    """Kernel configuration.

    Use Kernel.tdx() for sensible TDX defaults, or construct directly
    for full control.
    """

    version: str = "6.8"
    config: dict[str, str] = field(default_factory=dict)
    config_file: str | None = None
    cmdline: str = _DEFAULT_CMDLINE
    extra_config: dict[str, str] = field(default_factory=dict)

    @classmethod
    def tdx(
        cls,
        version: str = "6.8",
        cmdline: str | None = None,
        config_file: str | None = None,
        extra_config: dict[str, str] | None = None,
    ) -> Kernel:
        """Create a kernel config with sensible TDX defaults.

        All defaults can be overridden. Pass config_file to use your own
        .config entirely, or extra_config to add/override individual knobs.
        """
        merged = dict(_TDX_KCONFIG_DEFAULTS)
        if extra_config:
            merged.update(extra_config)

        return cls(
            version=version,
            config=merged,
            config_file=config_file,
            cmdline=cmdline or _DEFAULT_CMDLINE,
            extra_config=extra_config or {},
        )

    def to_kconfig(self) -> str:
        """Render the config dict as a .config file."""
        if self.config_file:
            content = Path(self.config_file).read_text()
            # Overlay extra_config on top of file
            for key, val in self.extra_config.items():
                # Replace existing or append
                line = f"{key}={val}"
                if key in content:
                    import re
                    content = re.sub(rf"^{re.escape(key)}=.*$", line, content, flags=re.MULTILINE)
                else:
                    content += f"\n{line}"
            return content

        lines = [f"{k}={v}" for k, v in sorted(self.config.items())]
        return "\n".join(lines) + "\n"
