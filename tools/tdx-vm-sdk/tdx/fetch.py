"""Verified resource fetching for reproducible builds.

Every external resource (compiler tarball, firmware binary, source archive)
is downloaded through fetch() with a mandatory content hash. This ensures
builds are reproducible and resistant to supply-chain attacks.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlparse


def _cache_dir() -> Path:
    """Return the fetch cache directory."""
    base = Path(os.environ.get("TDX_CACHE_DIR", Path.home() / ".cache" / "tdx"))
    d = base / "fetch"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _git_cache_dir() -> Path:
    """Return the git bare repo cache directory."""
    base = Path(os.environ.get("TDX_CACHE_DIR", Path.home() / ".cache" / "tdx"))
    d = base / "git"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _sha256_file(path: Path) -> str:
    """Compute sha256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _dirhash(directory: Path) -> str:
    """Compute a content hash of a directory tree.

    Algorithm:
        1. List all files (respecting .gitignore if in a git repo)
        2. Sort filenames lexicographically
        3. For each file: sha256(relative_path + "\\0" + file_contents)
        4. sha256 the concatenation of all per-file hashes

    This produces a stable hash over directory contents, independent of
    file metadata (timestamps, permissions) or git history.
    """
    files: list[str] = []
    for root, _dirs, filenames in os.walk(directory):
        for fname in filenames:
            full = Path(root) / fname
            rel = full.relative_to(directory)
            # Skip hidden VCS directories
            parts = rel.parts
            if any(p.startswith(".git") for p in parts):
                continue
            files.append(str(rel))

    files.sort()

    outer = hashlib.sha256()
    for relpath in files:
        full = directory / relpath
        content = full.read_bytes()
        inner = hashlib.sha256()
        inner.update(relpath.encode("utf-8"))
        inner.update(b"\0")
        inner.update(content)
        outer.update(inner.digest())

    return outer.hexdigest()


def fetch(url: str, sha256: str) -> Path:
    """Download a resource and verify its content hash.

    Returns the path to the cached file. If the file is already cached
    and matches the expected hash, no download occurs.

    Args:
        url: The URL to download from.
        sha256: Expected SHA-256 hex digest of the file contents.

    Returns:
        Path to the verified cached file.

    Raises:
        ValueError: If the downloaded content doesn't match the expected hash.
    """
    cache = _cache_dir()
    cached = cache / sha256
    if cached.exists():
        # Verify cached file still matches (guards against cache corruption)
        actual = _sha256_file(cached)
        if actual == sha256:
            return cached
        # Cache corrupted — re-download
        cached.unlink()

    # Download to a temp file, verify, then move to cache
    with tempfile.NamedTemporaryFile(dir=cache, delete=False, suffix=".download") as tmp:
        tmp_path = Path(tmp.name)

    try:
        subprocess.run(
            ["curl", "-fsSL", "-o", str(tmp_path), url],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        tmp_path.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to download {url}: {e.stderr.decode()}") from e

    actual = _sha256_file(tmp_path)
    if actual != sha256:
        tmp_path.unlink(missing_ok=True)
        raise ValueError(
            f"Hash mismatch for {url}\n"
            f"  Expected: sha256:{sha256}\n"
            f"  Got:      sha256:{actual}\n"
            f"\n"
            f"The remote content has changed. Verify the new content and update the hash."
        )

    tmp_path.rename(cached)
    return cached


def fetch_git(
    url: str,
    *,
    tag: str | None = None,
    branch: str | None = None,
    rev: str | None = None,
    sha256: str,
) -> Path:
    """Fetch a git repository at a specific ref and verify its content hash.

    The hash covers the file tree contents (not git metadata), so the same
    source tree produces the same hash regardless of git history.

    Args:
        url: Git repository URL.
        tag: Git tag to checkout.
        branch: Git branch to checkout (resolved to HEAD at fetch time).
        rev: Exact commit SHA.
        sha256: Expected SHA-256 content hash (dirhash of the tree).

    Returns:
        Path to the checked-out directory.

    Raises:
        ValueError: If no ref is specified, or if the content hash doesn't match.
    """
    ref = rev or tag or branch
    if ref is None:
        raise ValueError("fetch_git() requires tag=, branch=, or rev=")

    # Determine the cache key from the resolved commit
    git_cache = _git_cache_dir()
    parsed = urlparse(url)
    repo_name = parsed.path.strip("/").replace("/", "-").replace(".git", "")
    bare_repo = git_cache / f"{parsed.hostname}-{repo_name}.git"

    # Clone or fetch into bare repo
    if not bare_repo.exists():
        subprocess.run(
            ["git", "clone", "--bare", url, str(bare_repo)],
            check=True,
            capture_output=True,
        )
    else:
        subprocess.run(
            ["git", "-C", str(bare_repo), "fetch", "--force", "--tags", url, "+refs/heads/*:refs/heads/*"],
            check=True,
            capture_output=True,
        )

    # Resolve ref to commit SHA
    try:
        result = subprocess.run(
            ["git", "-C", str(bare_repo), "rev-parse", ref],
            check=True,
            capture_output=True,
            text=True,
        )
        resolved_rev = result.stdout.strip()
    except subprocess.CalledProcessError:
        raise ValueError(f"Could not resolve ref {ref!r} in {url}")

    # Check if we already have this checkout cached
    checkout_cache = _cache_dir() / "git-trees" / sha256
    if checkout_cache.exists():
        actual = _dirhash(checkout_cache)
        if actual == sha256:
            return checkout_cache

    # Checkout into a temp directory, verify, then move
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp) / "src"
        subprocess.run(
            ["git", "clone", "--depth=1", str(bare_repo), str(tmp_path)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(tmp_path), "checkout", resolved_rev],
            check=True,
            capture_output=True,
        )

        actual = _dirhash(tmp_path)
        if actual != sha256:
            raise ValueError(
                f"Hash mismatch for {url} at {ref}\n"
                f"  Expected: sha256:{sha256}\n"
                f"  Got:      sha256:{actual}\n"
                f"\n"
                f"The source tree contents have changed. Verify and update the hash."
            )

        checkout_cache.parent.mkdir(parents=True, exist_ok=True)
        tmp_path.rename(checkout_cache)

    return checkout_cache


def hash_of(path_or_url: str) -> str:
    """Compute the SHA-256 hash of a file or URL.

    Convenience function for discovering the expected hash of a resource
    before adding it to a fetch() call.

    Args:
        path_or_url: Local file path or URL.

    Returns:
        Hash string in "sha256:<hex>" format.
    """
    p = Path(path_or_url)
    if p.exists():
        return f"sha256:{_sha256_file(p)}"

    # It's a URL — download to a temp file and hash
    with tempfile.NamedTemporaryFile(delete=False, suffix=".hash") as tmp:
        tmp_path = Path(tmp.name)

    try:
        subprocess.run(
            ["curl", "-fsSL", "-o", str(tmp_path), path_or_url],
            check=True,
            capture_output=True,
        )
        result = f"sha256:{_sha256_file(tmp_path)}"
    finally:
        tmp_path.unlink(missing_ok=True)

    return result


def hash_dir(directory: str) -> str:
    """Compute the content hash of a directory tree.

    Args:
        directory: Path to the directory.

    Returns:
        Hash string in "sha256:<hex>" format.
    """
    return f"sha256:{_dirhash(Path(directory))}"
