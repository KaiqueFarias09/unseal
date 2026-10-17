#!/usr/bin/env python3
"""Independent ZIP inventory for the B02 byte-range mission.

Walks real book containers with Python's standard-library ``zipfile``
(no Unseal code involved) and writes a JSON inventory: container hash,
per-entry path, compressed/uncompressed sizes, CRC-32, compression
method, local-header offset, and the SHA-256 of every entry's inflated
content. The offset/sizes also define the byte span a partial reader is
allowed to touch for each entry, which the comparison stage checks
against the recorded range log.

Usage:

    python3 tool/zip_reference_inventory.py --output <path.json> FIXTURE...

Reads fixtures only; the output path must sit under build/.
"""

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(fixture: Path) -> dict:
    with zipfile.ZipFile(fixture) as archive:
        infos = archive.infolist()
        entries = []
        for info in infos:
            entry = {
                "path": info.filename,
                "isFile": not info.is_dir(),
                "compressionMethod": info.compress_type,
                "crc32": info.CRC,
                "compressedSize": info.compress_size,
                "uncompressedSize": info.file_size,
                "localHeaderOffset": info.header_offset,
            }
            if not info.is_dir():
                content = archive.read(info)
                entry["sha256"] = hashlib.sha256(content).hexdigest()
                entry["contentBytes"] = len(content)
                if len(content) != info.file_size or (zipfile.crc32(content) & 0xFFFFFFFF) != info.CRC:
                    raise SystemExit(f"{fixture}: entry {info.filename} failed its declared CRC/size")
            entries.append(entry)
        # Span a partial reader may touch when serving one entry: the
        # local header plus its compressed payload.
        for entry in entries:
            if entry["isFile"]:
                entry["allowedSpanStart"] = entry["localHeaderOffset"]
                entry["allowedSpanEnd"] = entry["localHeaderOffset"] + 30 + entry["compressedSize"]
        return {
            "fixture": str(fixture),
            "sha256": sha256_file(fixture),
            "bytes": fixture.stat().st_size,
            "entryCount": len(infos),
            "entries": entries,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("fixtures", nargs="+", type=Path)
    arguments = parser.parse_args()

    output = arguments.output.resolve()
    if not output.is_relative_to(Path.cwd().resolve() / "build"):
        raise SystemExit("output must stay under build/")

    inventories = [inventory(fixture.resolve()) for fixture in arguments.fixtures]
    payload = {
        "schemaVersion": 1,
        "tool": "python3 zipfile",
        "pythonVersion": sys.version.split()[0],
        "containers": inventories,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {output} ({output.stat().st_size} bytes, {len(inventories)} containers)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
