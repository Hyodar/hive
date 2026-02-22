"""Compile a resolved Image into mkosi configs, scripts, and file trees.

Maps the Python DSL to mkosi's full lifecycle:

    mkosi.conf           Main configuration
    mkosi.skeleton/      Files copied BEFORE package manager
    mkosi.sync           Source synchronization scripts
    mkosi.prepare        After base packages, before build (pip, npm, etc.)
    mkosi.build.d/       Build scripts ($DESTDIR for artifacts)
    mkosi.extra/         Files copied AFTER build scripts
    mkosi.postinst       After artifacts installed, configure image
    mkosi.finalize       Runs on HOST with $BUILDROOT access
    mkosi.postoutput     After image generated (signing, upload)
    mkosi.clean          Cleanup on `mkosi clean`
    mkosi.repart/        systemd-repart partition definitions
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from tdx.image import FileEntry, RepositoryEntry, ResolvedImage, RunCommand, SecretEntry, SkeletonEntry, TemplateEntry, UserEntry


# All mkosi script phases in execution order (excluding "boot" which is not mkosi).
_MKOSI_PHASES = ("sync", "prepare", "postinst", "finalize", "postoutput", "clean")

# Map our phase names to mkosi script file names.
_PHASE_TO_MKOSI = {
    "sync": "mkosi.sync",
    "prepare": "mkosi.prepare",
    "postinst": "mkosi.postinst",
    "finalize": "mkosi.finalize",
    "postoutput": "mkosi.postoutput",
    "clean": "mkosi.clean",
}


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
        self._write_repart_configs()
        self._write_repositories()
        self._write_skeleton()
        self._write_build_scripts()
        self._write_service_units()
        self._write_files()
        self._write_templates()
        self._write_lifecycle_scripts()
        self._write_boot_scripts()
        self._write_secrets_delivery()

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

        # Build packages: collect build_deps from all builds
        build_deps: list[str] = []
        for b in r.builds:
            build_deps.extend(b.build_deps)
        if build_deps:
            content["BuildPackages"] = "\n    ".join(sorted(set(build_deps)))

        if content:
            sections["Content"] = content

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

    def _write_repart_configs(self) -> None:
        """Generate systemd-repart partition definitions in mkosi.repart/."""
        if not self.resolved.partitions:
            return

        repart_dir = self.output / "mkosi.repart"
        repart_dir.mkdir(exist_ok=True)

        for i, part in enumerate(self.resolved.partitions):
            # Determine partition type UUID based on mountpoint
            type_uuid = _partition_type(part.mountpoint)

            lines = ["[Partition]"]
            lines.append(f"Type={type_uuid}")
            lines.append(f"Format={part.fs}")
            lines.append(f"SizeMinBytes={part.size}")
            lines.append(f"SizeMaxBytes={part.size}")

            if part.mountpoint != "/":
                # systemd-repart uses MountPoint= for non-root partitions
                lines.append(f"MountPoint={part.mountpoint}")

            if part.readonly:
                lines.append("ReadOnly=yes")

            # Encryption via LUKS
            if self.resolved.encryption and part.mountpoint == "/":
                lines.append(f"Encrypt={self.resolved.encryption.type}")

            lines.append("")

            # Name files with ordering prefix and a label
            label = part.mountpoint.strip("/").replace("/", "-") or "root"
            config_path = repart_dir / f"{i:02d}-{label}.conf"
            config_path.write_text("\n".join(lines))

    def _write_repositories(self) -> None:
        """Generate skeleton files and mkosi.conf entries for custom repositories.

        For each repository:
        - Copies keyring file to mkosi.skeleton/etc/apt/trusted.gpg.d/
        - Generates apt sources file in mkosi.skeleton/etc/apt/sources.list.d/
        These go into skeleton so they're available BEFORE the package manager.
        """
        if not self.resolved.repositories:
            return

        skeleton_dir = self.output / "mkosi.skeleton"

        for i, repo in enumerate(self.resolved.repositories):
            repo_name = f"tdx-repo-{i:02d}"

            # Copy keyring if provided
            signed_by = repo.signed_by
            if repo.keyring:
                keyring_dest = f"/etc/apt/trusted.gpg.d/{repo_name}.gpg"
                dest = skeleton_dir / keyring_dest.lstrip("/")
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(repo.keyring, dest)
                signed_by = keyring_dest

            # Generate apt sources list entry
            types = " ".join(repo.types)
            signed_by_opt = f" signed-by={signed_by}" if signed_by else ""
            components = " ".join(repo.components)
            sources_line = f"Types: {types}\nURIs: {repo.url}\nSuites: {repo.suite}\nComponents: {components}"
            if signed_by_opt:
                sources_line += f"\nSigned-By: {signed_by}"

            sources_dest = f"/etc/apt/sources.list.d/{repo_name}.sources"
            dest = skeleton_dir / sources_dest.lstrip("/")
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(sources_line + "\n")

    def _write_skeleton(self) -> None:
        """Write mkosi.skeleton/ tree (files placed BEFORE package manager)."""
        if not self.resolved.skeleton:
            return

        skeleton_dir = self.output / "mkosi.skeleton"

        for entry in self.resolved.skeleton:
            dest = skeleton_dir / entry.dest.lstrip("/")
            dest.parent.mkdir(parents=True, exist_ok=True)

            if entry.content is not None:
                dest.write_text(entry.content)
            elif entry.src is not None:
                shutil.copy2(entry.src, dest)

    def _write_build_scripts(self) -> None:
        """Write BuildArtifact declarations as mkosi.build.d/ scripts.

        These run in the build overlay with $DESTDIR available. Build
        packages are installed in the overlay and stripped from the final image.
        """
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

    def _write_lifecycle_scripts(self) -> None:
        """Generate mkosi scripts for each lifecycle phase.

        Each phase gets its own script file. postinst additionally gets
        service setup commands (user creation, systemctl enable).
        """
        for phase in _MKOSI_PHASES:
            commands = [
                cmd for cmd in self.resolved.run_commands if cmd.phase == phase
            ]

            # postinst gets extra preamble for services
            has_service_setup = (phase == "postinst" and self.resolved.services)

            if not commands and not has_service_setup:
                continue

            parts = ["#!/bin/bash", "set -euo pipefail", ""]

            # postinst preamble: user creation, service setup, secret placeholders
            if phase == "postinst":
                # Create declared users
                for user in self.resolved.users:
                    for cmd in user.to_commands():
                        parts.append(cmd)

                # Create service users and enable services
                for svc in self.resolved.services:
                    for cmd in svc.setup_commands():
                        parts.append(cmd)

                # Set up secret destination directories and permissions
                for secret in self.resolved.secrets:
                    if secret.dest:
                        dest_dir = str(Path(secret.dest).parent)
                        parts.append(f"mkdir -p {dest_dir}")

                parts.append(f"systemctl set-default {self.resolved.default_target}")
                parts.append("")

            # User commands/scripts for this phase
            for cmd in commands:
                if cmd.command:
                    parts.append(cmd.command)
                elif cmd.script:
                    parts.append(f"bash {cmd.script!r}")
                parts.append("")

            mkosi_file = _PHASE_TO_MKOSI[phase]
            script_path = self.output / mkosi_file
            script_path.write_text("\n".join(parts))
            script_path.chmod(0o755)

    def _write_boot_scripts(self) -> None:
        """Write on_boot() commands as a systemd oneshot service.

        Boot-time commands are NOT an mkosi phase — they run when the
        actual VM boots, not during image build.
        """
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


    def _write_secrets_delivery(self) -> None:
        """Generate the secrets delivery service and target.

        Secrets are injected post-measurement. This generates:
        1. A secrets-ready.target that services can depend on
        2. A delivery service that receives secrets via the configured channel
        3. A script that writes received secrets to their declared paths
        """
        if not self.resolved.secrets:
            return

        extra = self.output / "mkosi.extra"
        units_dir = extra / "etc" / "systemd" / "system"
        units_dir.mkdir(parents=True, exist_ok=True)

        # secrets-ready.target — other services wait for this
        target_unit = (
            "[Unit]\n"
            "Description=All secrets have been delivered\n"
            "\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n"
        )
        (units_dir / "secrets-ready.target").write_text(target_unit)

        # Generate the secrets manifest (list of expected secrets)
        scripts_dir = extra / "usr" / "local" / "lib" / "tdx"
        scripts_dir.mkdir(parents=True, exist_ok=True)

        manifest_lines: list[str] = []
        for secret in self.resolved.secrets:
            manifest_lines.append(f"{secret.name}\t{secret.dest}\t{secret.owner}\t{secret.mode}")
        (scripts_dir / "secrets.manifest").write_text("\n".join(manifest_lines) + "\n")

        # Generate the secrets receiver script
        receiver_parts = [
            "#!/bin/bash",
            "set -euo pipefail",
            "",
            "# Wait for secrets and place them at their declared paths.",
            "# Generated by tdx — do not edit.",
            "",
            'MANIFEST="/usr/local/lib/tdx/secrets.manifest"',
            "",
            "place_secret() {",
            '    local name="$1" dest="$2" owner="$3" mode="$4" value="$5"',
            '    mkdir -p "$(dirname "$dest")"',
            '    printf "%s" "$value" > "$dest"',
            '    chown "$owner" "$dest"',
            '    chmod "$mode" "$dest"',
            "}",
            "",
        ]
        (scripts_dir / "receive-secrets.sh").write_text("\n".join(receiver_parts) + "\n")
        (scripts_dir / "receive-secrets.sh").chmod(0o755)

        # Delivery service unit
        method = self.resolved.secret_delivery
        if method == "ssh":
            # SSH-based: secrets are pushed by the operator after boot
            delivery_exec = "/usr/local/lib/tdx/receive-secrets.sh --ssh"
        elif method == "vsock":
            delivery_exec = "/usr/local/lib/tdx/receive-secrets.sh --vsock"
        else:
            # Custom script
            fetch_script = self.resolved.secret_delivery_config.get("fetch_script", "")
            delivery_exec = fetch_script or "/usr/local/lib/tdx/receive-secrets.sh"

        delivery_unit = (
            "[Unit]\n"
            "Description=TDX secret delivery\n"
            "Before=secrets-ready.target\n"
            "\n"
            "[Service]\n"
            "Type=oneshot\n"
            f"ExecStart={delivery_exec}\n"
            "RemainAfterExit=yes\n"
            "\n"
            "[Install]\n"
            "WantedBy=secrets-ready.target\n"
        )
        (units_dir / "tdx-secrets.service").write_text(delivery_unit)


def _partition_type(mountpoint: str) -> str:
    """Map mountpoint to GPT partition type UUID.

    Uses well-known systemd discoverable partition type UUIDs.
    """
    types = {
        "/": "root",
        "/home": "home",
        "/srv": "srv",
        "/var": "var",
        "/tmp": "tmp",
        "swap": "swap",
        "/boot": "xbootldr",
        "/boot/efi": "esp",
    }
    return types.get(mountpoint, "linux-generic")


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
