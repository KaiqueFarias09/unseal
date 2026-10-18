#!/usr/bin/env python3
"""Execute the hOCR comparator's deliberately invalid cases: a missing
reference, an emptied reference, a mutated record, a mutated fixture hash,
and a reference command that fails. The comparator must reject every one
of them with a non-zero exit.
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path("build/d02"))
parser.add_argument("--dart", default="dart")
args = parser.parse_args()
out = args.root / "outputs"
out.mkdir(parents=True, exist_ok=True)
base = [args.dart, "run", "tool/hocr_compare.dart", "--root", str(args.root)]
results = {}
reference_path = out / "reference.json"


def run_compare(name, reference):
    argv = base + ["--reference", str(reference), "--out", str(out / f"{name}-comparison.json")]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=300)
    (out / f"{name}.log").write_text(
        "argv: " + repr(argv) + "\nexit: " + str(result.returncode) + "\n" + result.stdout + result.stderr
    )
    results[name] = result.returncode != 0


def mutated(name, mutation):
    payload = json.loads(reference_path.read_text())
    mutation(payload)
    target = out / f"{name}-reference.json"
    target.write_text(json.dumps(payload))
    return target


# The untouched comparator passes on the real reference.
run_compare("baseline", reference_path)
results["baselinePasses"] = not results.pop("baseline")

# Missing reference: no file at all.
missing = out / "missing-reference.json"
missing.unlink(missing_ok=True)
run_compare("missing", missing)

# Emptied reference: no documents, no records.
run_compare("empty", mutated("empty", lambda payload: payload.update(records={})))

# One mutated field deep inside the lxml records.
def flip_bbox(payload):
    records = payload["records"]
    key = next(k for k in records if k.startswith("tesseract/phototest"))
    document = json.loads(Path(records[key]["path"]).read_text())
    document["pages"][0]["elements"][0]["bbox"][0] += 1
    path = out / "divergent-records.json"
    path.write_text(json.dumps(document))
    records[key] = dict(records[key], path=str(path))


run_compare("divergent-record", mutated("divergent-record", flip_bbox))


# A fixture whose pinned freshness claim no longer holds.
def flip_fixture(payload):
    key = next(iter(payload["fixtures"]))
    payload["fixtures"][key]["matchesFreshOutput"] = False


run_compare("divergent-fixture", mutated("divergent-fixture", flip_fixture))

# The reference command itself failing: a Tesseract that does not exist.
failed = subprocess.run(
    [
        sys.executable,
        "tool/hocr_reference.py",
        "--root",
        str(args.root / "negative-reference-root"),
        "--tesseract",
        "/nonexistent/tesseract",
    ],
    capture_output=True,
    text=True,
    timeout=120,
)
(out / "failed-reference-command.log").write_text(
    "exit: " + str(failed.returncode) + "\n" + failed.stdout + failed.stderr
)
results["failedReferenceCommand"] = failed.returncode != 0
shutil.rmtree(args.root / "negative-reference-root", ignore_errors=True)

(out / "comparator-negatives.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results))
raise SystemExit(0 if all(results.values()) else 1)
