#!/usr/bin/env python3
"""D02 reference runner: executes Tesseract 5.5.3 over the licensed images
so hOCR and TSV come from one recognition pass each, verifies every pinned
input, checks that the committed Tesseract fixtures are byte-identical to
the fresh outputs, extracts the independent lxml records for every corpus
document, normalizes the TSV under the contract in doc/hocr.md, and writes
the reference artifacts the oracle gate consumes:

  <root>/images/            copies of the pinned images (Tesseract's cwd)
  <root>/tesseract/<name>.hocr|.tsv|.log   fresh outputs and logs
  <root>/records/<name>.records.json       lxml records per corpus document
  <root>/records/<name>.tsv.json           normalized TSV per Tesseract run
  <root>/outputs/reference.json            pins, argv, exit codes, hashes
"""

import argparse
import csv
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from lxml import etree

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "reference" / "hocr"))
import extract_hocr  # noqa: E402

PINS = json.loads((HERE / "reference" / "hocr" / "corpus-sha256.json").read_text())
PROJECT = HERE.parent

ARGUMENTS = argparse.ArgumentParser(description=__doc__)
ARGUMENTS.add_argument("--root", type=Path, default=Path("build/d02"))
ARGUMENTS.add_argument("--tesseract", default="/opt/homebrew/bin/tesseract")
ARGUMENTS.add_argument("--tiffcp", default="/opt/homebrew/bin/tiffcp")
ARGS = ARGUMENTS.parse_args()
ROOT = ARGS.root.resolve()
IMAGES = ROOT / "images"
TESSERACT_OUT = ROOT / "tesseract"
RECORDS = ROOT / "records"
OUT = ROOT / "outputs"

# One recognition pass per image, hOCR and TSV requested together.
RUNS = [
    ("phototest", "phototest.tif"),
    ("eurotext", "eurotext.tif"),
    ("unlv-8071", "unlv-8071_093.3B.tif"),
    ("unlv-8087", "unlv-8087_054.3B.tif"),
    ("multipage", "multipage.tif"),
]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        sys.exit(f"reference: {message}")


def run(argv, cwd, log):
    started = time.monotonic()
    with log.open("wb") as stream:
        process = subprocess.run(argv, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
    return {
        "argv": [str(a) for a in argv],
        "cwd": str(cwd),
        "exitCode": process.returncode,
        "durationSeconds": round(time.monotonic() - started, 3),
        "log": str(log),
        "logSha256": sha256(log),
    }


def normalize_tsv(path):
    """The TSV side of the comparison contract: per page, document-order
    lists of text-bearing words/lines/paragraphs/blocks with exact boxes
    and the truncated word confidence; whitespace-only word rows are
    placeholders and are counted, not joined."""
    rows = list(csv.reader(path.open(encoding="utf-8", newline=""), delimiter="\t"))
    header, body = rows[0], rows[1:]
    require(header[:12] == ["level", "page_num", "block_num", "par_num", "line_num", "word_num", "left", "top", "width", "height", "conf", "text"], "unexpected TSV header")
    pages = {}
    placeholders = 0
    for row in body:
        level, page = row[0], row[1]
        record = pages.setdefault(page, {"page": int(page), "width": None, "height": None, "blocks": [], "paragraphs": [], "lines": [], "words": [], "seenBlocks": set(), "seenParagraphs": set(), "seenLines": set(), "rows": {}})
        left, top, width, height = (int(row[i]) for i in (6, 7, 8, 9))
        box = [left, top, left + width, top + height]
        key = tuple(row[1:6])
        record["rows"][(level, key[:1] if level == "1" else key[: int(level)])] = box
        if level == "1":
            record["width"], record["height"] = width, height
        if level != "5":
            continue
        text = row[11] if len(row) > 11 else ""
        if text.strip() == "":
            placeholders += 1
            continue
        conf = float(row[10])
        record["words"].append({"text": text, "bbox": box, "conf": int(conf), "confRaw": row[10]})
        for level_name, depth, seen_key in (("blocks", 2, "seenBlocks"), ("paragraphs", 3, "seenParagraphs"), ("lines", 4, "seenLines")):
            owner = key[:depth]
            if owner not in record[seen_key]:
                record[seen_key].add(owner)
                record[level_name].append({"bbox": record["rows"][(str(depth), owner)]})
    result = []
    for page in sorted(pages, key=int):
        record = pages[page]
        result.append({k: v for k, v in record.items() if k not in ("seenBlocks", "seenParagraphs", "seenLines", "rows")})
    return {"pages": result, "placeholderRows": placeholders}


def main():
    for folder in (IMAGES, TESSERACT_OUT, RECORDS, OUT):
        folder.mkdir(parents=True, exist_ok=True)
    report = {
        "mission": "D02",
        "python": platform.python_version(),
        "lxml": list(etree.LXML_VERSION),
        "libxml2": list(etree.LIBXML_VERSION),
        "pins": {"tesseract": PINS["tesseract"], "lxml": PINS["lxml"], "spec": PINS["spec"]},
        "inputs": {},
        "commands": [],
        "outputs": {},
        "fixtures": {},
        "records": {},
    }

    # Tesseract identity before anything runs.
    banner = subprocess.run([ARGS.tesseract, "--version"], capture_output=True, text=True)
    lines = (banner.stdout + banner.stderr).splitlines()
    require(lines and lines[0].strip() == PINS["tesseract"]["banner"], f"tesseract banner {lines[:1]!r}")
    model = Path(PINS["tesseract"]["model"])
    require(model.is_file() and sha256(model) == PINS["tesseract"]["modelSha256"], "eng.traineddata pin")
    report["tesseractBanner"] = lines[:4]

    # Pinned images, copied so Tesseract records bare file names.
    for name, pin in PINS["images"].items():
        source = PROJECT / pin["path"]
        require(source.is_file() and sha256(source) == pin["sha256"], f"image pin {name}")
        shutil.copyfile(source, IMAGES / name)
        report["inputs"][name] = {"path": pin["path"], "sha256": pin["sha256"], "license": pin["license"], "source": pin["source"]}
    log = TESSERACT_OUT / "tiffcp.log"
    report["commands"].append(run([ARGS.tiffcp, "phototest.tif", "eurotext.tif", "multipage.tif"], IMAGES, log))
    require(report["commands"][-1]["exitCode"] == 0, "tiffcp failed")
    report["inputs"]["multipage.tif"] = {"derivedFrom": ["phototest.tif", "eurotext.tif"], "sha256": sha256(IMAGES / "multipage.tif")}

    # One execution per image; hOCR and TSV from the same pass.
    for name, image in RUNS:
        argv = [ARGS.tesseract, image, str(TESSERACT_OUT / name), "-c", "tessedit_create_hocr=1", "-c", "tessedit_create_tsv=1"]
        record = run(argv, IMAGES, TESSERACT_OUT / f"{name}.log")
        report["commands"].append(record)
        require(record["exitCode"] == 0, f"tesseract {name} exit {record['exitCode']}")
        for ext in ("hocr", "tsv"):
            produced = TESSERACT_OUT / f"{name}.{ext}"
            require(produced.is_file() and produced.stat().st_size > 0, f"{name}.{ext} missing or empty")
            digest = sha256(produced)
            report["outputs"][f"{name}.{ext}"] = {"path": str(produced), "bytes": produced.stat().st_size, "sha256": digest}
            fixture = PROJECT / "test" / "resources" / "hocr" / "tesseract" / f"{name}.{ext}"
            committed = sha256(fixture) if fixture.is_file() else None
            report["fixtures"][f"{name}.{ext}"] = {"path": str(fixture.relative_to(PROJECT)), "sha256": committed, "matchesFreshOutput": committed == digest}
            require(committed == digest, f"committed fixture {fixture.name} differs from the fresh Tesseract output")
        tsv = normalize_tsv(TESSERACT_OUT / f"{name}.tsv")
        (RECORDS / f"{name}.tsv.json").write_text(json.dumps(tsv, ensure_ascii=False, indent=1) + "\n")
        hocr_words = sum(sum(1 for e in page["elements"] if e["role"] == "word") for page in extract_hocr.extract((TESSERACT_OUT / f"{name}.hocr").read_bytes())["pages"])
        tsv_words = sum(len(p["words"]) for p in tsv["pages"])
        require(hocr_words > 0 and hocr_words == tsv_words, f"{name}: {hocr_words} hOCR words vs {tsv_words} TSV words")
        report["records"][f"{name}.tsv"] = {"path": str(RECORDS / f"{name}.tsv.json"), "pages": len(tsv["pages"]), "words": tsv_words, "placeholderRows": tsv["placeholderRows"]}

    # Independent lxml records for every corpus document.
    corpus = {f"tesseract/{name}.hocr": TESSERACT_OUT / f"{name}.hocr" for name, _ in RUNS}
    for group in ("external", "derived"):
        for name, pin in PINS[group].items():
            source = PROJECT / pin["path"]
            require(source.is_file() and sha256(source) == pin["sha256"], f"{group} pin {name}")
            corpus[f"{group}/{name}"] = source
            report["inputs"][f"{group}/{name}"] = {"path": pin["path"], "sha256": pin["sha256"], "license": pin.get("license"), "producer": pin.get("producer"), "source": pin.get("source")}
    for key, path in corpus.items():
        records = extract_hocr.extract(path.read_bytes())
        target = RECORDS / (key.replace("/", "__") + ".records.json")
        target.write_text(json.dumps(records, ensure_ascii=False, indent=1) + "\n")
        words = sum(sum(1 for e in page["elements"] if e["role"] == "word") for page in records["pages"])
        lines_ = sum(sum(1 for e in page["elements"] if e["role"] == "line") for page in records["pages"])
        report["records"][key] = {"path": str(target), "sha256": sha256(target), "pages": len(records["pages"]), "lines": lines_, "words": words, "sourceSha256": sha256(path)}

    (OUT / "reference.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n")
    print(f"reference ok: {len(RUNS)} tesseract runs, {len(corpus)} documents extracted -> {OUT / 'reference.json'}")


if __name__ == "__main__":
    main()
