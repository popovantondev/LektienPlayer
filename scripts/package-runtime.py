#!/usr/bin/env python3
"""Validate pinned local components and package them without external lookup."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def package(source, destination):
    manifest_path = Path(__file__).resolve().parent.parent / "Config/runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if destination.exists():
        raise SystemExit("Runtime destination already exists")
    for relative, expected in manifest.items():
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit("Invalid runtime path")
        item = source / path
        if not item.is_file() or item.stat().st_size != expected["size"]:
            raise SystemExit("Missing or unexpected runtime component: " + relative)
        digest = hashlib.sha256()
        with item.open("rb") as handle:
            for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected["sha256"]:
            raise SystemExit("Runtime checksum mismatch: " + relative)
    destination.mkdir(parents=True)
    for relative in manifest:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # APFS clones keep preview builds cheap; ordinary copy works on other volumes.
        result = subprocess.run(["/bin/cp", "-c", str(source / relative), str(target)], capture_output=True)
        if result.returncode:
            shutil.copy2(source / relative, target)
    shutil.copy2(manifest_path, destination / "manifest.json")


if __name__ == "__main__":
    package(Path(sys.argv[1]), Path(sys.argv[2]))
