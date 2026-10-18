#!/usr/bin/env python3
"""Print the PAGE oracle, schema, and input identities without network access."""
import argparse
import hashlib
import platform
import subprocess
from pathlib import Path
from lxml import etree

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path("build/c02"))
parser.add_argument("--dart", default="dart")
args = parser.parse_args()
schema = args.root / "schema/pagecontent-2019-07-15.xsd"
digest = hashlib.sha256(schema.read_bytes()).hexdigest()
if digest != "5d7da5af5f5e06d3b9cd1e78b407ffca1862f78ad9823ed89c302fb6409932d5":
    raise SystemExit("PAGE schema hash drifted")
subprocess.run([args.dart, "--version"], check=True)
print("python", platform.python_version(), "lxml", etree.LXML_VERSION, "libxml2", etree.LIBXML_VERSION)
print("schema sha256", digest)
for folder in ("corpus", "negatives"):
    for path in sorted((args.root / folder).glob("*.xml")):
        print(path, hashlib.sha256(path.read_bytes()).hexdigest())
