#!/usr/bin/env python3
"""Prepare the upstream, checksum-pinned dependencies for a Windows build.

No Cake production API credentials or wallet data are required. Downloads are
GET-only, bounded, verified before extraction, and cached by their SHA-256.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "scripts/.cache/windows"
DEPENDENCIES = {
    "monero": (
        "https://github.com/MrCyjaneK/monero_c/releases/download/v0.18.4.6-RC2/release-bundle.zip",
        "94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70",
    ),
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


def main() -> None:
    metadata = {}
    for name, (url, digest) in DEPENDENCIES.items():
        print(f"Preparing {name} (SHA-256 {digest})", flush=True)
        archive = download(url, digest)
        metadata[name] = {"url": url, "sha256": digest}
        if name == "monero":
            with zipfile.ZipFile(archive) as source:
                for coin in ("monero", "wownero"):
                    member = f"v0.18.4.6-RC2/x86_64-w64-mingw32/lib{coin}_wallet2_api_c.dll"
                    output = ROOT / f"scripts/monero_c/release/{coin}/x86_64-w64-mingw32_libwallet2_api_c.dll"
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with source.open(member) as content, output.open("wb") as handle:
                        shutil.copyfileobj(content, handle)
        else:
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
    shutil.copy2(pthread, ROOT / "scripts/monero_c/release/monero/x86_64-w64-mingw32_libwinpthread-1.dll")
    (native.parent / "dependency-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
