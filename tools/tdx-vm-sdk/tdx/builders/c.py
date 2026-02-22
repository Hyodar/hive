"""C/C++ builder module.

Provides CBuild for compiling C/C++ projects, with support for
custom compilers via fetch().
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from tdx.build import BuildArtifact


@dataclass
class CBuild:
    """Build a C/C++ project.

    By default, uses the system GCC/Clang. Provide compiler_source
    (from fetch_git) to build a specific compiler version from source,
    or compiler (from fetch) to use a prebuilt compiler archive.
    """
    src: str
    build_script: str = "make"
    artifacts: dict[str, str] = field(default_factory=dict)
    output: str | None = None
    compiler: Path | None = None
    compiler_source: Path | None = None
    cc: str | None = None
    cxx: str | None = None
    cflags: str = ""
    env: dict[str, str] = field(default_factory=dict)
    build_deps: list[str] = field(default_factory=list)
    reproducible: bool = True

    def to_build_artifact(self) -> BuildArtifact:
        """Convert to a BuildArtifact for use with image.build()."""
        resolved_output: str | dict[str, str]
        if self.artifacts:
            resolved_output = self.artifacts
        elif self.output:
            resolved_output = self.output
        else:
            raise ValueError("CBuild requires either artifacts= or output=")

        if isinstance(resolved_output, dict):
            name = "c-build"
        else:
            name = Path(resolved_output).stem

        script_parts = self._compiler_setup()
        script_parts.extend(self._build_commands())
        full_script = "\n".join(script_parts)

        return BuildArtifact(
            name=name,
            src=self.src,
            output=resolved_output,
            builder="script",
            build_deps=list(self.build_deps),
            env=dict(self.env),
            config={"build_script": full_script},
        )

    def _compiler_setup(self) -> list[str]:
        """Generate commands to set up the C/C++ compiler."""
        parts: list[str] = []
        if self.compiler_source:
            parts.extend([
                "# Build compiler from source",
                f"cd {self.compiler_source}",
                "./configure --prefix=/opt/custom-gcc --disable-multilib",
                "make -j$(nproc)",
                "make install",
                "export PATH=/opt/custom-gcc/bin:$PATH",
                f"cd -",
            ])
        elif self.compiler:
            parts.extend([
                "# Install compiler from archive",
                f"tar -xf {self.compiler} -C /opt/custom-compiler",
                "export PATH=/opt/custom-compiler/bin:$PATH",
            ])
        return parts

    def _build_commands(self) -> list[str]:
        """Generate the actual C/C++ build commands."""
        parts = [""]
        if self.reproducible:
            parts.append("export SOURCE_DATE_EPOCH=0")

        if self.cc:
            parts.append(f"export CC={self.cc!r}")
        if self.cxx:
            parts.append(f"export CXX={self.cxx!r}")

        if self.cflags:
            base_flags = self.cflags
        else:
            base_flags = ""
        if self.reproducible and "-fdebug-prefix-map" not in base_flags:
            base_flags += " -fdebug-prefix-map=$PWD=."
        if base_flags.strip():
            parts.append(f"export CFLAGS={base_flags.strip()!r}")
            parts.append(f"export CXXFLAGS={base_flags.strip()!r}")

        for k, v in self.env.items():
            parts.append(f"export {k}={v!r}")

        parts.append(f"cd {self.src!r}")
        parts.append(self.build_script)

        # Copy artifacts
        if isinstance(self.artifacts, dict):
            for build_path, image_path in self.artifacts.items():
                parts.append(f"cp {build_path!r} {image_path!r}")

        return parts
