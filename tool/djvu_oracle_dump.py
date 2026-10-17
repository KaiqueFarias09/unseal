#!/usr/bin/env python3
"""Dump DjVuLibre's per-page spatial text reference for one book.

For every page N (1-based) this writes:

  page-N.sexpr  the zone tree, from `djvused -e 'select N; print-txt'`
  page-N.txt    the stored page text, from `djvused -e 'select N; print-pure-txt'`

plus a manifest.json recording the djvused version, the page count, and
each file's SHA-256. The dump is the comparison input of
`tool/djvu_spatial_compare.dart`; the extraction itself is entirely
DjVuLibre's.

Usage: djvu_oracle_dump.py <book.djvu> <output-dir>
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    book = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    version = subprocess.run(
        ["djvused", "--version"], capture_output=True, text=True
    ).stderr.strip().splitlines()[0]
    page_count = int(
        subprocess.run(
            ["djvused", "-e", "n", str(book)], capture_output=True, text=True
        ).stdout.strip()
    )

    manifest = {"tool": "djvused", "version": version, "book": book.name, "pages": []}
    for page in range(1, page_count + 1):
        for suffix, command in (
            ("sexpr", f"select {page}; print-txt"),
            ("txt", f"select {page}; print-pure-txt"),
        ):
            result = subprocess.run(
                ["djvused", "-e", command, str(book)], capture_output=True
            )
            if result.returncode != 0:
                print(f"page {page} {suffix}: djvused failed: {result.stderr!r}", file=sys.stderr)
                return 1
            path = out / f"page-{page}.{suffix}"
            path.write_bytes(result.stdout)
            manifest["pages"].append(
                {
                    "page": page,
                    "file": path.name,
                    "sha256": hashlib.sha256(result.stdout).hexdigest(),
                    "bytes": len(result.stdout),
                }
            )

    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"dumped {page_count} pages of {book.name} with {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
