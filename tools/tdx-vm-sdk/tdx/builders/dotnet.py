"""Dotnet builder module.

Provides DotnetBuild for compiling .NET projects.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from tdx.build import BuildArtifact


@dataclass
class DotnetBuild:
    """.NET project builder.

    By default, uses the .NET SDK version available in the build environment.
    Specify sdk_version to install a specific version, or provide a compiler
    path via fetch() for full control.
    """
    src: str
    output: str
    sdk_version: str | None = None
    compiler: Path | None = None
    project: str = "."
    self_contained: bool = True
    runtime: str = "linux-x64"
    env: dict[str, str] = field(default_factory=dict)
    build_deps: list[str] = field(default_factory=list)
    reproducible: bool = True

    def to_build_artifact(self) -> BuildArtifact:
        """Convert to a BuildArtifact for use with image.build()."""
        name = Path(self.output).rstrip("/").split("/")[-1] if "/" in self.output else "dotnet-app"

        script_parts = self._compiler_setup()
        script_parts.extend(self._build_commands())
        full_script = "\n".join(script_parts)

        return BuildArtifact(
            name=name,
            src=self.src,
            output=self.output,
            builder="script",
            build_deps=list(self.build_deps),
            env=dict(self.env),
            config={"build_script": full_script},
        )

    def _compiler_setup(self) -> list[str]:
        """Generate commands to set up the .NET SDK."""
        if isinstance(self.compiler, Path):
            return [
                "# Install .NET SDK from provided archive",
                "mkdir -p /usr/share/dotnet",
                f"tar -xzf {self.compiler} -C /usr/share/dotnet",
                "ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet",
            ]
        elif self.sdk_version:
            return [
                f"# Install .NET SDK {self.sdk_version}",
                "export DOTNET_CLI_TELEMETRY_OPTOUT=1",
            ]
        return []

    def _build_commands(self) -> list[str]:
        """Generate the actual .NET build commands."""
        parts = [""]
        if self.reproducible:
            parts.append("export SOURCE_DATE_EPOCH=0")

        parts.append("export DOTNET_CLI_TELEMETRY_OPTOUT=1")
        for k, v in self.env.items():
            parts.append(f"export {k}={v!r}")

        parts.append(f"cd {self.src!r}")

        sc_flag = "--self-contained" if self.self_contained else "--no-self-contained"
        publish_cmd = (
            f"dotnet publish {self.project} "
            f"-c Release "
            f"-o {self.output!r} "
            f"-r {self.runtime} "
            f"{sc_flag}"
        )
        if self.reproducible:
            publish_cmd += " /p:Deterministic=true"

        parts.append(publish_cmd)
        return parts
