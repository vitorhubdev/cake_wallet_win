#!/usr/bin/env python3
"""Prepare the upstream, checksum-pinned dependencies for a Windows build.

No Cake production API credentials or wallet data are required. Downloads are
GET-only, bounded, verified before extraction, and cached by their SHA-256.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "scripts/.cache/windows"
DEPENDENCIES = {
    "torch_dart": (
        "https://github.com/MrCyjaneK/torch_dart/releases/download/v1.0.17/torch_dart-v1.0.17.tar.gz",
        "d7ad0dbb63e1dee16a1d28f375d9e570ab82d77999a0e070111b694c7c8c371e",
    ),
    "reown_flutter": (
        "https://github.com/cake-tech/reown_flutter/releases/download/v0.0.4/reown_flutter-v0.0.4.tar.gz",
        "d6e907924124d81c6e71647255b42da5693dcfa2ccf0c2553761e648171601c0",
    ),
}
BITBOX_COMMIT = "5a6e6dd388ef64003f86094af80d5453518b601d"
MONERO_COMMIT = "33671871de3d51696b66ffb3bd94f744e26974f6"


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def download(url: str, digest: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    destination = CACHE / digest
    if destination.exists() and sha256(destination) == digest:
        return destination
    partial = destination.with_suffix(".partial")
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "cake-wallet-windows-build"})
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output)
            actual = sha256(partial)
            if actual != digest:
                raise ValueError(f"SHA-256 mismatch for {url}: {actual}")
            partial.replace(destination)
            return destination
        except (OSError, TimeoutError):
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def extract_sources(archive: Path, destination: Path) -> None:
    # Do not unpack example projects, absolute build symlinks, caches or git
    # credentials that may be present in an upstream development archive.
    excluded = {".git", ".dart_tool", "example", "examples", "build", "ephemeral", ".symlinks"}
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as source:
        for entry in source:
            relative = PurePosixPath(entry.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(f"Unsafe archive member: {entry.name}")
            if excluded.intersection(relative.parts) or not entry.isfile():
                continue
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(entry) as content, target.open("wb") as output:
                shutil.copyfileobj(content, output)


def verify_monero() -> dict:
    # The last upstream DLL release predates this Dart wrapper and is rejected
    # by the application's implementation checksum gate. Build the exact pin.
    overrides_text = (ROOT / "pubspec_overrides.yaml").read_text(encoding="utf-8")
    monero_pin = re.search(
        r"(?m)^  monero:\n    git:\n      url: [^\n]+\n      ref: ([0-9a-f]{40})$",
        overrides_text,
    )
    if monero_pin is None or monero_pin.group(1) != MONERO_COMMIT:
        raise ValueError("Update the native Monero build when changing the Dart wrapper pin")
    monero_dir = ROOT / "build/windows-native/monero"
    monero_metadata = json.loads((monero_dir / "native-build-info.json").read_text(encoding="utf-8"))
    if monero_metadata.get("commit") != MONERO_COMMIT or monero_metadata.get("target") != "x86_64-w64-mingw32":
        raise ValueError("The native Monero artifact does not match the pinned Windows build")
    files = monero_metadata.get("files", {})
    if not {"libmonero_wallet2_api_c.dll", "libwinpthread-1.dll"}.issubset(files):
        raise ValueError("The native Monero artifact is incomplete")
    if set(files) != {path.name for path in monero_dir.glob("*.dll")}:
        raise ValueError("The Monero artifact contains unrecorded or missing DLLs")
    for name, digest in files.items():
        if Path(name).name != name or not name.endswith(".dll") or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid Monero artifact manifest entry")
        if sha256(monero_dir / name) != digest:
            raise ValueError(f"Native Monero artifact checksum mismatch: {name}")
    print(f"Verified source-built Monero at {MONERO_COMMIT}", flush=True)
    return monero_metadata


def main(*, sources_only: bool = False) -> None:
    # CI prepares Dart packages while the independent native job is compiling.
    # build.ps1 always verifies the completed artifact again before compilation.
    metadata = {} if sources_only else {"monero_c": verify_monero()}
    for name, (url, digest) in DEPENDENCIES.items():
        print(f"Preparing {name} (SHA-256 {digest})", flush=True)
        archive = download(url, digest)
        metadata[name] = {"url": url, "sha256": digest}
        extract_sources(archive, ROOT / "scripts" / name)

    bitbox = ROOT / "scripts/bitbox_flutter"
    if not (bitbox / ".git").exists():
        subprocess.run(["git", "clone", "--no-checkout", "https://github.com/konstantinullrich/bitbox_flutter", str(bitbox)], check=True, timeout=300)
    subprocess.run(["git", "-C", str(bitbox), "fetch", "origin", BITBOX_COMMIT], check=True, timeout=300)
    subprocess.run(["git", "-C", str(bitbox), "checkout", "--detach", BITBOX_COMMIT], check=True, timeout=120)
    metadata["bitbox_flutter"] = {"repository": "https://github.com/konstantinullrich/bitbox_flutter", "commit": BITBOX_COMMIT}

    # Git checkout on Windows can materialize symlinks as tiny text files.
    # All cw packages must see the same upstream dependency pins.
    overrides = (ROOT / "pubspec_overrides.yaml").read_bytes()
    for package in ROOT.glob("cw_*"):
        if (package / "pubspec.yaml").exists():
            target = package / "pubspec_overrides.yaml"
            target.unlink(missing_ok=True)
            target.write_bytes(overrides)

    native = ROOT / "build/windows-native/mweb"
    pthread = native / "libwinpthread-1.dll"
    if not (native / "mweb.dll").is_file() or not pthread.is_file():
        raise FileNotFoundError("Build/download the windows-native artifact before preparing dependencies")
    (native.parent / "dependency-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--sources-only", action="store_true", help="Prepare package sources while the native Monero job runs")
    modes.add_argument("--verify-monero", action="store_true", help="Verify the native artifact and record it in the dependency manifest")
    args = parser.parse_args()
    if args.verify_monero:
        native_metadata = verify_monero()
        manifest = ROOT / "build/windows-native/dependency-manifest.json"
        metadata = json.loads(manifest.read_text(encoding="utf-8"))
        metadata["monero_c"] = native_metadata
        manifest.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    else:
        main(sources_only=args.sources_only)
