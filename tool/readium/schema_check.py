#!/usr/bin/env python3
"""D01 schema gate: validate the fixed corpus against the official Readium
Locator schema (syntax-derived, pinned) plus the normative rules the schema
does not express.

The raw upstream schema carries a trailing comma outside strings and is never
parsed here; its bytes are pinned by hash and validation uses only the derived
file whose derivation is recorded in locator-derivation.json. This validator is
a *local normative checker*, not an official Readium artifact: the official
position-list schema path returned 404 at preparation time and no official
schema is claimed for it.

Usage: schema_check.py <evidence-dir> <corpus-json>
Writes <evidence-dir>/schema-check.json.
"""
import hashlib
import json
import sys
from pathlib import Path

from jsonschema import Draft7Validator, FormatChecker

NORMATIVE_RULES = {
    "hrefNonEmpty": "href must be a non-empty string (spec: required URI)",
    "typeNonEmpty": "type must be a non-empty media-type string (spec: required)",
    "hrefWithoutFragment": "href must not point to the fragment of a resource (spec normative statement)",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_normative(locator: dict) -> list[str]:
    violations = []
    href = locator.get("href")
    if not isinstance(href, str) or not href:
        violations.append("hrefNonEmpty")
    elif "#" in href:
        violations.append("hrefWithoutFragment")
    if not isinstance(locator.get("type"), str) or not locator.get("type"):
        violations.append("typeNonEmpty")
    return violations


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: schema_check.py <evidence-dir> <corpus-json>", file=sys.stderr)
        return 2
    evidence = Path(sys.argv[1])
    corpus_path = Path(sys.argv[2])
    derived_schema_path = evidence / "locator-derived.schema.json"
    derivation_path = evidence / "locator-derivation.json"
    raw_schema_path = evidence / "locator.schema.json"

    schema = json.loads(derived_schema_path.read_text())
    corpus = json.loads(corpus_path.read_text())
    reference = json.loads((evidence / "reference.json").read_text())
    derivation = json.loads(derivation_path.read_text())
    validator = Draft7Validator(schema, format_checker=FormatChecker())

    # The raw upstream schema bytes must be preserved unmodified: its pinned
    # hash equals the source hash recorded by the preparation.
    raw_matches = sha256(raw_schema_path) == corpus["sources"]["locatorSchema"]["rawSha256"]
    derived_matches = sha256(derived_schema_path) == corpus["sources"]["locatorSchema"]["derivedSha256"]

    results = []
    by_id = {case["id"]: case for case in reference["cases"]}
    for entry in corpus["cases"]:
        record = {"id": entry["id"], "kind": entry["kind"]}
        if entry["kind"] == "locator":
            input_errors = sorted(validator.iter_errors(entry["input"]), key=lambda e: e.json_path)
            record["inputSchemaValid"] = not input_errors
            record["inputSchemaErrors"] = [e.message for e in input_errors]
            record["inputNormativeViolations"] = (
                [] if entry.get("expectRejected") else check_normative(entry["input"])
            )
            ref = by_id[entry["id"]]
            if ref.get("rejected"):
                record["toolkitRejected"] = True
                record["outputSchemaValid"] = None
            else:
                output_errors = sorted(
                    validator.iter_errors(ref["output"]), key=lambda e: e.json_path
                )
                record["toolkitRejected"] = False
                record["outputSchemaValid"] = not output_errors
                record["outputSchemaErrors"] = [e.message for e in output_errors]
                record["outputNormativeViolations"] = check_normative(ref["output"])
        else:
            # Position-list service shape: the official schema covers single
            # Locators only; each entry is validated as a Locator.
            entry_results = []
            for position in entry["input"]["positions"]:
                errors = sorted(validator.iter_errors(position), key=lambda e: e.json_path)
                entry_results.append(
                    {
                        "schemaValid": not errors,
                        "errors": [e.message for e in errors],
                        "normativeViolations": check_normative(position),
                    }
                )
            record["entries"] = entry_results
        results.append(record)

    report = {
        "schemaVersion": 1,
        "schema": "official Readium Locator schema (pinned, syntax-derived)",
        "schemaId": schema.get("$id"),
        "rawSchemaSha256": sha256(raw_schema_path),
        "derivedSchemaSha256": sha256(derived_schema_path),
        "rawBytesPreserved": raw_matches,
        "derivedMatchesDerivation": derived_matches and derivation.get("derivedSha256") == corpus["sources"]["locatorSchema"]["derivedSha256"],
        "derivationNote": derivation.get("reason"),
        "normativeRules": NORMATIVE_RULES,
        "positionListSchema": "no official schema exists (official path 404); entries checked against the official Locator schema and the normative positions document",
        "cases": results,
    }
    out = evidence / "schema-check.json"
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"schema check: {len(results)} cases -> {out}")
    if not (raw_matches and report["derivedMatchesDerivation"]):
        print("pinned schema hashes diverged", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
