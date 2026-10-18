#!/bin/sh
# D01 version stage: record the exact executed toolchain versions.
# Env: DART_BIN, NODE_BIN, PYTHON_BIN, EVIDENCE_DIR.
set -e
DART_BIN="${DART_BIN:-dart}"
NODE_BIN="${NODE_BIN:-node}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EVIDENCE_DIR="${EVIDENCE_DIR:-build/evidence/D01}"

cd "$(dirname "$0")/../.."
mkdir -p "$EVIDENCE_DIR"

{
  printf 'dart: '
  "$DART_BIN" --version 2>&1
  printf 'node: '
  "$NODE_BIN" --version
  printf 'python: '
  "$PYTHON_BIN" --version 2>&1
  printf '@readium/shared: '
  "$NODE_BIN" -e \
    "process.stdout.write(require('./tool/readium/node_modules/@readium/shared/package.json').version + '\n')" 2>/dev/null ||
    echo 'not installed (run npm ci in tool/readium)'
  printf 'jsonschema: '
  "$PYTHON_BIN" -c 'import jsonschema; print(jsonschema.__version__)'
  printf 'git HEAD: '
  git rev-parse HEAD
} > "$EVIDENCE_DIR/versions.log" 2>&1
cat "$EVIDENCE_DIR/versions.log"
