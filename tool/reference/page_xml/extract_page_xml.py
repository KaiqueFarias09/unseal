#!/usr/bin/env python3
"""Independent PAGE XML 2019-07-15 extractor (C02 reference oracle).

Extracts the contract subset from a PAGE document with lxml only: page
identity and dimensions, all region kinds, text regions with lines and
words, native polygons, baselines, ReadingOrder groups, TextEquiv
content with alternatives, confidence and language attributes. The
output is JSON the Dart implementation is later diffed against — the
two implementations share no code.

TextEquiv choice policy (declared, deterministic): among a node's
TextEquiv children, the chosen one is the first in document order with
the lowest declared `index` (missing index sorts after every present
index at equal rank... no: missing index is treated as +inf, and ties
fall back to document order). This mirrors the schema note that the
lowest index is the main text content.
"""

import json
import sys

from lxml import etree

NAMESPACE = "http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"
PC = "{%s}" % NAMESPACE

REGION_KINDS = [
    "TextRegion",
    "ImageRegion",
    "LineDrawingRegion",
    "GraphicRegion",
    "TableRegion",
    "ChartRegion",
    "MapRegion",
    "SeparatorRegion",
    "MathsRegion",
    "ChemRegion",
    "MusicRegion",
    "AdvertRegion",
    "NoiseRegion",
    "UnknownRegion",
    "CustomRegion",
]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_points(raw):
    """Parses 'x1,y1 x2,y2' into a flat integer list."""
    points = []
    for pair in raw.strip().split(" "):
        x_text, _, y_text = pair.partition(",")
        points.append([int(x_text), int(y_text)])
    return points


def bbox_of(points):
    """The explicitly derived bounding box over a point list."""
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def text_equivs(node):
    """Every TextEquiv of a node: chosen content plus alternatives."""
    equivs = []
    for element in node.findall(PC + "TextEquiv"):
        unicode_element = element.find(PC + "Unicode")
        plain = element.find(PC + "PlainText")
        index = element.get("index")
        equivs.append(
            {
                # An empty <Unicode/> element reads as None under lxml;
                # the schema-required content is the empty string.
                "unicode": (unicode_element.text or "")
                if unicode_element is not None
                else None,
                "plainText": plain.text if plain is not None else None,
                "index": int(index) if index is not None else None,
                "conf": element.get("conf"),
            }
        )
    if not equivs:
        return None
    ordered = sorted(
        enumerate(equivs),
        key=lambda item: (item[1]["index"] if item[1]["index"] is not None else float("inf"), item[0]),
    )
    return {
        "chosen": ordered[0][1]["unicode"],
        "chosenIndex": ordered[0][1]["index"],
        "alternatives": [
            {"unicode": item["unicode"], "index": item["index"], "conf": item["conf"]}
            for _, item in ordered
        ],
    }


def polygon(node):
    coords = node.find(PC + "Coords")
    if coords is None:
        return None
    points = parse_points(coords.get("points"))
    return {
        "points": points,
        "bbox": bbox_of(points),
        "conf": coords.get("conf"),
    }


def extract_text_line(element):
    baseline = element.find(PC + "Baseline")
    words = [extract_word(word) for word in element.findall(PC + "Word")]
    return {
        "id": element.get("id"),
        "polygon": polygon(element),
        "baseline": None
        if baseline is None
        else {
            "points": parse_points(baseline.get("points")),
            "conf": baseline.get("conf"),
        },
        "primaryLanguage": element.get("primaryLanguage"),
        "readingDirection": element.get("readingDirection"),
        "index": element.get("index"),
        "textEquiv": text_equivs(element),
        "words": words,
    }


def extract_word(element):
    return {
        "id": element.get("id"),
        "polygon": polygon(element),
        "language": element.get("language"),
        "readingDirection": element.get("readingDirection"),
        "textEquiv": text_equivs(element),
    }


def extract_region(element):
    kind = etree.QName(element).localname
    region = {
        "kind": kind,
        "id": element.get("id"),
        "polygon": polygon(element),
        "continuation": element.get("continuation"),
        "custom": element.get("custom"),
    }
    if kind == "TextRegion":
        region["orientation"] = element.get("orientation")
        region["readingOrientation"] = element.get("readingOrientation")
        region["type"] = element.get("type")
        region["primaryLanguage"] = element.get("primaryLanguage")
        region["secondaryLanguage"] = element.get("secondaryLanguage")
        region["readingDirection"] = element.get("readingDirection")
        region["textLineOrder"] = element.get("textLineOrder")
        region["leading"] = element.get("leading")
        region["indented"] = element.get("indented")
        region["align"] = element.get("align")
        region["production"] = element.get("production")
        region["textEquiv"] = text_equivs(element)
        region["lines"] = [
            extract_text_line(line) for line in element.findall(PC + "TextLine")
        ]
    return region


def walk_group(element, into):
    """Flattens a ReadingOrder group tree into indexed entries."""
    for child in element:
        name = etree.QName(child).localname
        if name == "RegionRefIndexed":
            into.append({"kind": "RegionRefIndexed", "index": int(child.get("index")), "regionRef": child.get("regionRef")})
        elif name == "OrderedGroupIndexed":
            into.append({"kind": "OrderedGroupIndexed", "id": child.get("id"), "index": int(child.get("index")), "regionRef": child.get("regionRef")})
            walk_group(child, into)
        elif name == "UnorderedGroupIndexed":
            into.append({"kind": "UnorderedGroupIndexed", "id": child.get("id"), "index": int(child.get("index")), "regionRef": child.get("regionRef")})
            walk_group(child, into)
        elif name == "RegionRef":
            into.append({"kind": "RegionRef", "regionRef": child.get("regionRef")})
        elif name in ("OrderedGroup", "UnorderedGroup"):
            into.append({"kind": name, "id": child.get("id")})
            walk_group(child, into)


def extract(path):
    tree = etree.parse(path)
    root = tree.getroot()
    if root.tag != PC + "PcGts":
        fail("%s: root is %s" % (path, root.tag))

    metadata = root.find(PC + "Metadata")
    page = root.find(PC + "Page")
    regions = []
    for child in page:
        if etree.QName(child).localname in REGION_KINDS:
            regions.append(extract_region(child))

    reading_order = page.find(PC + "ReadingOrder")
    order_entries = []
    if reading_order is not None:
        group = reading_order[0]
        order_entries.append({"kind": etree.QName(group).localname, "id": group.get("id")})
        walk_group(group, order_entries)

    border = page.find(PC + "Border")
    print_space = page.find(PC + "PrintSpace")

    return {
        "pcGtsId": root.get("pcGtsId"),
        "metadata": {
            "creator": metadata.findtext(PC + "Creator"),
            "created": metadata.findtext(PC + "Created"),
            "lastChange": metadata.findtext(PC + "LastChange"),
            "comments": metadata.findtext(PC + "Comments"),
        },
        "page": {
            "imageFilename": page.get("imageFilename"),
            "imageWidth": int(page.get("imageWidth")),
            "imageHeight": int(page.get("imageHeight")),
            "imageXResolution": page.get("imageXResolution"),
            "imageYResolution": page.get("imageYResolution"),
            "imageResolutionUnit": page.get("imageResolutionUnit"),
            "orientation": page.get("orientation"),
            "type": page.get("type"),
            "primaryLanguage": page.get("primaryLanguage"),
            "conf": page.get("conf"),
            "border": polygon(border) if border is not None else None,
            "printSpace": polygon(print_space) if print_space is not None else None,
        },
        "regions": regions,
        "readingOrder": order_entries if reading_order is not None else None,
    }


if __name__ == "__main__":
    print(json.dumps(extract(sys.argv[1]), ensure_ascii=False, indent=1))
