#!/usr/bin/env python3
"""OPDS 2.0 schema oracle for the C05 mission.

Stages used by the oracle gate:

  setup     copy the pinned OPDS/Readium schema closure into the worktree
            build directory with verified SHA-256 hashes and print tool
            versions (gate stage "version").
  validate  run jsonschema Draft7 with a local referencing Registry over the
            committed corpus (positive / negative / normative-only /
            link-positive cases) and write the reference report (gate stage
            "reference").
  expected  regenerate or check the independent per-feed expectation files
            in test/resources/opds/expected/ that the Dart tests compare
            against.

The validator never touches the network: every schema is loaded from the
local copy through a referencing Registry keyed by $id.
"""

import argparse
import hashlib
import re
import json
import shutil
import sys
from pathlib import Path
from urllib.parse import urljoin, urlsplit


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"oracle error: {message}")


FEED_SCHEMA_ID = "https://specs.opds.io/schema/feed.schema.json"
LINK_SCHEMA_ID = "https://readium.org/webpub-manifest/schema/link.schema.json"
MANIFEST_NAME = "corpus-manifest.json"

# The BCP 47 patterns in the Readium/OPDS schemas use JS/.NET named-group
# syntax (?<name>...); Python's re needs (?P<name>...). Translate at load
# time. (?<= and (?<! lookbehinds are left untouched. Pattern semantics are
# unchanged.
_NAMED_GROUP = re.compile(r"\(\?<(?![=!])")


def _python_patterns(node):
    if isinstance(node, dict):
        return {
            (_NAMED_GROUP.sub("(?P<", key) if key == "patternProperties" else key): (
                {_NAMED_GROUP.sub("(?P<", k): _python_patterns(v) for k, v in value.items()}
                if key == "patternProperties" and isinstance(value, dict)
                else _NAMED_GROUP.sub("(?P<", value)
                if key == "pattern" and isinstance(value, str)
                else _python_patterns(value)
            )
            for key, value in node.items()
        }
    if isinstance(node, list):
        return [_python_patterns(item) for item in node]
    return node


def _load_schema(schemas_dir: Path, index, url: str):
    entry = next(e for e in index if e["url"] == url)
    return _python_patterns(json.loads((schemas_dir / entry["path"]).read_text()))


def load_registry(schemas_dir: Path):
    from referencing import Registry, Resource

    index = json.loads((schemas_dir / "index.json").read_text())
    registry = Registry()
    for entry in index:
        data = (schemas_dir / entry["path"]).read_bytes()
        got = hashlib.sha256(data).hexdigest()
        require(got == entry["sha256"], f"schema hash mismatch for {entry['url']}")
        document = _python_patterns(json.loads(data))
        resource = Resource.from_contents(document)
        registry = registry.with_resource(uri=entry["url"], resource=resource)
    return registry, index


def cmd_setup(args: argparse.Namespace) -> None:
    """Copy the campaign schema closure into the worktree with verified hashes."""
    from importlib.metadata import version as package_version

    source = Path(args.campaign_schemas).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    index = json.loads((source / "index.json").read_text())
    for entry in index:
        data = (source / entry["path"]).read_bytes()
        got = hashlib.sha256(data).hexdigest()
        require(got == entry["sha256"], f"campaign schema hash mismatch for {entry['url']}")
        target = out_dir / entry["path"]
        if target.exists():
            target.chmod(0o644)
            target.unlink()
        shutil.copyfile(source / entry["path"], target)
        target.chmod(0o444)
    index_target = out_dir / "index.json"
    if index_target.exists():
        index_target.chmod(0o644)
        index_target.unlink()
    shutil.copyfile(source / "index.json", index_target)
    index_target.chmod(0o444)

    report = {
        "python": sys.version.split()[0],
        "jsonschema": package_version("jsonschema"),
        "referencing": package_version("referencing"),
        "schemaCount": len(index),
        "schemas": [
            {"url": entry["url"], "sha256": entry["sha256"], "file": entry["path"]}
            for entry in index
        ],
    }
    print(json.dumps(report, indent=2))


def parse_corpus(worktree: Path):
    import jsonschema

    resource_root = worktree / "test/resources/opds"
    manifest = json.loads((resource_root / MANIFEST_NAME).read_text())
    return resource_root, manifest


def cmd_validate(args: argparse.Namespace) -> None:
    import jsonschema
    from jsonschema import Draft7Validator

    worktree = Path(args.worktree).resolve()
    schemas_dir = Path(args.schemas).resolve()
    registry, index = load_registry(schemas_dir)
    feed_schema_doc = _load_schema(schemas_dir, index, FEED_SCHEMA_ID)
    link_schema_doc = _load_schema(schemas_dir, index, LINK_SCHEMA_ID)
    feed_validator = Draft7Validator(feed_schema_doc, registry=registry)
    link_validator = Draft7Validator(link_schema_doc, registry=registry)

    resource_root, manifest = parse_corpus(worktree)
    cases = []
    failed = False
    for row in manifest["feeds"]:
        path = resource_root / "feeds" / row["name"]
        got = digest(path)
        require(got == row["sha256"], f"corpus hash mismatch for {row['name']}")
        raw = path.read_text(encoding="utf-8")
        case = {
            "name": row["name"],
            "kind": row["kind"],
            "sha256": got,
            "note": row["note"],
        }
        try:
            instance = json.loads(raw)
        except json.JSONDecodeError as error:
            case["valid"] = False
            case["decodeError"] = str(error)
            case["expectedValid"] = False
            case["verdict"] = "pass" if row["kind"] == "negative" else "fail"
            if case["verdict"] == "fail":
                failed = True
            cases.append(case)
            continue

        validator = link_validator if row["kind"] == "link-positive" else feed_validator
        errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        case["valid"] = not errors
        case["errors"] = [
            {
                "message": error.message,
                "path": "/" + "/".join(str(p) for p in error.absolute_path),
            }
            for error in errors
        ]
        if row["kind"] == "positive":
            case["expectedValid"] = True
        elif row["kind"] == "link-positive":
            case["expectedValid"] = True
        elif row["kind"] == "negative":
            case["expectedValid"] = False
        else:  # normative-only: the schema must NOT enforce the rule
            case["expectedValid"] = True
            case["normativeRejectedByParser"] = True
        case["verdict"] = "pass" if case["valid"] == case["expectedValid"] else "fail"
        if case["verdict"] == "fail":
            failed = True
        cases.append(case)

    report = {
        "reference": "jsonschema Draft7 over the pinned OPDS/Readium closure (local Registry, no network)",
        "schemaIndexSha256": digest(schemas_dir / "index.json"),
        "schemaCount": len(index),
        "cases": cases,
        "status": "passed" if not failed else "failed",
    }
    out = Path(args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "cases": len(cases), "out": str(out)}))
    if failed:
        raise SystemExit(1)


def _lang_map(value):
    if isinstance(value, str):
        return {"und": value}
    if isinstance(value, dict):
        return {str(k): str(v) for k, v in sorted(value.items())}
    return None


def _norm_datetime(value):
    if not isinstance(value, str):
        return None
    from datetime import datetime, timezone

    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    parsed = parsed.astimezone(timezone.utc)
    return parsed.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _links_summary(links):
    rows = []
    for link in links or []:
        if not isinstance(link, dict):
            continue
        rel = link.get("rel")
        rels = [str(r) for r in rel] if isinstance(rel, list) else ([str(rel)] if rel else [])
        rows.append(
            {
                "rels": rels,
                "href": link.get("href"),
                "type": link.get("type"),
                "templated": bool(link.get("templated")),
            }
        )
    return rows


def _publications_summary(pubs):
    rows = []
    for pub in pubs or []:
        if not isinstance(pub, dict):
            continue
        meta = pub.get("metadata") or {}
        authors = meta.get("author") or []
        if not isinstance(authors, list):
            authors = [authors]
        author_names = []
        for author in authors:
            if isinstance(author, str):
                author_names.append(author)
            elif isinstance(author, dict) and isinstance(author.get("name"), str):
                author_names.append(author["name"])
        images = []
        for image in pub.get("images") or []:
            if not isinstance(image, dict):
                continue
            images.append(
                {
                    "href": image.get("href"),
                    "type": image.get("type"),
                    "width": image.get("width"),
                    "height": image.get("height"),
                }
            )
        languages = meta.get("language") or []
        if not isinstance(languages, list):
            languages = [languages]
        rows.append(
            {
                "title": _lang_map(meta.get("title")),
                "sortAs": _lang_map(meta.get("sortAs")),
                "subtitle": _lang_map(meta.get("subtitle")),
                "identifier": meta.get("identifier"),
                "languages": [str(l) for l in languages],
                "authors": author_names,
                "published": meta.get("published"),
                "modified": _norm_datetime(meta.get("modified")),
                "links": _links_summary(pub.get("links")),
                "images": images,
            }
        )
    return rows


def feed_summary(raw: dict) -> dict:
    meta = raw.get("metadata") or {}
    rel = raw.get("rel")
    self_link = None
    for link in raw.get("links") or []:
        if not isinstance(link, dict):
            continue
        value = link.get("rel")
        rels = value if isinstance(value, list) else ([value] if value else [])
        if "self" in rels:
            self_link = {"href": link.get("href"), "type": link.get("type")}
            break
    return {
        "metadata": {
            "title": _lang_map(meta.get("title")),
            "identifier": meta.get("identifier"),
            "modified": _norm_datetime(meta.get("modified")),
            "description": meta.get("description"),
            "numberOfItems": meta.get("numberOfItems"),
            "itemsPerPage": meta.get("itemsPerPage"),
            "currentPage": meta.get("currentPage"),
        },
        "self": self_link,
        "links": _links_summary(raw.get("links")),
        "navigation": [
            {
                "title": _lang_map(nav.get("title")),
                "href": nav.get("href"),
                "rels": [str(r) for r in nav["rel"]] if isinstance(nav.get("rel"), list) else (
                    [str(nav["rel"])] if nav.get("rel") else []
                ),
                "type": nav.get("type"),
            }
            for nav in raw.get("navigation") or []
            if isinstance(nav, dict)
        ],
        "facets": [
            {
                "title": _lang_map((facet.get("metadata") or {}).get("title")),
                "links": _links_summary(facet.get("links")),
            }
            for facet in raw.get("facets") or []
            if isinstance(facet, dict)
        ],
        "groups": [
            {
                "title": _lang_map((group.get("metadata") or {}).get("title")),
                "self": next(
                    (
                        link.get("href")
                        for link in group.get("links") or []
                        if isinstance(link, dict) and link.get("rel") == "self"
                    ),
                    None,
                ),
                "navigation": [
                    {"title": nav.get("title"), "href": nav.get("href")}
                    for nav in group.get("navigation") or []
                    if isinstance(nav, dict)
                ],
                "publications": _publications_summary(group.get("publications")),
            }
            for group in raw.get("groups") or []
            if isinstance(group, dict)
        ],
        "publications": _publications_summary(raw.get("publications")),
        "subcollections": [
            {
                "key": key,
                "title": (value.get("metadata") or {}).get("title"),
                "linksCount": len(value.get("links") or []),
            }
            for key, value in sorted(raw.items())
            if key not in ("metadata", "links", "publications", "navigation", "facets", "groups")
            and isinstance(value, dict)
            and isinstance(value.get("links"), list)
        ],
    }


ACQUISITION_RELS = {
    "acquisition",
    "borrow",
    "buy",
    "preview",
    "sample",
    "subscribe",
    "http://opds-spec.org/acquisition",
    "http://opds-spec.org/acquisition/buy",
    "http://opds-spec.org/acquisition/open-access",
    "http://opds-spec.org/acquisition/borrow",
    "http://opds-spec.org/acquisition/sample",
    "http://opds-spec.org/acquisition/subscribe",
}


def all_rels(raw: dict):
    rels = set()

    def collect(links):
        for link in links or []:
            if not isinstance(link, dict):
                continue
            value = link.get("rel")
            if isinstance(value, str):
                rels.add(value)
            elif isinstance(value, list):
                rels.update(str(r) for r in value)

    def walk(node):
        if not isinstance(node, dict):
            return
        collect(node.get("links"))
        for key in ("publications", "navigation"):
            for child in node.get(key) or []:
                walk(child)
        for child in node.get("groups") or []:
            walk(child)
        for facet in node.get("facets") or []:
            collect(facet.get("links"))

    walk(raw)
    return rels


def acquisition_rels_summary(raw: dict):
    return sorted(rel for rel in all_rels(raw) if rel in ACQUISITION_RELS)


def resolution_cases(worktree: Path):
    """Independent URI-resolution expectations via urllib urljoin (RFC 3986)."""
    resource_root, manifest = parse_corpus(worktree)
    cases = []
    for row in manifest["feeds"]:
        if row["kind"] not in ("positive", "normative-only"):
            continue
        path = resource_root / "feeds" / row["name"]
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        base = next(
            (
                link.get("href")
                for link in raw.get("links") or []
                if isinstance(link, dict) and link.get("rel") == "self" and link.get("href")
            ),
            None,
        )
        if not base:
            continue
        for nav in raw.get("navigation") or []:
            href = nav.get("href") if isinstance(nav, dict) else None
            if href and not urlsplit(href).scheme:
                cases.append(
                    {"base": base, "relative": href, "expected": urljoin(base, href)}
                )
    manual = [
        (
            "https://catalog.example/opds/%C3%ADndice?lang=pt#top",
            "/opds/page/2?cursor=%E5%86%AC&order=desc#results",
        ),
        ("https://catalog.example/opds/%C3%ADndice?lang=pt#top", "#shelf"),
        ("https://catalog.example/opds/%C3%ADndice?lang=pt#top", "?x=1"),
        ("https://catalog.example/opds/a/b/c", "s%20p/../d"),
        ("https://catalog.example/opds/root", "//other.example/p"),
        ("https://catalog.example/opds/root", "mailto:catalog@example.org"),
        ("https://catalog.example/opds/root", "http://absolute.example/p?q=1#f"),
    ]
    # The expected value always comes from the reference resolver so the
    # pinned file cannot drift from it.
    cases.extend(
        {"base": base, "relative": relative, "expected": urljoin(base, relative)}
        for base, relative in manual
    )
    return cases


def cmd_expected(args: argparse.Namespace) -> None:
    worktree = Path(args.worktree).resolve()
    resource_root, manifest = parse_corpus(worktree)
    expected_dir = resource_root / "expected"
    generated = {}
    for row in manifest["feeds"]:
        if row["kind"] != "positive":
            continue
        path = resource_root / "feeds" / row["name"]
        raw = json.loads(path.read_text(encoding="utf-8"))
        summary = feed_summary(raw)
        summary["feed"] = row["name"]
        summary["acquisitionRels"] = acquisition_rels_summary(raw)
        generated[f"{row['name']}.expected.json"] = summary
    generated["resolution.json"] = {"cases": resolution_cases(worktree)}

    if args.write:
        expected_dir.mkdir(parents=True, exist_ok=True)
        for name, payload in sorted(generated.items()):
            target = expected_dir / name
            target.write_text(
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
        print(f"wrote {len(generated)} expectation files to {expected_dir}")
        return

    require(expected_dir.is_dir(), f"missing {expected_dir}; run with --write first")
    mismatched = []
    for name, payload in sorted(generated.items()):
        target = expected_dir / name
        if not target.is_file():
            mismatched.append(f"missing {name}")
            continue
        wanted = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
        if target.read_text(encoding="utf-8") != wanted:
            mismatched.append(f"stale {name}")
    extra = sorted(
        p.name for p in expected_dir.glob("*.json") if p.name not in generated
    )
    mismatched.extend(f"unexpected {name}" for name in extra)
    if mismatched:
        raise SystemExit("expectation drift:\n  " + "\n  ".join(sorted(set(mismatched))))
    print(f"expectation files match ({len(generated)} files)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    setup = sub.add_parser("setup", help="copy pinned schemas with verified hashes and print versions")
    setup.add_argument("--campaign-schemas", required=True)
    setup.add_argument("--out-dir", required=True)
    setup.set_defaults(func=cmd_setup)

    validate = sub.add_parser("validate", help="run the schema reference over the corpus")
    validate.add_argument("--worktree", required=True)
    validate.add_argument("--schemas", required=True)
    validate.add_argument("--out", required=True)
    validate.set_defaults(func=cmd_validate)

    expected = sub.add_parser("expected", help="regenerate or check expectation files")
    expected.add_argument("--worktree", required=True)
    mode = expected.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    expected.set_defaults(func=cmd_expected)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
