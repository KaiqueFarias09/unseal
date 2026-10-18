#!/bin/sh
# D01 reference stage: execute the official @readium/shared Locator model
# over the pinned corpus, then validate the corpus against the pinned
# official Locator schema (syntax-derived) plus the normative rules.
# Env: NODE_BIN (default: node), PYTHON_BIN (default: python3),
#      EVIDENCE_DIR (default: build/evidence/D01).
set -e
NODE_BIN="${NODE_BIN:-node}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EVIDENCE_DIR="${EVIDENCE_DIR:-build/evidence/D01}"

mkdir -p "$EVIDENCE_DIR"
cd "$(dirname "$0")/../.."

"$NODE_BIN" --version > "$EVIDENCE_DIR/node-version.log" 2>&1
"$NODE_BIN" tool/readium/reference.mjs "$EVIDENCE_DIR"
"$PYTHON_BIN" tool/readium/schema_check.py "$EVIDENCE_DIR" tool/readium/corpus/locator-cases.json
