#!/usr/bin/env python3
"""C02 reference runner: validates every corpus and negative file against
the pinned official PAGE 2019-07-15 XSD, extracts the valid ones with the
independent extractor, and writes the reference artifacts the oracle gate
consumes:

  outputs/reference-versions.log   tool/schema identity (banner level)
  outputs/reference-validation.json  per-file XSD verdicts and errors
  outputs/reference.json           pin + provenance + extractions
"""

import argparse
import hashlib
import json
import platform
import sys
from pathlib import Path

import lxml.etree as etree

ARGUMENTS = argparse.ArgumentParser(description=__doc__)
ARGUMENTS.add_argument("--root", type=Path, default=Path("build/c02"))
ARGS = ARGUMENTS.parse_args()
HERE = ARGS.root.resolve()
CORPUS = HERE / "corpus"
NEGATIVES = HERE / "negatives"
SCHEMA = HERE / "schema" / "pagecontent-2019-07-15.xsd"
OUT = HERE / "outputs"

EXPECTED_SCHEMA_SHA256 = "5d7da5af5f5e06d3b9cd1e78b407ffca1862f78ad9823ed89c302fb6409932d5"

NEGATIVES_MUST_BE_INVALID = [
    "negative-missing-imageWidth.xml",
    "negative-negative-points.xml",
    "negative-conf-above-one.xml",
    "negative-bad-text-type.xml",
    "negative-missing-creator.xml",
    "negative-wrong-namespace.xml",
    "negative-duplicate-id.xml",
    "negative-textequiv-without-unicode.xml",
    "negative-malformed.xml",
]

# libxml2's XSD validator does not enforce xs:IDREF resolution, so a PAGE
# document whose ReadingOrder points at a nonexistent region validates
# clean. The schema alone cannot certify reference integrity — the Dart
# parser rejects this document with its own ref validation, and the
# comparison stage pins that outcome.
SCHEMA_VALID_BUT_PARSER_NEGATIVE = {
    "negative-dangling-region-ref.xml": "libxml2 XSD validation does not check xs:IDREF resolution",
}

PROVENANCE = {
    "source": "https://github.com/OCR-D/gt_structure_text",
    "license": "CC-BY-SA-4.0 (LICENSE.md recorded beside the corpus)",
    "schema": "PAGE pagecontent 2019-07-15 official XSD",
    "schemaSha256": EXPECTED_SCHEMA_SHA256,
    "note": "Target images travel beside their sidecars; SHA-256 of every "
    "input is pinned in outputs/corpus-input-sha256.txt.",
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    schema_bytes = SCHEMA.read_bytes()
    actual = hashlib.sha256(schema_bytes).hexdigest()
    if actual != EXPECTED_SCHEMA_SHA256:
        sys.exit("schema hash drifted: %s" % actual)
    schema = etree.XMLSchema(etree.parse(str(SCHEMA)))

    versions = OUT / "reference-versions.log"
    versions.write_text(
        "python %s\nlxml %s (compiled against libxml2 %s)\n"
        % (platform.python_version(), ".".join(map(str, etree.LXML_VERSION)), ".".join(map(str, etree.LIBXML_VERSION)))
        + "XSD %s sha256 %s\n" % (SCHEMA.name, EXPECTED_SCHEMA_SHA256)
    )

    validation = {"schemaSha256": EXPECTED_SCHEMA_SHA256, "files": {}}
    extractions = {}
    failures = []

    expected_corpus = json.loads((Path(__file__).resolve().parent / "reference/page_xml/corpus-sha256.json").read_text())
    corpus_files = sorted(CORPUS.glob("*.xml"))
    observed = {path.name: sha256(path) for path in corpus_files}
    if observed != expected_corpus:
        sys.exit("PAGE corpus differs from the versioned six-document hash inventory")
    if not corpus_files:
        sys.exit("no corpus files found")

    for path in corpus_files:
        valid, errors = validate(schema, path)
        validation["files"][path.name] = {"role": "corpus", "schemaValid": valid, "errors": errors}
        if not valid:
            failures.append("corpus file failed XSD: %s %s" % (path.name, errors[:1]))
        else:
            extractions[path.name] = extract(path)

    for path in sorted(NEGATIVES.glob("*.xml")):
        valid, errors = validate(schema, path)
        positive_derived = path.name.startswith("positive-")
        schema_valid_allowed = positive_derived or path.name in SCHEMA_VALID_BUT_PARSER_NEGATIVE
        if valid and not schema_valid_allowed:
            failures.append(
                "%s validated True but must be invalid: %s" % (path.name, errors[:1])
            )
        if not valid and schema_valid_allowed:
            failures.append(
                "%s validated False but must stay schema-valid: %s" % (path.name, errors[:1])
            )
        validation["files"][path.name] = {
            "role": "positive-derived"
            if positive_derived
            else ("parser-negative" if path.name in SCHEMA_VALID_BUT_PARSER_NEGATIVE else "negative"),
            "schemaValid": valid,
            "errors": errors,
            "schemaValidAllowed": schema_valid_allowed and not positive_derived,
            "mutation": (NEGATIVES / (path.name + ".mutation.txt")).read_text().strip(),
        }
        if valid:
            extractions[path.name] = extract(path)

    missing = [name for name in NEGATIVES_MUST_BE_INVALID if name not in validation["files"]]
    if missing:
        failures.append("required negatives absent: %s" % missing)

    if failures:
        for failure in failures:
            print("FAIL:", failure, file=sys.stderr)
        sys.exit(1)

    (OUT / "reference-validation.json").write_text(
        json.dumps(validation, ensure_ascii=False, indent=1) + "\n"
    )
    reference = {
        "pin": {
            "extractor": "tool/reference/page_xml/extract_page_xml.py (independent lxml implementation)",
            "lxml": ".".join(map(str, etree.LXML_VERSION)),
            "libxml2": ".".join(map(str, etree.LIBXML_VERSION)),
            "schemaSha256": EXPECTED_SCHEMA_SHA256,
        },
        "provenance": PROVENANCE,
        "inputs": {
            path.name: sha256(path)
            for path in sorted([*corpus_files, *sorted(NEGATIVES.glob("*.xml"))])
        },
        "documents": extractions,
    }
    (OUT / "reference.json").write_text(json.dumps(reference, ensure_ascii=False, indent=1) + "\n")
    print(
        "reference ok: %d corpus + %d negative/positive files; %d extracted"
        % (len(corpus_files), len(validation["files"]) - len(corpus_files), len(extractions))
    )


def validate(schema, path):
    try:
        doc = etree.parse(str(path))
    except etree.XMLSyntaxError as error:
        return False, ["XMLSyntaxError: %s" % error]
    if schema.validate(doc):
        return True, []
    return False, [str(entry) for entry in schema.error_log]


def extract(path):
    sys.path.insert(0, str(Path(__file__).resolve().parent / "reference" / "page_xml"))
    from extract_page_xml import extract

    return extract(str(path))


if __name__ == "__main__":
    main()
