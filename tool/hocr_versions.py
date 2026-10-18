#!/usr/bin/env python3
"""Print the D02 oracle identities without network access and fail when any
pin drifts: Tesseract 5.5.3 and its English model, lxml, the pinned hOCR
specification sources, the licensed images and the external sidecars.
"""

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

from lxml import etree

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / "reference" / "hocr" / "corpus-sha256.json").read_text())

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tesseract", default="/opt/homebrew/bin/tesseract")
parser.add_argument("--dart", default="dart")
parser.add_argument(
    "--spec-dir",
    type=Path,
    default=Path("build/d02/spec"),
    help="folder holding the pinned hOCR 1.2 spec.md and defs.yml copies (not committed; see doc/hocr.md)",
)
args = parser.parse_args()


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


failures = []
banner = subprocess.run([args.tesseract, "--version"], capture_output=True, text=True)
first = (banner.stdout + banner.stderr).splitlines()
print("\n".join(first[:4]))
if banner.returncode != 0 or not first or first[0].strip() != PINS["tesseract"]["banner"]:
    failures.append(f"tesseract banner {first[:1]!r} != {PINS['tesseract']['banner']!r}")
model = Path(PINS["tesseract"]["model"])
if not model.is_file() or sha256(model) != PINS["tesseract"]["modelSha256"]:
    failures.append("eng.traineddata missing or hash drifted")
else:
    print("eng.traineddata", sha256(model))
subprocess.run([args.dart, "--version"], check=True)
print("python", platform.python_version(), "lxml", etree.LXML_VERSION, "libxml2", etree.LIBXML_VERSION)
if list(etree.LXML_VERSION[:3]) != PINS["lxml"]:
    failures.append(f"lxml {etree.LXML_VERSION} != {PINS['lxml']}")
for name, expected in PINS["spec"].items():
    path = args.spec_dir / expected["file"]
    if not path.is_file():
        failures.append(f"missing spec copy {path}; download {expected['url']}")
        continue
    actual = sha256(path)
    print("spec", name, actual)
    if actual != expected["sha256"]:
        failures.append(f"spec/{name} hash drifted")
for group in ("images", "external", "derived"):
    for name, expected in PINS[group].items():
        path = HERE.parent / expected["path"]
        if not path.is_file():
            failures.append(f"missing {path}")
            continue
        actual = sha256(path)
        print(group, name, actual)
        if actual != expected["sha256"]:
            failures.append(f"{group}/{name} hash drifted")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
