#!/bin/sh
# D01 compare stage: run the Readium VM and Chrome suites (with a freshly
# compiled worker), then the gate-shaped comparator with its independent
# Python verifier and negatives. Env: DART_BIN, NODE_BIN, PYTHON_BIN,
# EVIDENCE_DIR.
set -e
DART_BIN="${DART_BIN:-dart}"
NODE_BIN="${NODE_BIN:-node}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EVIDENCE_DIR="${EVIDENCE_DIR:-build/evidence/D01}"

cd "$(dirname "$0")/../.."
mkdir -p "$EVIDENCE_DIR/cases"

# Chrome needs the worker entry point freshly compiled next to the tests.
"$DART_BIN" compile js web/unseal_worker.dart -o test/web/unseal_worker.js \
  > "$EVIDENCE_DIR/cases/worker-compile.log" 2>&1

set +e
"$DART_BIN" test test/tests/locators/ test/tests/cfi/ test/tests/reading/ \
  > "$EVIDENCE_DIR/cases/vm-suite.log" 2>&1
VM_EXIT=$?
"$DART_BIN" test -p chrome test/web/readium_worker_test.dart \
  > "$EVIDENCE_DIR/cases/chrome-suite.log" 2>&1
CHROME_EXIT=$?
set -e

# The Chrome suite itself probes that a real worker served the session.
grep -q "All tests passed!" "$EVIDENCE_DIR/cases/chrome-suite.log" || CHROME_EXIT=1

printf '%s\n' '{
  "vm": {"exit": '"$VM_EXIT"', "worker": true},
  "chrome": {"exit": '"$CHROME_EXIT"', "worker": true}
}' > "$EVIDENCE_DIR/cases/suites.json"

"$DART_BIN" run tool/readium_position_bench.dart \
  --book "test/resources/epub/Alices Adventures in Wonderland.epub" \
  --out "$EVIDENCE_DIR/readium-position-bench.json" \
  > "$EVIDENCE_DIR/cases/bench-alice.log" 2>&1
"$DART_BIN" run tool/readium_position_bench.dart \
  --book test/resources/books/epub/mahabharata.epub \
  --out "$EVIDENCE_DIR/readium-position-bench-mahabharata.json" \
  > "$EVIDENCE_DIR/cases/bench-mahabharata.log" 2>&1

"$DART_BIN" run tool/readium_compare.dart \
  --evidence "$EVIDENCE_DIR" \
  --python "$PYTHON_BIN" \
  --suites "$EVIDENCE_DIR/cases/suites.json"
