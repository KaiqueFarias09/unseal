#!/usr/bin/env python3
"""Record the reference tools' versions for the B01 oracle gate.

Runs each development-only reference tool, keeps its banner, and writes
one log per tool plus a manifest with hashes into the output directory.

Usage: b01_oracle_versions.py <output-dir>
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path


def run(argv: list[str]) -> tuple[int, bytes]:
    result = subprocess.run(argv, capture_output=True)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    checks = []
    for name, argv in (
        ("djvused", ["djvused", "--version"]),
        ("djvutxt", ["djvutxt"]),
        ("xmllint", ["xmllint", "--version"]),
        ("tesseract", ["tesseract", "--version"]),
        ("python", [sys.executable, "--version"]),
    ):
        code, output = run(argv)
        log = out / f"{name}.log"
        log.write_bytes(output)
        checks.append(
            {
                "name": name,
                "argv": argv,
                "exitCode": code,
                "banner": output.decode("utf-8", "replace").splitlines()[0]
                if output.strip()
                else "",
                "log": log.name,
                "sha256": hashlib.sha256(output).hexdigest(),
            }
        )

    manifest = {"tool": "b01_oracle_versions", "checks": checks}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for check in checks:
        print(f"{check['name']}: exit {check['exitCode']} — {check['banner']}")
    return 0 if all(check["exitCode"] == 0 or check["name"] == "djvutxt" for check in checks) else 1


if __name__ == "__main__":
    sys.exit(main())
