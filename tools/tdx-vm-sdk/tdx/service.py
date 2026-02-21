"""Systemd service unit generation."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Service:
    """A systemd service to be installed in the VM image.

    Covers common service options declaratively, with extra_unit as
    an escape hatch for any systemd directive.
    """

    name: str
    exec_start: str
    after: list[str] = field(default_factory=list)
    requires: list[str] = field(default_factory=list)
    wants: list[str] = field(default_factory=list)
    restart: str = "on-failure"
    user: str | None = None
    group: str | None = None
    working_directory: str | None = None

    # Full escape hatch: any systemd unit section/directive
    extra_unit: dict[str, Any] = field(default_factory=dict)

    def to_unit_file(self) -> str:
        """Render as a complete systemd .service unit file."""
        # Start with [Unit]
        unit_section: dict[str, str] = {
            "Description": self.name,
        }
        if self.after:
            unit_section["After"] = " ".join(self.after)
        if self.requires:
            unit_section["Requires"] = " ".join(self.requires)
        if self.wants:
            unit_section["Wants"] = " ".join(self.wants)

        # Merge extra_unit["Unit"] if present
        if "Unit" in self.extra_unit:
            unit_section.update(self.extra_unit["Unit"])

        # [Service]
        service_section: dict[str, str | list[str]] = {
            "ExecStart": self.exec_start,
            "Restart": self.restart,
        }
        if self.user:
            service_section["User"] = self.user
        if self.group:
            service_section["Group"] = self.group
        if self.working_directory:
            service_section["WorkingDirectory"] = self.working_directory

        # Merge extra_unit["Service"]
        if "Service" in self.extra_unit:
            service_section.update(self.extra_unit["Service"])

        # [Install]
        install_section: dict[str, str] = {
            "WantedBy": "multi-user.target",
        }
        if "Install" in self.extra_unit:
            install_section.update(self.extra_unit["Install"])

        # Render
        lines: list[str] = []
        lines.append("[Unit]")
        for k, v in unit_section.items():
            lines.append(f"{k}={v}")

        lines.append("")
        lines.append("[Service]")
        for k, v in service_section.items():
            if isinstance(v, list):
                for item in v:
                    lines.append(f"{k}={item}")
            else:
                lines.append(f"{k}={v}")

        lines.append("")
        lines.append("[Install]")
        for k, v in install_section.items():
            if isinstance(v, list):
                for item in v:
                    lines.append(f"{k}={item}")
            else:
                lines.append(f"{k}={v}")

        return "\n".join(lines) + "\n"

    def setup_commands(self) -> list[str]:
        """Generate shell commands to create the user and enable the service."""
        cmds: list[str] = []
        if self.user:
            cmds.append(
                f"id -u {self.user} &>/dev/null || useradd -r -s /usr/sbin/nologin {self.user}"
            )
        cmds.append(f"systemctl enable {self.name}.service")
        return cmds
