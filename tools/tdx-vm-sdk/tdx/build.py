"""Build system for reproducible package building from source."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class BuildArtifact:
    """A package built from source to be included in the VM image.

    This is the base type. Use Build.go(), Build.rust(), etc. for
    typed builders, or Build.script() for arbitrary build systems.
    """

    name: str
    src: str
    output: str | dict[str, str]  # single path or {build_path: image_path}
    builder: str  # "go", "rust", "dotnet", "script"
    build_deps: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)

    # Builder-specific config
    config: dict[str, Any] = field(default_factory=dict)

    def to_build_script(self) -> str:
        """Generate the shell commands to build this artifact."""
        generators = {
            "go": self._go_script,
            "rust": self._rust_script,
            "dotnet": self._dotnet_script,
            "script": self._custom_script,
        }
        gen = generators.get(self.builder)
        if gen is None:
            raise ValueError(f"Unknown builder: {self.builder!r}")
        return gen()

    def _env_exports(self) -> str:
        lines = ["export SOURCE_DATE_EPOCH=0"]
        for k, v in self.env.items():
            lines.append(f"export {k}={v!r}")
        return "\n".join(lines)

    def _install_deps(self) -> str:
        if not self.build_deps:
            return ""
        pkgs = " ".join(self.build_deps)
        return f"apt-get install -y --no-install-recommends {pkgs}"

    def _go_script(self) -> str:
        go_version = self.config.get("go_version", "1.22")
        ldflags = self.config.get("ldflags", "-s -w")
        parts = [
            f"# Build: {self.name} (Go)",
            self._env_exports(),
            self._install_deps(),
            f"export GOVERSION=go{go_version}",
            f"cd {self.src!r}",
            f"go build -trimpath -ldflags {ldflags!r} -o {self.output!r} .",
        ]
        return "\n".join(p for p in parts if p)

    def _rust_script(self) -> str:
        toolchain = self.config.get("toolchain", "stable")
        features = self.config.get("features", [])
        feat_flag = f"--features {','.join(features)}" if features else ""
        parts = [
            f"# Build: {self.name} (Rust)",
            self._env_exports(),
            self._install_deps(),
            f"rustup default {toolchain}",
            f"cd {self.src!r}",
            f"cargo build --release {feat_flag}".strip(),
            f"cp target/release/{self.name} {self.output!r}",
        ]
        return "\n".join(p for p in parts if p)

    def _dotnet_script(self) -> str:
        sdk_version = self.config.get("sdk_version", "10.0")
        project = self.config.get("project", ".")
        self_contained = self.config.get("self_contained", True)
        sc_flag = "--self-contained" if self_contained else "--no-self-contained"
        parts = [
            f"# Build: {self.name} (.NET)",
            self._env_exports(),
            self._install_deps(),
            f"cd {self.src!r}",
            f"dotnet publish {project} -c Release -o {self.output!r} {sc_flag}",
        ]
        return "\n".join(p for p in parts if p)

    def _custom_script(self) -> str:
        build_script = self.config.get("build_script", "make")
        parts = [
            f"# Build: {self.name} (custom script)",
            self._env_exports(),
            self._install_deps(),
            f"cd {self.src!r}",
            build_script,
        ]
        # Handle artifact mapping for script builds
        if isinstance(self.output, dict):
            for build_path, image_path in self.output.items():
                parts.append(f"cp {build_path!r} {image_path!r}")

        return "\n".join(p for p in parts if p)


class Build:
    """Factory for creating BuildArtifact instances with typed builders."""

    @staticmethod
    def go(
        name: str,
        src: str,
        output: str,
        go_version: str = "1.22",
        ldflags: str = "-s -w",
        env: dict[str, str] | None = None,
        build_deps: list[str] | None = None,
    ) -> BuildArtifact:
        return BuildArtifact(
            name=name,
            src=src,
            output=output,
            builder="go",
            build_deps=build_deps or [],
            env=env or {},
            config={"go_version": go_version, "ldflags": ldflags},
        )

    @staticmethod
    def rust(
        name: str,
        src: str,
        output: str,
        toolchain: str = "stable",
        features: list[str] | None = None,
        env: dict[str, str] | None = None,
        build_deps: list[str] | None = None,
    ) -> BuildArtifact:
        return BuildArtifact(
            name=name,
            src=src,
            output=output,
            builder="rust",
            build_deps=build_deps or [],
            env=env or {},
            config={"toolchain": toolchain, "features": features or []},
        )

    @staticmethod
    def dotnet(
        name: str,
        src: str,
        output: str,
        sdk_version: str = "10.0",
        project: str = ".",
        self_contained: bool = True,
        env: dict[str, str] | None = None,
        build_deps: list[str] | None = None,
    ) -> BuildArtifact:
        return BuildArtifact(
            name=name,
            src=src,
            output=output,
            builder="dotnet",
            build_deps=build_deps or [],
            env=env or {},
            config={
                "sdk_version": sdk_version,
                "project": project,
                "self_contained": self_contained,
            },
        )

    @staticmethod
    def script(
        name: str,
        src: str,
        build_script: str = "make",
        artifacts: dict[str, str] | None = None,
        output: str | None = None,
        env: dict[str, str] | None = None,
        build_deps: list[str] | None = None,
    ) -> BuildArtifact:
        """Universal fallback — any build system.

        Args:
            artifacts: Mapping of {build_path: image_path} for the outputs.
            output: Single output path (alternative to artifacts for simple cases).
        """
        resolved_output: str | dict[str, str]
        if artifacts:
            resolved_output = artifacts
        elif output:
            resolved_output = output
        else:
            raise ValueError("script() requires either artifacts= or output=")

        return BuildArtifact(
            name=name,
            src=src,
            output=resolved_output,
            builder="script",
            build_deps=build_deps or [],
            env=env or {},
            config={"build_script": build_script},
        )
