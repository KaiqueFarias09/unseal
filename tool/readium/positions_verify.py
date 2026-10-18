#!/usr/bin/env python3
"""D01 independent position-list verifier.

Recomputes the expected Readium position list from the evidence the Dart
comparator exports — per-occurrence canonical texts, the book container —
and compares it against the generated list. The verifier never imports
Dart logic: anchor density (first position of each occurrence, then every
1024 Unicode scalars), the progression formulas, the one-based contiguous
indexing, the total, and the href sequence are all derived here, in
Python, from the raw inputs.

For EPUB the expected href sequence is read from the container itself
(zipfile -> META-INF/container.xml -> OPF spine), not from the evidence.
For comics the expected page sequence is the archive listing under the
verifier's own natural sort. For PDFs the page count is cross-checked
against the /Count of the document's page tree.

This tool is a project contract (doc/readium-locators.md). No official
Readium position-list schema exists (the official path returned 404);
this verifier is never presented as an official artifact.

Usage:
  positions_verify.py --list <positions.json> --evidence <evidence.json>
                      --book <book file> [--report <report.json>]
"""
import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

PROFILE_INTERVAL = 1024


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).digest().hex()


def utf16_offset_of_scalar_index(text: str, scalar_index: int) -> int:
    """The UTF-16 code-unit offset of the scalar at zero-based
    scalar_index: astral scalars occupy two code units."""
    offset = 0
    seen = 0
    for char in text:
        if seen == scalar_index:
            break
        offset += 2 if ord(char) > 0xFFFF else 1
        seen += 1
    return offset


def expected_anchors(text: str) -> list[int]:
    """UTF-16 offsets of the profile anchors: scalar index 0 (the
    occurrence's first position), then every 1024th scalar strictly below
    the end. Astral pairs never split: the anchor sits at the pair's own
    offset."""
    if not text:
        return [0]
    offsets = [0]
    scalar = PROFILE_INTERVAL
    length = len(text)
    while scalar < length:
        offsets.append(utf16_offset_of_scalar_index(text, scalar))
        scalar += PROFILE_INTERVAL
    return offsets


def epub_spine_paths(book: Path) -> list[str]:
    """The spine resource paths read from the EPUB container itself."""
    with zipfile.ZipFile(book) as archive:
        container = archive.read("META-INF/container.xml").decode("utf-8")
        rootfile = re.search(r'full-path="([^"]+)"', container)
        if rootfile is None:
            raise ValueError("container.xml names no rootfile")
        opf = archive.read(rootfile.group(1)).decode("utf-8")
        opf_dir = rootfile.group(1).rsplit("/", 1)[0] if "/" in rootfile.group(1) else ""
        items = {
            match.group(1): match.group(2)
            for match in re.finditer(
                r'<item\b[^>]*\bid="([^"]+)"[^>]*\bhref="([^"]+)"', opf
            )
        }
        # Attribute order varies; run a second pass for href-before-id.
        for match in re.finditer(
            r'<item\b[^>]*\bhref="([^"]+)"[^>]*\bid="([^"]+)"', opf
        ):
            items.setdefault(match.group(2), match.group(1))

        spine = re.search(r"<spine\b.*?</spine>", opf, re.S)
        if spine is None:
            raise ValueError("OPF has no spine")
        paths = []
        for idref in re.finditer(r'<itemref\b[^>]*\bidref="([^"]+)"', spine.group(0)):
            href = items.get(idref.group(1))
            if href is None:
                raise ValueError(f"spine idref {idref.group(1)} has no manifest item")
            # OPF hrefs resolve against the OPF directory; Unseal reports
            # the parser's exact path, so compare in that space.
            combined = f"{opf_dir}/{href}" if opf_dir else href
            paths.append(combined)
        return paths


def comic_page_paths(book: Path) -> list[str]:
    """The archive's image entries under this verifier's own natural
    sort (basename digits compared numerically, path as tiebreaker)."""
    def natural_key(name: str):
        base = name.rsplit("/", 1)[-1]
        parts = re.split(r"(\d+)", base)

        return (
            [int(part) if part.isdigit() else part.lower() for part in parts],
            name,
        )

    with zipfile.ZipFile(book) as archive:
        image_extensions = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}
        pages = [
            name
            for name in archive.namelist()
            if not name.endswith("/")
            and Path(name).suffix.lower() in image_extensions
        ]
    return sorted(pages, key=natural_key)


def pdf_page_count(book: Path) -> int:
    """The page tree's /Count, read from the raw bytes. Generated PDFs
    with plain xref tables expose it directly; encrypted or object-stream
    documents cannot be verified this way and the check reports that."""
    data = book.read_bytes()
    if data.startswith(b"%PDF-1.") or data.startswith(b"%PDF-2."):
        counts = re.findall(rb"/Type\s*/Pages[^>]*?/Count\s+(\d+)", data, re.S)
        counts += re.findall(rb"/Count\s+(\d+)[^>]*?/Type\s*/Pages", data, re.S)
        if counts:
            return max(int(value) for value in counts)
    raise ValueError("page tree /Count not readable from raw bytes")


def verify(list_path: Path, evidence: dict, book: Path) -> tuple[dict, bool]:
    payload = json.loads(list_path.read_text())
    problems: list[str] = []
    total = payload.get("total")
    positions = payload.get("positions")
    if not isinstance(total, int) or not isinstance(positions, list):
        return {"error": "list is not a position-list service document"}, False
    if total != len(positions):
        problems.append(f"total {total} != {len(positions)} entries")

    occurrences = evidence["occurrences"]
    interval = evidence.get("profile", {}).get("scalarInterval", PROFILE_INTERVAL)
    if interval != PROFILE_INTERVAL:
        problems.append(f"unexpected profile interval {interval}")

    # Independent href sequence per book kind.
    kind = evidence["book"]["kind"]
    if kind == "epub":
        spine = epub_spine_paths(book)
        evidence_paths = [entry["resourcePath"] for entry in occurrences]
        if spine != evidence_paths:
            problems.append(
                "evidence occurrence paths diverge from the container spine:\n"
                f"  spine:    {spine}\n  evidence: {evidence_paths}"
            )
        expected_hrefs = spine
    elif kind == "comic":
        expected_hrefs = comic_page_paths(book)
        evidence_paths = [entry["resourcePath"] for entry in occurrences]
        if expected_hrefs != evidence_paths:
            problems.append(
                "evidence occurrence paths diverge from the archive pages:\n"
                f"  archive:  {expected_hrefs}\n  evidence: {evidence_paths}"
            )
    elif kind == "pdf":
        declared = pdf_page_count(book)
        if declared != len(occurrences):
            problems.append(
                f"PDF /Count {declared} != {len(occurrences)} occurrences"
            )
        expected_hrefs = [entry["resourcePath"] for entry in occurrences]
    else:
        return {"error": f"unknown book kind {kind}"}, False

    # Recompute the full expected list from the evidence texts.
    expected: list[dict] = []
    text_before = 0
    text_total = sum(
        len(entry.get("text", "")) if entry.get("isHtml", True) else 0
        for entry in occurrences
    )
    for index, entry in enumerate(occurrences):
        href = expected_hrefs[index] if index < len(expected_hrefs) else entry["resourcePath"]
        page_based = kind in ("comic", "pdf") or not entry.get("isHtml", True)
        if page_based:
            expected.append(
                {
                    "href": href,
                    "position": len(expected) + 1,
                    "progression": 0.0,
                    "totalProgression": index / len(occurrences),
                    "occurrence": index,
                }
            )
            continue
        text = entry.get("text", "")
        length_utf16 = len(text.encode("utf-16-le")) // 2
        if length_utf16 != entry.get("textUtf16Length"):
            problems.append(
                f"occurrence {index} declared length "
                f"{entry.get('textUtf16Length')} != verifier length {length_utf16}"
            )
        for offset in expected_anchors(text):
            expected.append(
                {
                    "href": href,
                    "position": len(expected) + 1,
                    "progression": (offset / length_utf16) if length_utf16 else 0.0,
                    "totalProgression": ((text_before + offset) / text_total)
                    if text_total
                    else 0.0,
                    "occurrence": index,
                }
            )
        text_before += length_utf16

    if len(expected) != total:
        problems.append(
            f"verifier expects {len(expected)} positions, list declares {total}"
        )

    occurrences_seen: list[int] = []
    for index, (actual, wanted) in enumerate(zip(positions, expected)):
        locations = actual.get("locations", {})
        if actual.get("href") != wanted["href"]:
            problems.append(
                f"position {index + 1}: href {actual.get('href')!r} != {wanted['href']!r}"
            )
        if locations.get("position") != wanted["position"]:
            problems.append(
                f"position {index + 1}: locations.position "
                f"{locations.get('position')} != {wanted['position']}"
            )
        for field in ("progression", "totalProgression"):
            actual_value = locations.get(field)
            wanted_value = wanted[field]
            if actual_value is None or abs(actual_value - wanted_value) > 0:
                problems.append(
                    f"position {index + 1}: {field} {actual_value!r} != "
                    f"{wanted_value!r} (exact double equality expected)"
                )
        occurrences_seen.append(wanted["occurrence"])

    # Positions must group by occurrence in reading order.
    grouped = [occurrences_seen[0]] if occurrences_seen else []
    for occurrence in occurrences_seen:
        if occurrence != grouped[-1]:
            grouped.append(occurrence)
    if grouped != sorted(set(occurrences_seen), key=occurrences_seen.index):
        problems.append(f"positions do not group by occurrence: {grouped}")

    report = {
        "verifier": "tool/readium/positions_verify.py (independent)",
        "listSha256": sha256(list_path),
        "bookSha256": sha256(book),
        "bookKind": kind,
        "profileInterval": interval,
        "declaredTotal": total,
        "verifiedPositions": len(expected),
        "problems": problems,
        "status": "pass" if not problems else "fail",
    }
    return report, not problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--book", required=True)
    parser.add_argument("--report")
    arguments = parser.parse_args()

    list_path = Path(arguments.list)
    book = Path(arguments.book)
    evidence = json.loads(Path(arguments.evidence).read_text())

    report, ok = verify(list_path, evidence, book)
    if arguments.report:
        Path(arguments.report).write_text(json.dumps(report, indent=2) + "\n")

    print(
        f"positions_verify: {report.get('status', 'error')} "
        f"({report.get('verifiedPositions', 0)} positions recomputed, "
        f"{len(report.get('problems', []))} problems)"
    )
    for problem in report.get("problems", []):
        print(f"  - {problem}")
    for line in report.get("error", "").splitlines():
        print(f"  ! {line}")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
