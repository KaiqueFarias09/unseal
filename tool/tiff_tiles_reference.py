#!/usr/bin/env python3
"""Run libtiff over the tiled TIFF corpus and record the reference evidence.

For every fixture of ``test/resources/tiff/tiled/manifest.json`` (plus the
strip corpus of ``test/resources/tiff``), this script:

1. copies the tracked file read-only into ``<out>/inputs`` and checks its
   SHA-256 against the manifest;
2. derives an extra matrix with ``tiffcp`` into ``<out>/derived`` (every
   derived file is labelled as such);
3. runs ``tiffinfo`` and keeps its log;
4. runs ``tool/reference/tiff_oracle_dump`` (libtiff) to extract the native
   samples and the RGBA conversion of every directory;
5. writes ``<out>/reference.json`` with every command, exit code, log hash,
   and dump hash.

Nothing here reads the Dart decoder. Usage:

    python3 tool/tiff_tiles_reference.py --out build/evidence/C03
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
TILED_MANIFEST = Path("test/resources/tiff/tiled/manifest.json")
STRIP_DIR = Path("test/resources/tiff")

# Expectations for the pre-existing strip corpus (the tiled manifest carries
# its own). Files absent here are not part of the comparison.
STRIP_EXPECTATIONS = {
    "gray-none-2page-le.tif": "compare",
    "rgb-packbits.tif": "compare",
    "rgb-lzw-predictor.tif": "compare",
    "gray16-deflate-predictor.tif": "compare",
    "g4-text-2page-be.tif": "compare",
    "g3-text-le.tif": "compare",
    "bigtiff-rgb-2page.tif": "compare",
    "metadata-gray.tif": "compare",
    "minisblack-1c-8b.tiff": "compare",
    "miniswhite-1c-1b.tiff": "compare",
    "rgb-3c-8b.tiff": "compare",
    "testfax4.tiff": "compare",
    "testfax3_bug54_1dnoEOL.tif": "compare",
    "quad-lzw-compat.tiff": "compare",
    "test_two_ifds.tif": "compare",
    "tiff_with_subifd_chain.tif": "compare",
    "deflate-last-strip-extra-data.tiff": "compare",
    "jpeg-external-tables.tif": "reject:TiffUnsupportedCodecException",
    "ojpeg_zackthecat_subsamp22_single_strip.tiff": "reject:TiffUnsupportedCodecException",
    "palette-1c-8b.tiff": "reject:TiffUnsupportedCodecException",
    "logluv-3c-16b.tiff": "reject:TiffUnsupportedCodecException",
    "quad-tile.jpg.tiff": "reject:TiffUnsupportedCodecException",
    "minisblack-2c-8b-alpha.tiff": "reject:TiffUnsupportedCodecException",
    "test_ifd_loop_to_self.tif": "reject:TiffException",
}

# Gate-time derivations from tracked sources: (output, source, tiffcp args, layout).
DERIVED_MATRIX = [
    ("cramps-none-t128-be.tif", "cramps-tile.tif", ["-B", "-t", "-w", "128", "-l", "128", "-c", "none"], "cramps gray8 none 128x128 BE"),
    ("cramps-zip-t256.tif", "cramps-tile.tif", ["-L", "-t", "-w", "256", "-l", "256", "-c", "zip"], "cramps gray8 Deflate 256x256"),
    ("cramps-packbits-t32-big.tif", "cramps.tif", ["-8", "-L", "-t", "-w", "32", "-l", "32", "-c", "packbits"], "cramps gray8 PackBits 32x32 BigTIFF"),
    ("quad-lzw-t64-be.tif", "quad-tile.tif", ["-B", "-t", "-w", "64", "-l", "64", "-c", "lzw"], "quad RGB8 LZW 64x64 BE"),
    ("quad-packbits-t256-big-be.tif", "quad-tile.tif", ["-8", "-B", "-t", "-w", "256", "-l", "256", "-c", "packbits"], "quad RGB8 PackBits 256x256 BigTIFF BE"),
    ("quad-none-t16.tif", "quad-tile.tif", ["-L", "-t", "-w", "16", "-l", "16", "-c", "none"], "quad RGB8 none 16x16"),
    ("ladoga-none-t32-be.tif", "ladoga.tif", ["-B", "-t", "-w", "32", "-l", "32", "-c", "none"], "ladoga gray16 none 32x32 BE"),
    ("ladoga-packbits-t16-big.tif", "ladoga.tif", ["-8", "-L", "-t", "-w", "16", "-l", "16", "-c", "packbits"], "ladoga gray16 PackBits 16x16 BigTIFF"),
    ("testfax4-g4-t128.tif", "testfax4.tiff", ["-L", "-t", "-w", "128", "-l", "128", "-c", "g4"], "testfax4 bilevel Group 4 128x128 tiles (2453x3369)"),
    ("testfax4-g3-t256-be.tif", "testfax4.tiff", ["-B", "-t", "-w", "256", "-l", "256", "-c", "g3"], "testfax4 bilevel Group 3 1D 256x256 BE"),
    ("testfax4-lzw-t64-big.tif", "testfax4.tiff", ["-8", "-L", "-t", "-w", "64", "-l", "64", "-c", "lzw"], "testfax4 bilevel LZW 64x64 BigTIFF"),
    ("gray16-strip-to-tile-be.tif", "gray16-deflate-predictor.tif", ["-B", "-t", "-w", "32", "-l", "32", "-c", "zip:2"], "gray16 ramp Deflate predictor 2, 32x32 BE"),
    ("rgb-lzw-to-tile-big.tif", "rgb-lzw-predictor.tif", ["-8", "-L", "-t", "-w", "64", "-l", "16", "-c", "lzw:2"], "rgb ramp LZW predictor 2, 64x16 BigTIFF"),
    ("mixed-cramps-quad-2page.tif", None, ["cramps-tile.tif", "quad-tile.tif"], "two SGI tiled pages concatenated"),
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
    for candidate in [os.environ.get("DART"), "dart", str(Path.home() / "fvm" / "default" / "bin" / "dart")]:
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
    commands.append(run(
        ["cc", "-O2", "-o", dump_binary, DUMP_SOURCE, f"-I{LIBTIFF_PREFIX}/include", f"-L{LIBTIFF_PREFIX}/lib", "-ltiff"],
        out / "version" / "cc-dump.log",
    ))
    if commands[-1]["exitCode"] != 0:
        print("could not build tiff_oracle_dump", file=sys.stderr)
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
    }

    # 2. Tracked inputs: read-only copies with verified hashes.
    cases = []
    manifest = json.loads(TILED_MANIFEST.read_text())
    tracked = []
    for entry in manifest["files"]:
        tracked.append(("tiled", Path("test/resources/tiff/tiled") / entry["name"], entry["sha256"], entry["expectation"], entry.get("layout", ""), entry.get("producer", "")))
    for name, expectation in STRIP_EXPECTATIONS.items():
        path = STRIP_DIR / name
        tracked.append(("strips", path, None, expectation, "pre-existing strip corpus", "tracked"))
    failures = 0
    for group, source, expected_sha, expectation, layout, producer in tracked:
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
            "id": f"{group}/{source.name}",
            "group": group,
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
        for name, source, extra, layout in DERIVED_MATRIX:
            target = out / "derived" / name
            if source is None:
                argv = [tiffcp, *[str(out / "inputs" / s) for s in extra], target]
            else:
                argv = [tiffcp, *extra, out / "inputs" / source, target]
            record = run(argv, out / "derived" / f"{name}.tiffcp.log")
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
                "expectation": "compare",
                "layout": layout,
                "producer": f"tiffcp (libtiff 4.7.2) at gate time from {source or ', '.join(extra)}",
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
                for key in ["nativeFile", "rgbaFile"]:
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
        "mission": "C03",
        "head": head,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "libtiff": versions,
        "commands": commands,
        "cases": cases,
        "totals": {
            "cases": len(cases),
            "tiled": sum(1 for c in cases if c["group"] == "tiled"),
            "strips": sum(1 for c in cases if c["group"] == "strips"),
            "derived": sum(1 for c in cases if c["group"] == "derived"),
            "failures": failures,
        },
    }
    (out / "reference.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["totals"]))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
