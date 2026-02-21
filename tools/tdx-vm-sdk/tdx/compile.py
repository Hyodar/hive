"""Compile a resolved Image into mkosi configs, scripts, and file trees."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

from tdx.image import FileEntry, ResolvedImage, RunCommand, TemplateEntry


class MkosiCompiler:
    """Translates a ResolvedImage into a directory of mkosi configs and scripts.

    This is the core of the SDK: a compiler from the Python DSL to the
    mkosi build system. Everything is visible and inspectable — use
    --emit-mkosi to see exactly what gets generated.
    """

    def __init__(self, resolved: ResolvedImage, output_dir: str):
        self.resolved = resolved
        self.output = Path(output_dir)

    def compile(self) -> None:
        """Generate all mkosi configs, scripts, and file trees."""
        self.output.mkdir(parents=True, exist_ok=True)

        self._write_mkosi_conf()
        self._write_kernel_config()
        self._write_build_scripts()
        self._write_service_units()
        self._write_files()
        self._write_templates()
        self._write_postinst()
        self._write_boot_scripts()

    def _write_mkosi_conf(self) -> None:
        r = self.resolved

        # Map base to mkosi distribution
        distro, release = r.base.split("/", 1)
        distro_map = {"debian": "debian", "ubuntu": "ubuntu", "alpine": "alpine"}

        sections: dict[str, dict[str, str]] = {}

        # [Distribution]
        sections["Distribution"] = {
            "Distribution": distro_map.get(distro, distro),
            "Release": release,
        }

        # [Output]
        sections["Output"] = {
            "ImageId": r.name,
            "Format": "disk",
        }

        # [Content]
        content: dict[str, str] = {}
        if r.packages:
            content["Packages"] = "\n    ".join(r.packages)
        if not r.docs:
            content["WithDocs"] = "no"
        if r.locale is None:
            content["Locale"] = "C.UTF-8"
        else:
            content["Locale"] = r.locale
        if content:
            sections["Content"] = content

        # [Partitions] — generate repart configs separately
        # mkosi uses systemd-repart configs in mkosi.repart/

        # [Validation]
        sections["Validation"] = {
            "SecureBoot": "yes" if r.secure_boot else "no",
        }

        # Write mkosi.conf
        lines: list[str] = []
        for section, kvs in sections.items():
            lines.append(f"[{section}]")
            for k, v in kvs.items():
                lines.append(f"{k}={v}")
            lines.append("")

        (self.output / "mkosi.conf").write_text("\n".join(lines))

    def _write_kernel_config(self) -> None:
        kconfig = self.resolved.kernel.to_kconfig()
        kconfig_dir = self.output / "mkosi.kernel"
        kconfig_dir.mkdir(exist_ok=True)
        (kconfig_dir / ".config").write_text(kconfig)

        # Also write cmdline
        (self.output / "mkosi.extra" / "etc" / "kernel").mkdir(parents=True, exist_ok=True)
        (self.output / "mkosi.extra" / "etc" / "kernel" / "cmdline").write_text(
            self.resolved.kernel.cmdline + "\n"
        )

    def _write_build_scripts(self) -> None:
        if not self.resolved.builds:
            return

        scripts_dir = self.output / "mkosi.build.d"
        scripts_dir.mkdir(exist_ok=True)

        for i, artifact in enumerate(self.resolved.builds):
            script = f"#!/bin/bash\nset -euo pipefail\n\n{artifact.to_build_script()}\n"
            script_path = scripts_dir / f"{i:02d}-{artifact.name}.sh"
            script_path.write_text(script)
            script_path.chmod(0o755)

    def _write_service_units(self) -> None:
        if not self.resolved.services:
            return

        units_dir = self.output / "mkosi.extra" / "etc" / "systemd" / "system"
        units_dir.mkdir(parents=True, exist_ok=True)

        for svc in self.resolved.services:
            unit_path = units_dir / f"{svc.name}.service"
            unit_path.write_text(svc.to_unit_file())

    def _write_files(self) -> None:
        extra = self.output / "mkosi.extra"

        for f in self.resolved.files:
            dest = extra / f.dest.lstrip("/")
            dest.parent.mkdir(parents=True, exist_ok=True)

            if f.content is not None:
                dest.write_text(f.content)
            elif f.src is not None:
                shutil.copy2(f.src, dest)

    def _write_templates(self) -> None:
        if not self.resolved.templates:
            return

        extra = self.output / "mkosi.extra"

        for tmpl in self.resolved.templates:
            dest = extra / tmpl.dest.lstrip("/")
            dest.parent.mkdir(parents=True, exist_ok=True)

            # Read Jinja2 template and render
            src_content = Path(tmpl.src).read_text()
            rendered = _render_template(src_content, tmpl.vars)
            dest.write_text(rendered)

    def _write_postinst(self) -> None:
        """Write build-time run() commands as mkosi.postinst scripts."""
        build_commands = [
            cmd for cmd in self.resolved.run_commands if cmd.phase == "build"
        ]
        if not build_commands and not self.resolved.services:
            return

        parts = ["#!/bin/bash", "set -euo pipefail", ""]

        # Service user creation and enable commands
        for svc in self.resolved.services:
            for cmd in svc.setup_commands():
                parts.append(cmd)

        # Default target
        parts.append(f"systemctl set-default {self.resolved.default_target}")
        parts.append("")

        # Build-time run commands
        for cmd in build_commands:
            if cmd.command:
                parts.append(cmd.command)
            elif cmd.script:
                parts.append(f"bash {cmd.script!r}")
            parts.append("")

        postinst = self.output / "mkosi.postinst"
        postinst.write_text("\n".join(parts))
        postinst.chmod(0o755)

    def _write_boot_scripts(self) -> None:
        """Write on_boot() commands as init scripts."""
        boot_commands = [
            cmd for cmd in self.resolved.run_commands if cmd.phase == "boot"
        ]
        if not boot_commands:
            return

        parts = ["#!/bin/bash", "set -euo pipefail", ""]
        for cmd in boot_commands:
            if cmd.command:
                parts.append(cmd.command)
            elif cmd.script:
                parts.append(f"bash {cmd.script!r}")
            parts.append("")

        # Install as a oneshot service that runs before everything
        extra = self.output / "mkosi.extra"
        scripts_dir = extra / "usr" / "local" / "lib" / "tdx"
        scripts_dir.mkdir(parents=True, exist_ok=True)

        boot_script = scripts_dir / "on-boot.sh"
        boot_script.write_text("\n".join(parts))
        boot_script.chmod(0o755)

        # Create a systemd service for it
        units_dir = extra / "etc" / "systemd" / "system"
        units_dir.mkdir(parents=True, exist_ok=True)

        unit = (
            "[Unit]\n"
            "Description=TDX boot-time initialization\n"
            "DefaultDependencies=no\n"
            "Before=sysinit.target\n"
            "ConditionPathExists=/usr/local/lib/tdx/on-boot.sh\n"
            "\n"
            "[Service]\n"
            "Type=oneshot\n"
            "ExecStart=/usr/local/lib/tdx/on-boot.sh\n"
            "RemainAfterExit=yes\n"
            "\n"
            "[Install]\n"
            "WantedBy=sysinit.target\n"
        )
        (units_dir / "tdx-boot-init.service").write_text(unit)


def _render_template(template: str, vars: dict[str, Any]) -> str:
    """Simple Jinja2-style template rendering.

    Supports {{ var }} substitution. For full Jinja2 features,
    users can pip install jinja2 and the SDK will use it if available.
    """
    try:
        import jinja2
        env = jinja2.Environment(undefined=jinja2.StrictUndefined)
        return env.from_string(template).render(**vars)
    except ImportError:
        # Fallback: simple {{ var }} replacement
        result = template
        for key, val in vars.items():
            result = result.replace("{{ " + key + " }}", str(val))
            result = result.replace("{{" + key + "}}", str(val))
        return result
