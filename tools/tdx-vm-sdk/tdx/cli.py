"""CLI entry point for the TDX VM SDK."""

from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from tdx.compile import MkosiCompiler
from tdx.image import Image


def load_tdxfile(path: str) -> Image:
    """Load and evaluate a TDXfile, returning the Image object."""
    path = os.path.abspath(path)
    if not os.path.exists(path):
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)

    # Load the TDXfile as a Python module
    spec = importlib.util.spec_from_file_location("tdxfile", path)
    if spec is None or spec.loader is None:
        print(f"Error: could not load {path}", file=sys.stderr)
        sys.exit(1)

    module = importlib.util.module_from_spec(spec)

    # Make tdx imports available
    sys.modules["tdxfile"] = module
    spec.loader.exec_module(module)

    # Find the Image object in the module
    images = [v for v in vars(module).values() if isinstance(v, Image)]
    if not images:
        print(f"Error: no Image object found in {path}", file=sys.stderr)
        sys.exit(1)

    if len(images) > 1:
        print(
            f"Warning: multiple Image objects in {path}, using the first one",
            file=sys.stderr,
        )

    return images[0]


def cmd_build(args: argparse.Namespace) -> None:
    """Build a TDX VM image from a TDXfile."""
    image = load_tdxfile(args.tdxfile)
    resolved = image.resolve(profile=args.profile)

    # Determine output directory
    if args.emit_mkosi:
        out_dir = args.emit_mkosi
    else:
        out_dir = tempfile.mkdtemp(prefix=f"tdx-{image.name}-")

    compiler = MkosiCompiler(resolved, out_dir)
    compiler.compile()

    if args.emit_mkosi:
        print(f"mkosi configs written to: {out_dir}")
        return

    # Apply mkosi overrides if provided
    if args.mkosi_override:
        override_dir = Path(args.mkosi_override)
        if (override_dir / "mkosi.conf").exists():
            # Append override conf
            with open(Path(out_dir) / "mkosi.conf", "a") as f:
                f.write("\n# --- User overrides ---\n")
                f.write((override_dir / "mkosi.conf").read_text())

    # Run mkosi
    print(f"Building image '{resolved.name}' ...")
    result = subprocess.run(
        ["mkosi", "--directory", out_dir, "build"],
        cwd=out_dir,
    )
    if result.returncode != 0:
        print("Build failed.", file=sys.stderr)
        sys.exit(1)

    print(f"Image built successfully.")


def cmd_measure(args: argparse.Namespace) -> None:
    """Compute expected measurements for a TDX VM image."""
    image = load_tdxfile(args.tdxfile)
    resolved = image.resolve(profile=args.profile)
    print(f"Measurements for '{resolved.name}':")
    print("  (measurement computation not yet implemented)")
    # TODO: invoke measurement tooling


def cmd_inspect(args: argparse.Namespace) -> None:
    """Show the resolved configuration without building."""
    image = load_tdxfile(args.tdxfile)
    resolved = image.resolve(profile=args.profile)

    print(f"Image: {resolved.name}")
    print(f"Base: {resolved.base}")
    print(f"Kernel: {resolved.kernel.version}")
    print(f"Init: {resolved.init}")
    print(f"Target: {resolved.default_target}")
    print(f"Firmware: {resolved.firmware}")
    print(f"Packages: {resolved.packages}")
    print(f"Builds: {[b.name for b in resolved.builds]}")
    print(f"Services: {[s.name for s in resolved.services]}")
    print(f"Files: {[f.dest for f in resolved.files]}")
    print(f"Templates: {[t.dest for t in resolved.templates]}")
    print(f"Run commands: {len(resolved.run_commands)} ({sum(1 for c in resolved.run_commands if c.phase == 'build')} build, {sum(1 for c in resolved.run_commands if c.phase == 'boot')} boot)")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="tdx",
        description="TDX VM SDK — build reproducible, measured TDX virtual machine images",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # tdx build
    build_p = sub.add_parser("build", help="Build a TDX VM image")
    build_p.add_argument("tdxfile", help="Path to the TDXfile")
    build_p.add_argument("--profile", help="Build with a named profile")
    build_p.add_argument("--emit-mkosi", help="Write generated mkosi configs to this directory (don't build)")
    build_p.add_argument("--mkosi-override", help="Layer a custom mkosi.conf on top of generated config")
    build_p.set_defaults(func=cmd_build)

    # tdx measure
    measure_p = sub.add_parser("measure", help="Compute expected measurements")
    measure_p.add_argument("tdxfile", help="Path to the TDXfile")
    measure_p.add_argument("--profile", help="Measure with a named profile")
    measure_p.set_defaults(func=cmd_measure)

    # tdx inspect
    inspect_p = sub.add_parser("inspect", help="Show resolved configuration")
    inspect_p.add_argument("tdxfile", help="Path to the TDXfile")
    inspect_p.add_argument("--profile", help="Inspect with a named profile")
    inspect_p.set_defaults(func=cmd_inspect)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
