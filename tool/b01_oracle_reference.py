#!/usr/bin/env python3
"""Produce every B01 reference artifact into one directory.

Stages, in order, all under <output-dir>:

1. ``inputs/`` — byte-verified read-only copies of the DjVu fixtures and
   the pinned ALTO files (hashes checked against test/resources).
2. ``djvu/<fixture>.pages/`` — per-page ``djvused print-txt`` and
   ``print-pure-txt`` dumps via ``tool/djvu_oracle_dump.py``.
3. ``alto-ref/<name>.json`` — stdlib content extraction via
   ``tool/alto_reference_dump.py``.
4. ``alto-validation.log`` — ``xmllint --schema`` runs: both committed
   ALTO fixtures against the pinned ALTO 3.1 schema, one officially
   sampled v4 document against the pinned 4.4 schema, one officially
   sampled v2 document against the pinned 2.1 schema, and the declared
   malformed rejections (a mutated fixture and a wrong namespace) which
   must FAIL validation here exactly as Unseal rejects them.

Everything is written fresh per run; a manifest with hashes lands in
``manifest.json``. Usage: b01_oracle_reference.py <output-dir>
"""

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

FIXTURES = [
    "goody-twoshoes",
    "cyrillic",
    "speller-1921",
    "cable-1973",
    "spec-bundled",
]

ALTO_FIXTURES = ["goody-page2-tesseract", "cyrillic-page1-tesseract"]

# The official community samples validate against their own pinned major
# schema; both live outside the repository (documentation-only use).
OFFICIAL_V4 = (
    "official4-Glyph_Sample01_General.xml",
    "https://raw.githubusercontent.com/altoxml/documentation/master/v4/GlyphSamples/Glyph_Sample01_General.xml",
)
OFFICIAL_V2 = (
    "official-v2-NPsample.xml",
    "https://raw.githubusercontent.com/altoxml/documentation/master/v3/Glyph/NPsample.xml",
)

CATALOG = """<?xml version="1.0"?>
<!DOCTYPE catalog PUBLIC "-//OASIS//DTD XML Catalogs V1.0//EN" "http://www.oasis-open.org/committees/entity/release/1.0/catalog.dtd">
<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">
  <uri name="http://www.loc.gov/standards/xlink/xlink.xsd" uri="xlink.xsd"/>
  <uri name="http://www.w3.org/2001/xml.xsd" uri="xml.xsd"/>
</catalog>
"""

MALFORMED_MUTATION = ("malformed-namespace.xml", "ns-v3#", "ns-v9#")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv: list[str], env: dict[str, str] | None = None) -> tuple[int, bytes]:
    result = subprocess.run(argv, capture_output=True, env=env)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    oracle = out / "oracle"
    oracle.mkdir(exist_ok=True)
    artifacts: list[dict[str, object]] = []
    problems: list[str] = []

    # --- schemas and catalog (pinned, from the worktree build dir or fetched) ---
    xsd_dir = out / "xsd"
    xsd_dir.mkdir(exist_ok=True)
    schema_sources = {
        "alto-3-1.xsd": "https://raw.githubusercontent.com/altoxml/schema/master/v3/alto-3-1.xsd",
        "alto-2-1.xsd": "https://raw.githubusercontent.com/altoxml/schema/master/v2/alto-2-1.xsd",
        "alto-4-4.xsd": "https://raw.githubusercontent.com/altoxml/schema/master/v4/alto-4-4.xsd",
    }
    for name, url in schema_sources.items():
        target = xsd_dir / name
        if not target.exists():
            code, output = run(["curl", "-sL", "--max-time", "60", "-o", str(target), url])
            if code != 0 or not target.exists() or target.stat().st_size < 1000:
                problems.append(f"schema fetch failed: {name}")
                continue
        artifacts.append({"path": str(target), "sha256": sha256(target)})
    (xsd_dir / "xlink.xsd").write_bytes(
        subprocess.run(
            [
                "curl",
                "-sL",
                "--max-time",
                "90",
                "https://web.archive.org/web/2024id_/https://www.loc.gov/standards/xlink/xlink.xsd",
            ],
            capture_output=True,
        ).stdout
    )
    (xsd_dir / "xml.xsd").write_bytes(
        subprocess.run(["curl", "-sL", "--max-time", "60", "https://www.w3.org/2001/xml.xsd"], capture_output=True).stdout
    )
    (xsd_dir / "catalog.xml").write_text(CATALOG)
    for extra in ("xlink.xsd", "xml.xsd", "catalog.xml"):
        artifacts.append({"path": str(xsd_dir / extra), "sha256": sha256(xsd_dir / extra)})

    def xmllint(schema: Path, document: Path) -> tuple[int, bytes]:
        import os

        env = dict(os.environ)
        env["XML_CATALOG_FILES"] = str(xsd_dir / "catalog.xml")
        return run(
            [
                "xmllint",
                "--noout",
                "--nonet",
                "--schema",
                str(schema),
                str(document),
            ],
            env=env,
        )

    # --- 1. verified read-only input copies ---
    inputs = out / "inputs"
    inputs.mkdir(exist_ok=True)

    def stage_input(source: Path) -> Path:
        # Earlier runs leave the copies read-only; replace them instead
        # of writing over them.
        target = inputs / source.name
        if target.exists():
            target.chmod(0o644)
        shutil.copyfile(source, target)
        if sha256(source) != sha256(target):
            problems.append(f"input copy hash mismatch: {source}")
        target.chmod(0o444)
        artifacts.append({"path": str(target), "sha256": sha256(target)})

        return target

    for fixture in FIXTURES:
        stage_input(Path("test/resources/djvu") / f"{fixture}.djvu")
    for name in ALTO_FIXTURES:
        stage_input(Path("test/resources/alto") / f"{name}.xml")

    # --- 2. DjVuLibre per-page dumps ---
    djvu_out = out / "djvu"
    djvu_out.mkdir(exist_ok=True)
    for fixture in FIXTURES:
        book = inputs / f"{fixture}.djvu"
        dump_dir = djvu_out / fixture
        code, output = run(
            [sys.executable, "tool/djvu_oracle_dump.py", str(book), str(dump_dir)]
        )
        log = djvu_out / f"{fixture}.dump.log"
        log.write_bytes(output)
        if code != 0:
            problems.append(f"djvused dump failed for {fixture}: exit {code}")
            continue
        manifest = json.loads((dump_dir / "manifest.json").read_text())
        for page in manifest["pages"]:
            artifacts.append(
                {"path": str(dump_dir / page["file"]), "sha256": page["sha256"]}
            )
        artifacts.append({"path": str(log), "sha256": sha256(log)})

    # --- 3. stdlib ALTO content dumps ---
    alto_out = out / "alto-ref"
    alto_out.mkdir(exist_ok=True)
    for name in ALTO_FIXTURES:
        xml = inputs / f"{name}.xml"
        target = alto_out / f"{name}.json"
        code, output = run(
            [sys.executable, "tool/alto_reference_dump.py", str(xml), str(target)]
        )
        if code != 0:
            problems.append(f"alto reference dump failed for {name}: exit {code}")
            continue
        artifacts.append({"path": str(target), "sha256": sha256(target)})

    # --- 4. xmllint schema validations ---
    alto31 = xsd_dir / "alto-3-1.xsd"
    validation_log = out / "alto-validation.log"
    lines = []
    for name in ALTO_FIXTURES:
        code, output = xmllint(alto31, inputs / f"{name}.xml")
        lines.append(f"validates {name}: exit {code}\n{output.decode('utf-8', 'replace')}")
        if code != 0:
            problems.append(f"committed ALTO {name} fails schema validation")
    for name, url in (OFFICIAL_V4, OFFICIAL_V2):
        target = inputs / name
        if target.exists():
            target.chmod(0o644)
        if not target.exists():
            code, output = run(["curl", "-sL", "--max-time", "60", "-o", str(target), url])
            if code != 0 or not target.exists() or target.stat().st_size < 1000:
                problems.append(f"official sample fetch failed: {name}")
                continue
            target.chmod(0o444)
        schema = xsd_dir / ("alto-4-4.xsd" if "v4" in name or "official4" in name else "alto-2-1.xsd")
        code, output = xmllint(schema, target)
        lines.append(f"validates {name} against {schema.name}: exit {code}\n{output.decode('utf-8', 'replace')}")
        if code != 0:
            problems.append(f"official sample {name} fails its pinned schema")
    # Declared malformed rejections: a mutated fixture and a wrong
    # namespace must fail validation here, exactly as Unseal rejects them.
    for target_name, mutation in (("goody-page2-tesseract.xml", MALFORMED_MUTATION),):
        xml = (inputs / target_name).read_text()
        malformed = inputs / mutation[0]
        if malformed.exists():
            malformed.chmod(0o644)
        malformed.write_text(xml.replace(mutation[1], mutation[2]))
        malformed.chmod(0o444)
        code, output = xmllint(alto31, malformed)
        lines.append(f"rejects {mutation[0]}: exit {code}\n{output.decode('utf-8', 'replace')}")
        if code == 0:
            problems.append("malformed ALTO unexpectedly validates")
    validation_log.write_text("\n".join(lines) + "\n")
    artifacts.append({"path": str(validation_log), "sha256": sha256(validation_log)})

    manifest = {
        "tool": "b01_oracle_reference",
        "artifacts": artifacts,
        "problems": problems,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print(f"reference artifacts: {len(artifacts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
