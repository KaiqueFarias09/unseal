#!/usr/bin/env python3
"""Dump one ALTO file's positioned content as JSON, independently of Unseal.

The extraction uses only the Python standard library (xml.etree), so the
B01 comparator can diff Unseal's parse against a second implementation.
Coordinates stay verbatim; namespace handling accepts any ns-v* document.

Usage: alto_reference_dump.py <alto.xml> <out.json>
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    out = Path(sys.argv[2])
    root = ET.parse(source).getroot()
    if local(root.tag) != "alto":
        print("not an ALTO root", file=sys.stderr)
        return 1
    import re

    ns = root.tag[1:].split("}", 1)[0] if root.tag.startswith("{") else ""
    match = re.search(r"ns-v(\d)", ns)
    version = int(match.group(1)) if match else 0

    unit_node = root.find(".//{*}MeasurementUnit")
    software = root.find(".//{*}processingSoftware/{*}softwareName")
    software_version = root.find(".//{*}processingSoftware/{*}softwareVersion")

    def dump_block(block):
        kind = local(block.tag)
        entry = {
            "kind": kind,
            "hpos": block.get("HPOS"),
            "vpos": block.get("VPOS"),
            "width": block.get("WIDTH"),
            "height": block.get("HEIGHT"),
            "lines": [],
            "children": [dump_block(child) for child in block if local(child.tag).endswith("Block")],
        }
        for line in block.findall("{*}TextLine"):
            strings = [
                {
                    "content": string.get("CONTENT"),
                    "hpos": string.get("HPOS"),
                    "vpos": string.get("VPOS"),
                    "width": string.get("WIDTH"),
                    "height": string.get("HEIGHT"),
                    "wc": string.get("WC"),
                }
                for string in line.findall("{*}String")
            ]
            entry["lines"].append(
                {
                    "hpos": line.get("HPOS"),
                    "vpos": line.get("VPOS"),
                    "width": line.get("WIDTH"),
                    "height": line.get("HEIGHT"),
                    "wc": line.get("WC"),
                    "strings": strings,
                }
            )
        return entry

    pages = []
    for page in root.findall(".//{*}Page"):
        blocks = [dump_block(block) for block in page.findall(".//{*}PrintSpace/*")]
        pages.append(
            {
                "width": page.get("WIDTH"),
                "height": page.get("HEIGHT"),
                "printed": page.get("PHYSICAL_IMG_NR"),
                "pc": page.get("PC"),
                "blocks": blocks,
            }
        )

    payload = {
        "source": source.name,
        "version": version,
        "unit": unit_node.text.strip() if unit_node is not None and unit_node.text else None,
        "softwareName": software.text.strip() if software is not None and software.text else None,
        "softwareVersion": software_version.text.strip()
        if software_version is not None and software_version.text
        else None,
        "pages": pages,
    }
    out.write_text(json.dumps(payload, indent=1) + "\n")
    print(f"dumped {len(pages)} page(s) of {source.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
