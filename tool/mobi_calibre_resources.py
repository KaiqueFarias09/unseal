#!/usr/bin/env python3
"""Run with calibre-debug -e to hash original MOBI image/font resources.

ebook-convert may resize covers, discard thumbnails, and rewrite CSS. This
reference uses Calibre's PalmDB reader and FONT decoder before conversion.
Names differ between implementations, so comparison uses a hash multiset.
"""

import hashlib
import json
import sys
from pathlib import Path

from calibre.constants import __version__
from calibre.ebooks.mobi.reader.mobi6 import MobiReader
from calibre.ebooks.mobi.utils import read_font_record
from calibre.utils.imghdr import what


def main():
    source, destination = map(Path, sys.argv[1:3])
    reader = MobiReader(str(source))
    reader.check_for_drm()
    resources = []
    for index, (data, _) in enumerate(reader.sections):
        kind = what(None, data)
        if data.startswith(b"FONT"):
            decoded = read_font_record(data)
            if decoded["err"]:
                raise ValueError(decoded["err"])
            data = decoded["font_data"] or decoded["raw_data"]
            kind = "font"
        elif kind not in {"jpeg", "jpg", "gif", "png", "bmp", "webp"}:
            continue
        resources.append({"record": index, "kind": kind, "bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest()})
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps({
        "calibreVersion": __version__, "inputSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "resources": resources,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
