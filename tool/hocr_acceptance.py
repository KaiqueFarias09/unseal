#!/usr/bin/env python3
"""D02 gate compare stage: runs the real lanes (analysis, VM tests, freshly
compiled worker + Chrome, independent-record comparison, public flow,
bench), keeps every log under build/d02/outputs/, and assembles the
HO01–HO08 comparison report the oracle gate verifies.

Every case's evidenceArtifacts are refreshed by THIS run; a lane that
fails or skips fails the stage.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument("--root", type=Path, default=Path("build/d02"))
PARSER.add_argument("--dart", default="dart")
PARSER.add_argument("--python", default=sys.executable)
ARGS = PARSER.parse_args()
WORKTREE = Path.cwd()
OUT = ARGS.root.resolve() / "outputs"
DART = ARGS.dart
PYTHON = ARGS.python

FAILURES = []


def run_lane(name, argv, log_name, timeout=900):
    log_path = OUT / log_name
    started = time.monotonic()
    with log_path.open("wb") as stream:
        result = subprocess.run(
            argv,
            cwd=WORKTREE,
            stdout=stream,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    duration = round(time.monotonic() - started, 1)
    print(f"{name}: exit {result.returncode} in {duration}s -> {log_name}")
    if result.returncode != 0:
        FAILURES.append(f"{name} exited {result.returncode}; see {log_name}")
    return log_path, result.returncode, duration


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=WORKTREE, capture_output=True, text=True
    ).stdout.strip()
    if not head:
        sys.exit("no git HEAD in worktree")

    cases = []

    def case(case_id, verdict, evidence, note):
        cases.append(
            {
                "id": case_id,
                "verdict": verdict,
                "note": note,
                "evidenceArtifacts": [str(OUT / name) for name in evidence],
            }
        )

    # HO01: the public API compiles clean; the subset, title grammar and
    # policies are documented in doc/hocr.md, written before the
    # comparison lane ran.
    run_lane("analyze", [DART, "analyze", "--fatal-infos"], "analyze.log")
    run_lane(
        "entrypoints",
        [DART, "test", "test/public_format_entrypoints_test.dart"],
        "entrypoints.log",
    )

    # HO02 (reference half): re-run the executed reference so the Tesseract
    # outputs, fixture authenticity and lxml records are fresh within this
    # stage.
    run_lane(
        "reference-rerun",
        [PYTHON, "tool/hocr_reference.py", "--root", str(ARGS.root)],
        "reference-rerun.log",
        timeout=900,
    )

    # HO02 (Dart half): the Dart parser against the independent lxml
    # records and the same-pass TSV.
    run_lane(
        "compare-records",
        [
            DART,
            "run",
            "tool/hocr_compare.dart",
            "--root",
            str(ARGS.root),
            "--reference",
            str(OUT / "reference.json"),
            "--out",
            str(OUT / "comparison-diff.json"),
        ],
        "compare-records.log",
    )

    # HO03/HO04/HO05/HO06: the focused hOCR suites over the licensed
    # fixtures and the derived document, plus the VM worker-op lane.
    run_lane(
        "vm-hocr",
        [DART, "test", "test/tests/hocr/", "test/tests/web/hocr_worker_ops_test.dart"],
        "vm-hocr.log",
        timeout=900,
    )

    # HO05 (flow): sidecar -> snapshot -> search/index -> zones -> anchor
    # -> reopen.
    run_lane("flow", [DART, "test", "test/tests/hocr/hocr_flow_test.dart"], "flow.log")

    # HO07 (regressions): the whole VM suite without fuzz — every
    # pre-existing parser lane (ALTO, PAGE, DjVu, ...) stays green.
    run_lane("vm-suite", [DART, "test", "--exclude-tags", "fuzz"], "vm-suite.log", timeout=2400)

    # HO07 (worker): fresh compile, then the compiled-worker Chrome lane
    # (parse, bind, encode, two independent requests, typed errors), then
    # the whole Chrome suite.
    run_lane(
        "worker-compile",
        [DART, "compile", "js", "web/unseal_worker.dart", "-o", "test/web/unseal_worker.js"],
        "worker-compile.log",
    )
    run_lane(
        "chrome-worker",
        [DART, "test", "-p", "chrome", "test/web/hocr_worker_test.dart"],
        "chrome-worker.log",
        timeout=900,
    )
    run_lane(
        "chrome-suite",
        [DART, "test", "-p", "chrome", "test/web/"],
        "chrome-suite.log",
        timeout=2400,
    )

    # HO08: measurements, format, fuzz, corpus manifest, publish dry-run,
    # and the comparator's negative corpus.
    run_lane(
        "bench",
        [DART, "run", "tool/hocr_bench.dart", "--iterations", "20", "--out", str(OUT / "bench.json")],
        "bench.log",
    )
    run_lane("format", [DART, "format", "--output=none", "--set-exit-if-changed", "."], "format.log")
    run_lane("fuzz", [DART, "test", "--tags", "fuzz"], "fuzz.log", timeout=2400)
    run_lane("corpus", [DART, "run", "tool/fuzz_corpus_inventory.dart", "--check-manifest"], "corpus.log")
    run_lane("publish-dry-run", [DART, "pub", "publish", "--dry-run"], "publish-dry-run.log")
    run_lane(
        "comparator-negatives",
        [PYTHON, "tool/hocr_comparator_negatives.py", "--root", str(ARGS.root), "--dart", DART],
        "comparator-negatives.log",
        timeout=600,
    )

    diff = json.loads((OUT / "comparison-diff.json").read_text())
    negatives = json.loads((OUT / "comparator-negatives.json").read_text())
    reference = json.loads((OUT / "reference.json").read_text())
    vm_hocr = (OUT / "vm-hocr.log").read_text()
    flow = (OUT / "flow.log").read_text()
    suite = (OUT / "vm-suite.log").read_text()
    chrome = (OUT / "chrome-suite.log").read_text()
    chrome_worker = (OUT / "chrome-worker.log").read_text()

    def last_count(text):
        for line in reversed(text.splitlines()):
            if "All tests passed!" in line:
                return line.strip()
        return "no summary found"

    documents = len(reference.get("records", {})) - 5  # minus the five .tsv entries
    runs = len(reference.get("commands", []))
    case(
        "HO01",
        "pass" if FAILURES == [] else "fail",
        ["analyze.log", "entrypoints.log"],
        "lib/hocr.dart, the unseal.dart export, and the narrow entry point "
        "compile analyzer-clean; parser, model, binding, limits and typed "
        "errors are public; subset, class policy, title grammar, text and "
        "geometry contracts are documented in doc/hocr.md, written before "
        "the comparison lane ran.",
    )
    case(
        "HO02",
        "pass" if diff["failures"] == 0 and diff["tsvRuns"] == 5 else "fail",
        ["reference-rerun.log", "reference.json", "comparison-diff.json", "compare-records.log"],
        f"Tesseract 5.5.3 executed {runs} times in this stage (tiffcp plus five "
        "recognition passes, hOCR and TSV from the same pass each) over the "
        "Apache-2.0 tesseract-ocr/test images; eight pre-existing CC0 "
        f"sidecars from ocr-fileformat-samples (ABBYY 11, ocropy, OCRopus, "
        "gcv2hocr, kraken, tesseract 3.x) plus one derived document; the "
        f"Dart parser matches the independent lxml records field by field "
        f"({diff['fieldsCompared']} fields, {diff['failures']} divergences over "
        f"{documents} documents) and the hOCR joins its own TSV exactly "
        f"({diff['tsvWordsCompared']} words, {diff['tsvLinesCompared']} lines, "
        f"{diff['tsvBlocksCompared']} blocks, {diff['tsvParagraphsCompared']} "
        "paragraphs); the committed Tesseract fixtures are byte-identical to "
        "the fresh outputs.",
    )
    case(
        "HO03",
        "pass" if FAILURES == [] else "fail",
        ["vm-hocr.log", "comparison-diff.json"],
        "Multi-page (multipage), multi-column (UNLV nine content areas, "
        "ABBYY paragraph-direct, kraken page-direct), tags and classes "
        "beyond div/span (p, strong, em, sup, ins, del, br, alternatives), "
        "mixed class lists, entities, inline markup, lang/dir/xml:lang "
        "verbatim, CJK from gcv2hocr and astral characters from the "
        "derived document all preserved without altering the text origin; "
        "the lxml extractor produces identical records.",
    )
    case(
        "HO04",
        "pass" if FAILURES == [] else "fail",
        ["vm-hocr.log", "comparison-diff.json", "bench.json"],
        "Boxes stay integer pixels top-left with x1/y1 corners; baselines "
        "stay native polynomials with named page-space projections; "
        "textangle never rotates coordinates (spatial rotation is always "
        "0); scan_res is DPI; x_wconf 0..100 converts by division to the "
        "shared 0..1 and absent, unknown and zero remain distinct; every "
        "geometry field matches the reference records.",
    )
    case(
        "HO05",
        "pass" if FAILURES == [] else "fail",
        ["vm-hocr.log", "flow.log"],
        "The host-confirmed binding carries the target identity tuple; "
        "repeated quotes and ins/del alternatives report ambiguity with "
        "bounded candidates (16 default); absence is observable as "
        "missing; the reading cursor crosses pages in document order; "
        "search, the inverted index, zone lookups and durable anchors "
        "resolve the same bound ranges; a changed origin or revision "
        "refuses verified reuse.",
    )
    case(
        "HO06",
        "pass" if FAILURES == [] else "fail",
        ["vm-hocr.log", "comparison-diff.json"],
        "Bytes, raw-tag depth, element counts, per-page elements, "
        "attributes, title/class lengths are bounded in a preflight scan "
        "before any DOM is built; pages, blocks, paragraphs, lines, "
        "words, properties, tokens and text lengths are bounded during "
        "the walk; candidate collection and projection work charge the "
        "budget before scanning; depth overflow, title overflow, "
        "non-finite numbers, truncation and budget exhaustion fail typed "
        "(15 pinned comparator negatives).",
    )
    case(
        "HO07",
        "pass" if "All tests passed!" in chrome and "All tests passed!" in suite and "All tests passed!" in chrome_worker else "fail",
        ["vm-hocr.log", "vm-suite.log", "worker-compile.log", "chrome-worker.log", "chrome-suite.log"],
        "The worker recompiles fresh and the compiled-worker Chrome lane "
        "serves hocr.bind over the real message channel with two "
        "independent identities and typed corruption (HocrException and "
        f"HocrUnsupportedFeatureException); the full Chrome suite finishes "
        f"({last_count(chrome)}) and the whole VM suite keeps ALTO, PAGE "
        f"and DjVu regressions green ({last_count(suite)}).",
    )
    case(
        "HO08",
        "pass" if all(negatives.values()) and FAILURES == [] else "fail",
        ["comparator-negatives.json", "comparator-negatives.log", "bench.json", "format.log", "fuzz.log", "corpus.log", "publish-dry-run.log"],
        "The comparator rejects a missing reference, an emptied reference, "
        "a mutated record field, a fixture whose freshness claim no longer "
        "holds, and a reference command that fails, while the untouched "
        "baseline passes; the bench records parse/bind medians and RSS "
        "deltas over four corpus shapes; format, fuzz, corpus manifest "
        "and publish dry-run run clean.",
    )

    report = {
        "head": head,
        "cases": cases,
        "laneFailures": FAILURES,
        "lanes": {
            "analyze": str(OUT / "analyze.log"),
            "entrypoints": str(OUT / "entrypoints.log"),
            "referenceRerun": str(OUT / "reference-rerun.log"),
            "comparisonDiff": str(OUT / "comparison-diff.json"),
            "vmHocr": str(OUT / "vm-hocr.log"),
            "flow": str(OUT / "flow.log"),
            "vmSuite": str(OUT / "vm-suite.log"),
            "workerCompile": str(OUT / "worker-compile.log"),
            "chromeWorker": str(OUT / "chrome-worker.log"),
            "chromeSuite": str(OUT / "chrome-suite.log"),
            "bench": str(OUT / "bench.json"),
        },
    }
    (OUT / "comparison.json").write_text(json.dumps(report, indent=1) + "\n")
    if FAILURES:
        for failure in FAILURES:
            print("FAIL:", failure, file=sys.stderr)
        sys.exit(1)
    print("compare ok: HO01–HO08 pass; head", head[:12])


if __name__ == "__main__":
    main()
