"""Helper utilities for TDXfile evaluation."""

from __future__ import annotations

import os


def env(name: str, default: str | None = None) -> str:
    """Read a value from the environment.

    Use in TDXfiles to pull config from the build environment:

        image.template(
            src="./config.j2",
            dest="/etc/app/config.json",
            vars={"contract": env("CONTRACT_ADDRESS")},
        )
    """
    val = os.environ.get(name)
    if val is None and default is None:
        raise ValueError(
            f"Environment variable {name!r} is not set and no default was provided. "
            f"Set it before running 'tdx build' or provide a default: env({name!r}, default='...')"
        )
    return val if val is not None else default  # type: ignore[return-value]
