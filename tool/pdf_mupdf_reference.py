#!/usr/bin/env python3
"""C01 reference stage: independent MuPDF (PyMuPDF) dump of PDF fixtures.

Opens each fixture read-only, authenticates when a password is supplied,
and records the version that actually ran, the command's inputs, page
geometry/rotation, extracted text, metadata, and the outline (TOC). The
JSON feeds `tool/pdf_range_compare.dart`, which scores Unseal's session
output against it under the fixed fold + bigram-dice policy.

Usage (run with the campaign venv python so PyMuPDF resolves):

    python3 tool/pdf_mupdf_reference.py \
        --output build/evidence/C01/reference.json \
        [--password fixture.pdf=secret]... \
        fixture1.pdf fixture2.pdf ...

Exit code 0 only when every fixture opened and dumped.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import fitz


def sha256_of(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dump_fixture(path, password):
    document = fitz.open(str(path))
    try:
        needs_password = bool(document.needs_pass)
        if needs_password:
            if not password:
                raise ValueError(f"{path}: document needs a password, none supplied")
            if not document.authenticate(password):
                raise ValueError(f"{path}: authentication with the supplied password failed")

        pages = []
        for index in range(document.page_count):
            page = document[index]
            pages.append(
                {
                    "index": index,
                    "width": round(page.rect.width, 3),
                    "height": round(page.rect.height, 3),
                    "rotation": page.rotation,
                    "text": page.get_text("text"),
                }
            )

        return {
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": sha256_of(path),
            "needsPassword": needs_password,
            "pageCount": document.page_count,
            "metadata": {
                "title": document.metadata.get("title") or "",
                "author": document.metadata.get("author") or "",
                "producer": document.metadata.get("producer") or "",
                "creator": document.metadata.get("creator") or "",
            },
            "toc": [
                {"level": level, "title": title, "page": page_number}
                for level, title, page_number in document.get_toc()
            ],
            "pages": pages,
        }
    finally:
        document.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--password", action="append", default=[])
    args = parser.parse_args()

    passwords = {}
    for pair in args.password:
        path, _, secret = pair.partition("=")
        if not path or not _:
            parser.error(f"--password expects path=secret, got {pair!r}")
        passwords[path] = secret

    version_line = (fitz.__doc__ or "").strip().splitlines()
    report = {
        "tool": {
            "name": "PyMuPDF",
            "version": fitz.__version__ if hasattr(fitz, "__version__") else fitz.VersionBind,
            "mupdf": fitz.VersionFitz if hasattr(fitz, "VersionFitz") else fitz.MUZIP_VERSION
            if hasattr(fitz, "MUZIP_VERSION")
            else "",
            "versionBanner": version_line[0] if version_line else "",
            "python": sys.version.split(" ")[0],
        },
        "fixtures": [],
    }
    for fixture in args.fixtures:
        if not fixture.is_file():
            parser.error(f"fixture not found: {fixture}")
        entry = dump_fixture(fixture, passwords.get(str(fixture), ""))
        report["fixtures"].append(entry)
        print(
            f"reference: {fixture} pages={entry['pageCount']} "
            f"chars={sum(len(p['text']) for p in entry['pages'])} "
            f"toc={len(entry['toc'])} sha256={entry['sha256'][:16]}…"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1) + "\n")
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
