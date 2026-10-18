#!/usr/bin/env python3
"""Creates the C02 negative corpus as derived, mutated copies of the real
kant_aufklaerung_1784_0017 GT file. The original stays untouched; every
negative records the mutation that makes it schema-invalid (or, for the
schema-valid `positive-alternatives-confidence` sample, the additions
that exercise attributes the corpus itself lacks).
"""

import argparse
from pathlib import Path

import lxml.etree as etree

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path("build/c02"))
HERE = parser.parse_args().root.resolve()
SOURCE = HERE / "corpus" / "kant_aufklaerung_1784_0017.xml"
OUT = HERE / "negatives"
NS = "http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"
OLD_NS = "http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15"


def tree():
    return etree.parse(str(SOURCE))


def save(doc, name, note):
    doc.write(str(OUT / name), xml_declaration=True, encoding="UTF-8")
    (OUT / (name + ".mutation.txt")).write_text(note + "\n")
    print("wrote", name, "-", note)


def first_region(doc):
    return doc.find(".//{%s}TextRegion" % NS)


def main():
    OUT.mkdir(exist_ok=True)

    doc = tree()
    page = doc.find(".//{%s}Page" % NS)
    del page.attrib["imageWidth"]
    save(doc, "negative-missing-imageWidth.xml", "removed required Page/@imageWidth")

    doc = tree()
    coords = doc.find(".//{%s}TextRegion/{%s}Coords" % (NS, NS))
    coords.set("points", "-5,-5 100,20 40,60")
    save(doc, "negative-negative-points.xml", "Coords/@points with negative coordinates violates the PointsType pattern")

    doc = tree()
    coords = doc.find(".//{%s}TextRegion/{%s}Coords" % (NS, NS))
    coords.set("conf", "1.5")
    save(doc, "negative-conf-above-one.xml", "Coords/@conf=1.5 violates ConfSimpleType (0..1)")

    doc = tree()
    first_region(doc).set("type", "bogus")
    save(doc, "negative-bad-text-type.xml", "TextRegion/@type='bogus' violates TextTypeSimpleType")

    doc = tree()
    metadata = doc.find(".//{%s}Metadata" % NS)
    creator = metadata.find("{%s}Creator" % NS)
    metadata.remove(creator)
    save(doc, "negative-missing-creator.xml", "removed required Metadata/Creator")

    doc = tree()
    root = doc.getroot()
    root.tag = "{%s}PcGts" % OLD_NS
    save(doc, "negative-wrong-namespace.xml", "root namespace 2013-07-15 is outside the 2019-07-15 target namespace")

    doc = tree()
    ref = doc.find(".//{%s}RegionRefIndexed" % NS)
    ref.set("regionRef", "r_does_not_exist")
    save(doc, "negative-dangling-region-ref.xml", "RegionRefIndexed/@regionRef points at no declared ID")

    doc = tree()
    line = doc.find(".//{%s}TextLine" % NS)
    line.set("id", first_region(doc).get("id"))
    save(doc, "negative-duplicate-id.xml", "TextLine/@id duplicates the region ID, violating xs:ID uniqueness")

    doc = tree()
    word = doc.find(".//{%s}Word" % NS)
    for equiv in word.findall("{%s}TextEquiv" % NS):
        word.remove(equiv)
        break
    equiv = etree.SubElement(word, "{%s}TextEquiv" % NS)
    etree.SubElement(equiv, "{%s}PlainText" % NS).text = "no unicode here"
    save(doc, "negative-textequiv-without-unicode.xml", "TextEquiv without required Unicode child")

    (OUT / "negative-malformed.xml").write_bytes(
        SOURCE.read_bytes()[: SOURCE.stat().st_size // 2]
    )
    (OUT / "negative-malformed.xml.mutation.txt").write_text(
        "first half of the bytes of a valid file: not well-formed XML\n"
    )
    print("wrote negative-malformed.xml - truncated bytes")

    doc = tree()
    page = doc.find(".//{%s}Page" % NS)
    region = first_region(doc)
    region.set("orientation", "90.0")
    region.set("readingOrientation", "0.0")
    equiv = region.find("{%s}TextEquiv" % NS)
    equiv.set("index", "1")
    equiv.set("conf", "0.812")
    alternative = etree.Element("{%s}TextEquiv" % NS)
    alternative.set("index", "0")
    alternative.set("conf", "0.977")
    unicode_element = etree.Element("{%s}Unicode" % NS)
    unicode_element.text = "πάθει μῆκος ὀφείλεται — 𝕌𝕟𝕚𝕔𝕠𝕕𝕖: ſæculum"
    alternative.append(unicode_element)
    equiv.addprevious(alternative)
    line = doc.find(".//{%s}TextLine" % NS)
    baseline = line.find("{%s}Baseline" % NS)
    baseline.set("conf", "0.91")
    page.set("orientation", "180.0")
    page.set("conf", "0.995")
    page.set("imageXResolution", "300")
    page.set("imageResolutionUnit", "PPI")
    save(
        doc,
        "positive-alternatives-confidence.xml",
        "schema-valid derived sample: adds orientation (region+page), a lower-index TextEquiv "
        "alternative with conf, TextEquiv conf, baseline conf, page conf and PPI resolution — "
        "the attributes the Aletheia corpus itself does not declare",
    )


if __name__ == "__main__":
    main()
