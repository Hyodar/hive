"""Rust builder module.

Provides RustBuild for compiling Rust projects, with flexible compiler
sourcing: official rustup toolchain (default), custom tarball via fetch(),
or system-installed rustc.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from tdx.build import BuildArtifact


@dataclass
class RustBuild:
    """Build a Rust project.

    Supports multiple compiler sourcing strategies:
    - toolchain="1.83.0": Install via rustup (default)
    - compiler=fetch(...): Use a specific toolchain tarball
    - Neither: Use whatever rustc is already available

    Reproducibility flags are set by default (SOURCE_DATE_EPOCH,
    --remap-path-prefix).
    """
    src: str
    output: str
    toolchain: str | None = None
    compiler: Path | None = None
    features: list[str] = field(default_factory=list)
    no_default_features: bool = False
    target: str | None = None
    env: dict[str, str] = field(default_factory=dict)
    build_deps: list[str] = field(default_factory=list)
    reproducible: bool = True

    def to_build_artifact(self) -> BuildArtifact:
        """Convert to a BuildArtifact for use with image.build()."""
        name = Path(self.output).stem

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
        """Generate commands to set up the Rust compiler."""
        if isinstance(self.compiler, Path):
            return [
                "# Install Rust from provided tarball",
                f"tar -xf {self.compiler} -C /tmp/rust-install",
                "/tmp/rust-install/*/install.sh --prefix=/usr/local",
                "rm -rf /tmp/rust-install",
            ]
        elif self.toolchain:
            return [
                f"# Install Rust toolchain {self.toolchain}",
                f"rustup default {self.toolchain}",
            ]
        return []

    def _build_commands(self) -> list[str]:
        """Generate the actual Rust build commands."""
        parts = [""]
        if self.reproducible:
            parts.append("export SOURCE_DATE_EPOCH=0")
            parts.append("export RUSTFLAGS='--remap-path-prefix=$PWD=.'")

        for k, v in self.env.items():
            parts.append(f"export {k}={v!r}")

        parts.append(f"cd {self.src!r}")

        build_cmd = "cargo build --release"
        if self.features:
            build_cmd += f" --features {','.join(self.features)}"
        if self.no_default_features:
            build_cmd += " --no-default-features"
        if self.target:
            build_cmd += f" --target {self.target}"

        parts.append(build_cmd)

        # Copy the binary to the output path
        binary_name = Path(self.output).name
        if self.target:
            parts.append(f"cp target/{self.target}/release/{binary_name} {self.output!r}")
        else:
            parts.append(f"cp target/release/{binary_name} {self.output!r}")

        return parts
