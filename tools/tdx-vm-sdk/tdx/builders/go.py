"""Go builder module.

Provides GoBuild for compiling Go projects, with flexible compiler
sourcing: precompiled official release (default), custom tarball via
fetch(), or build-from-source via GoFromSource.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from tdx.build import BuildArtifact


# Official Go release URL template
_GO_RELEASE_URL = "https://go.dev/dl/go{version}.linux-amd64.tar.gz"


@dataclass
class GoFromSource:
    """Build Go from source using a bootstrap compiler.

    This compiles the Go toolchain from the official source tree, using
    an older Go version as the bootstrap compiler. Use this when you need
    full auditability of the compiler binary.
    """
    version: str
    bootstrap_version: str = "1.21.0"
    source_url: str | None = None
    bootstrap_url: str | None = None
    source_sha256: str | None = None
    bootstrap_sha256: str | None = None

    def to_build_commands(self) -> list[str]:
        """Generate shell commands to build Go from source."""
        src_url = self.source_url or _GO_RELEASE_URL.format(version=self.version)
        boot_url = self.bootstrap_url or _GO_RELEASE_URL.format(version=self.bootstrap_version)

        commands = [
            f"# Build Go {self.version} from source",
            f"# Bootstrap with Go {self.bootstrap_version}",
            "",
            "export GOROOT_BOOTSTRAP=/tmp/go-bootstrap",
            "mkdir -p /tmp/go-bootstrap",
            f"curl -fsSL '{boot_url}' | tar -C /tmp/go-bootstrap --strip-components=1 -xz",
            "",
            "mkdir -p /tmp/go-source",
            f"curl -fsSL '{src_url}' | tar -C /tmp/go-source --strip-components=1 -xz",
            "cd /tmp/go-source/src",
            "GOROOT=/tmp/go-source ./make.bash",
            "",
            "# Install built Go",
            "rm -rf /usr/local/go",
            "mv /tmp/go-source /usr/local/go",
            "ln -sf /usr/local/go/bin/go /usr/local/bin/go",
            "",
            "# Cleanup bootstrap",
            "rm -rf /tmp/go-bootstrap",
        ]
        return commands


@dataclass
class GoBuild:
    """Build a Go project.

    Supports three compiler sourcing strategies:
    - version="1.22.5": Download precompiled official release (default)
    - compiler=fetch(...): Use a specific tarball
    - compiler=GoFromSource(...): Build Go from source

    Reproducibility flags are set by default (SOURCE_DATE_EPOCH, -trimpath).
    """
    src: str
    output: str
    version: str | None = None
    compiler: Path | GoFromSource | None = None
    ldflags: str = "-s -w"
    tags: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    build_deps: list[str] = field(default_factory=list)
    reproducible: bool = True

    def to_build_artifact(self) -> BuildArtifact:
        """Convert to a BuildArtifact for use with image.build()."""
        name = Path(self.output).stem

        # Build the full script including compiler setup
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
        """Generate commands to set up the Go compiler."""
        if isinstance(self.compiler, GoFromSource):
            return self.compiler.to_build_commands()
        elif isinstance(self.compiler, Path):
            return [
                "# Install Go from provided tarball",
                f"tar -C /usr/local -xzf {self.compiler}",
                "export PATH=/usr/local/go/bin:$PATH",
            ]
        elif self.version:
            url = _GO_RELEASE_URL.format(version=self.version)
            return [
                f"# Install Go {self.version} (precompiled)",
                f"curl -fsSL '{url}' | tar -C /usr/local -xz",
                "export PATH=/usr/local/go/bin:$PATH",
            ]
        else:
            # Assume Go is already available (e.g., from a compiler module)
            return []

    def _build_commands(self) -> list[str]:
        """Generate the actual Go build commands."""
        parts = [""]
        if self.reproducible:
            parts.append("export SOURCE_DATE_EPOCH=0")

        for k, v in self.env.items():
            parts.append(f"export {k}={v!r}")

        parts.append(f"cd {self.src!r}")

        build_cmd = "go build -trimpath" if self.reproducible else "go build"
        if self.ldflags:
            build_cmd += f" -ldflags {self.ldflags!r}"
        if self.tags:
            build_cmd += f" -tags {','.join(self.tags)}"
        build_cmd += f" -o {self.output!r} ."

        parts.append(build_cmd)
        return parts
