#!/usr/bin/env python3
"""Run libtiff over the planar/palette TIFF corpus and record reference evidence.

For every fixture of ``test/resources/tiff/planar-palette/manifest.json``
(plus the cross-corpus files of the strip directory), this script:

1. copies the tracked file read-only into ``<out>/inputs`` and checks its
   SHA-256 against the manifest;
2. derives an extra gate-time matrix with ``tiffcp`` and the extended
   ``tiff_oracle_encode`` into ``<out>/derived`` (every derived file is
   labelled as such);
3. runs ``tiffinfo`` and keeps its log;
4. runs ``tool/reference/tiff_oracle_dump`` (libtiff) to extract the
   native samples, RGBA conversion, and palette colormaps of every
   directory;
5. writes ``<out>/reference.json`` with every command, exit code, log
   hash, and dump hash.

Nothing here reads the Dart decoder. Usage:

    python3 tool/tiff_planar_palette_reference.py --out build/evidence/D03
"""

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

LIBTIFF_BIN = Path(os.environ.get("LIBTIFF_BIN", "/opt/homebrew/bin"))
LIBTIFF_PREFIX = Path(os.environ.get("LIBTIFF_PREFIX", "/opt/homebrew"))
DUMP_SOURCE = Path("tool/reference/tiff_oracle_dump/tiff_oracle_dump.c")
ENCODER_SOURCE = Path("tool/reference/tiff_oracle_encode/tiff_oracle_encode.c")
CORPUS_MANIFEST = Path("test/resources/tiff/planar-palette/manifest.json")
STRIP_DIR = Path("test/resources/tiff")

# Expectations for the cross-corpus strip files (the planar/palette
# manifest carries its own).
STRIP_EXPECTATIONS = {
    "palette-1c-8b.tiff": "compare",
    "minisblack-2c-8b-alpha.tiff": "reject:TiffUnsupportedCodecException",
}

# Gate-time derivations from tracked sources: (output, tool, source, args, layout).
DERIVED_MATRIX = [
    (
        "gate-planar8-lzw-t64-be.tif",
        "tiffcp",
        "planar8-none-strips.tif",
        ["-B", "-t", "-w", "64", "-l", "64", "-c", "lzw"],
        "RGB8 planar 2 LZW 64x64 BE at gate time",
    ),
    (
        "gate-planar8-packbits-strips.tif",
        "tiffcp",
        "flower-rgb-planar-08.tif",
        ["-c", "packbits"],
        "flower RGB8 planar 2 PackBits strips at gate time",
    ),
    (
        "gate-palette8-none-strips.tif",
        "tiffcp",
        "palette8-none-t16-le.tif",
        ["-c", "none"],
        "palette 8-bit none strips at gate time",
    ),
    (
        "gate-palette4-zip-t32-big.tif",
        "tiffcp",
        "flower-palette-04.tif",
        ["-8", "-t", "-w", "32", "-l", "32", "-c", "zip"],
        "palette 4-bit Deflate 32x32 BigTIFF at gate time",
    ),
    (
        "gate-jello-lzw-strips-be.tif",
        "tiffcp",
        "jello.tif",
        ["-B", "-c", "lzw"],
        "jello palette 8-bit LZW strips BE at gate time",
    ),
    (
        "gate-planar16-none-t32.tif",
        "tiff_oracle_encode",
        "planar16-none-strips.tif",
        ["--planar", "--tile", "32x32", "--compression", "zip"],
        "RGB16 planar 2 Deflate 32x32 at gate time",
    ),
    (
        "gate-palette2-o2-strips.tif",
        "tiff_oracle_encode",
        "palette2-enc-strips-be.tif",
        ["--compression", "packbits", "--orientation", "2"],
        "palette 2-bit PackBits Orientation 2 at gate time",
    ),
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(argv, log_path, cwd=None):
    started = time.monotonic()
    with open(log_path, "wb") as log:
        process = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, cwd=cwd)
    return {
        "argv": [str(a) for a in argv],
        "exitCode": process.returncode,
        "log": str(log_path),
        "logSha256": sha256(log_path),
        "durationSeconds": round(time.monotonic() - started, 3),
    }


def read_only_copy(source, target):
    if target.exists():
        target.chmod(stat.S_IWUSR | stat.S_IRUSR)
        target.unlink()
    shutil.copyfile(source, target)
    target.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)


def print_versions():
    """Record every tool the reference and comparison stages depend on."""
    dylib = (LIBTIFF_PREFIX / "lib" / "libtiff.dylib").resolve()
    tiffvers = LIBTIFF_PREFIX / "include" / "tiffvers.h"
    version_line = ""
    if tiffvers.exists():
        for line in tiffvers.read_text(errors="replace").splitlines():
            if line.startswith("#define TIFFLIB_VERSION "):
                version_line = line.strip()
    banner = subprocess.run([LIBTIFF_BIN / "tiffinfo", "-h"], capture_output=True, text=True)
    dart_text = "not found"
    for candidate in [
        os.environ.get("DART"),
        str(Path.home() / "fvm" / "versions" / "3.47.5" / "bin" / "cache" / "dart-sdk" / "bin" / "dart"),
        "dart",
    ]:
        if not candidate:
            continue
        try:
            dart = subprocess.run([candidate, "--version"], capture_output=True, text=True)
        except FileNotFoundError:
            continue
        dart_text = f"{candidate}: {(dart.stdout or dart.stderr).strip()}"
        break
    report = {
        "libtiff": {
            "banner": banner.stdout.splitlines()[0] if banner.stdout else banner.stderr.splitlines()[0],
            "tiffvers": version_line,
            "dylib": str(dylib),
            "dylibSha256": sha256(dylib) if dylib.exists() else None,
            "tiffcp": str(Path(os.path.realpath(LIBTIFF_BIN / "tiffcp"))),
            "tiffcpSha256": sha256(Path(os.path.realpath(LIBTIFF_BIN / "tiffcp"))),
            "tiffinfoSha256": sha256(Path(os.path.realpath(LIBTIFF_BIN / "tiffinfo"))),
        },
        "dumpSource": {"path": str(DUMP_SOURCE), "sha256": sha256(DUMP_SOURCE)},
        "encoderSource": {"path": str(ENCODER_SOURCE), "sha256": sha256(ENCODER_SOURCE)},
        "python": sys.version.split()[0],
        "dart": dart_text,
        "head": subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(),
    }
    print(json.dumps(report, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--skip-derived", action="store_true")
    parser.add_argument("--version", action="store_true", help="print the pinned toolchain and exit")
    args = parser.parse_args()
    if args.version:
        return print_versions()
    if args.out is None:
        parser.error("--out is required")
    out = args.out
    for name in ["version", "inputs", "derived", "tiffinfo", "dumps", "bin"]:
        (out / name).mkdir(parents=True, exist_ok=True)

    commands = []
    # 1. Versions: the libtiff actually linked, the tools, the dump source.
    tiffinfo = LIBTIFF_BIN / "tiffinfo"
    tiffcp = LIBTIFF_BIN / "tiffcp"
    commands.append(run([tiffinfo, "-h"], out / "version" / "tiffinfo.log"))
    dump_binary = out / "bin" / "tiff_oracle_dump"
    encoder_binary = out / "bin" / "tiff_oracle_encode"
    commands.append(run(
        ["cc", "-O2", "-o", dump_binary, DUMP_SOURCE, f"-I{LIBTIFF_PREFIX}/include", f"-L{LIBTIFF_PREFIX}/lib", "-ltiff"],
        out / "version" / "cc-dump.log",
    ))
    if commands[-1]["exitCode"] != 0:
        print("could not build tiff_oracle_dump", file=sys.stderr)
        return 1
    commands.append(run(
        ["cc", "-O2", "-o", encoder_binary, ENCODER_SOURCE, f"-I{LIBTIFF_PREFIX}/include", f"-L{LIBTIFF_PREFIX}/lib", "-ltiff"],
        out / "version" / "cc-encoder.log",
    ))
    if commands[-1]["exitCode"] != 0:
        print("could not build tiff_oracle_encode", file=sys.stderr)
        return 1
    commands.append(run([dump_binary, "--version"], out / "version" / "dump-version.log"))
    dylib = (LIBTIFF_PREFIX / "lib" / "libtiff.dylib").resolve()
    versions = {
        "tiffinfoBanner": (out / "version" / "tiffinfo.log").read_text(errors="replace").splitlines()[0],
        "dumpVersion": (out / "version" / "dump-version.log").read_text(errors="replace").strip(),
        "libtiffDylib": str(dylib),
        "libtiffDylibSha256": sha256(dylib) if dylib.exists() else None,
        "tiffcpSha256": sha256(Path(os.path.realpath(tiffcp))),
        "tiffinfoSha256": sha256(Path(os.path.realpath(tiffinfo))),
        "dumpSourceSha256": sha256(DUMP_SOURCE),
        "dumpBinarySha256": sha256(dump_binary),
        "encoderSourceSha256": sha256(ENCODER_SOURCE),
        "encoderBinarySha256": sha256(encoder_binary),
    }

    # 2. Tracked inputs: read-only copies with verified hashes.
    cases = []
    manifest = json.loads(CORPUS_MANIFEST.read_text())
    tracked = []
    for entry in manifest["files"]:
        tracked.append((
            Path("test/resources/tiff/planar-palette") / entry["name"],
            entry["sha256"],
            entry["expectation"],
            entry.get("layout", ""),
            entry.get("producer", ""),
        ))
    for name, expectation in STRIP_EXPECTATIONS.items():
        tracked.append((STRIP_DIR / name, None, expectation, "strip-corpus file", "tracked"))
    failures = 0
    for source, expected_sha, expectation, layout, producer in tracked:
        if not source.is_file():
            print(f"missing tracked fixture {source}", file=sys.stderr)
            failures += 1
            continue
        target = out / "inputs" / source.name
        read_only_copy(source, target)
        digest = sha256(target)
        if expected_sha is not None and digest != expected_sha:
            print(f"hash mismatch for {source}", file=sys.stderr)
            failures += 1
            continue
        cases.append({
            "id": f"planar-palette/{source.name}",
            "group": "planar-palette",
            "name": source.name,
            "path": str(target),
            "sha256": digest,
            "trackedPath": str(source),
            "expectation": expectation,
            "layout": layout,
            "producer": producer,
        })

    # 3. Gate-time derivations, labelled as such.
    if not args.skip_derived:
        for name, tool, source, extra, layout in DERIVED_MATRIX:
            target = out / "derived" / name
            if tool == "tiffcp":
                argv = [tiffcp, *extra, out / "inputs" / source, target]
            else:
                argv = [encoder_binary, out / "inputs" / source, target, *extra]
            record = run(argv, out / "derived" / f"{name}.run.log")
            commands.append(record)
            if record["exitCode"] != 0:
                failures += 1
                continue
            cases.append({
                "id": f"derived/{name}",
                "group": "derived",
                "name": name,
                "path": str(target),
                "sha256": sha256(target),
                "expectation": "compare" if "16" not in name.split("-")[1] else "compare-native",
                "layout": layout,
                "producer": f"{tool} (libtiff 4.7.2) at gate time from {source}",
                "derivation": record,
            })

    # 4 and 5. tiffinfo and pixel dumps for every case.
    for case in cases:
        info = run([tiffinfo, case["path"]], out / "tiffinfo" / f"{case['name']}.log")
        case["tiffinfo"] = info
        prefix = out / "dumps" / case["name"]
        dump = run([dump_binary, case["path"], prefix], out / "dumps" / f"{case['name']}.run.log")
        case["dump"] = dump
        dump_json = Path(f"{prefix}.json")
        if dump["exitCode"] == 0 and dump_json.is_file():
            data = json.loads(dump_json.read_text())
            directories = []
            for directory in data["directories"]:
                record = dict(directory)
                for key in ["nativeFile", "rgbaFile", "colormapFile"]:
                    value = directory.get(key)
                    record[key + "Sha256"] = sha256(Path(value)) if value else None
                directories.append(record)
            case["reference"] = {
                "json": str(dump_json),
                "jsonSha256": sha256(dump_json),
                "libtiff": data.get("libtiff"),
                "openStatus": data.get("openStatus"),
                "directories": directories,
            }
        else:
            case["reference"] = None
            failures += 1

    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    report = {
        "schemaVersion": 1,
        "mission": "D03",
        "head": head,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "libtiff": versions,
        "commands": commands,
        "cases": cases,
        "totals": {
            "cases": len(cases),
            "corpus": sum(1 for c in cases if c["group"] == "planar-palette"),
            "derived": sum(1 for c in cases if c["group"] == "derived"),
            "failures": failures,
        },
    }
    (out / "reference.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["totals"]))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
