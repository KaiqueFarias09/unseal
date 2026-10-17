# Hypothesis quote-anchoring oracle

Produces the JSONL oracle answers `tool/hypothesis_anchor_compare.dart`
consumes: for every (text, quote, prefix, suffix) case, the range
Hypothesis client's `matchQuote` anchors. This is the acceptance oracle
for the durable-anchor resolution — the port base is Hypothesis's
anchoring approach (quote + context re-found approximately), so its own
matcher is the reference the comparator scores against. `matchQuote` is
DOM-free: it runs on plain strings, the same canonical texts Unseal
resolves against.

## Pinned revision

- Hypothesis client `a7b7400d0d706d4357ec37c2a3610b25dcca89d5`
  (BSD-2-Clause with separately licensed subcomponents), the revision
  the parallel plan pins. `matchQuote` searches exact first, then
  approximately with up to `min(256, quote.length / 2)` edits
  (`approx-string-match@^2.0.0`), scores quote 50 / prefix 20 /
  suffix 20 / position 2, and returns the single highest-scoring match
  — ties keep the leftmost occurrence. Unseal's resolver is
  deliberately stricter on that last point: an indistinguishable tie
  stays ambiguous. The comparator classifies that policy difference as
  an expected divergence and fails only on real mismatches.

## Building the oracle bundle

Requires Node (any recent LTS) and network access; the clone lives
outside this repository:

```
ORACLE=/tmp/unseal-a05-oracle
mkdir -p "$ORACLE" && cd "$ORACLE"
git init hypothesis-client && cd hypothesis-client
git remote add origin https://github.com/hypothesis/client.git
git fetch --depth 1 origin a7b7400d0d706d4357ec37c2a3610b25dcca89d5
git checkout FETCH_HEAD
npm install --no-save approx-string-match@2.0.1
npx esbuild src/annotator/anchoring/match-quote.ts --bundle \
  --format=cjs --platform=node --outfile="$ORACLE/match-quote.cjs"
```

## Running the comparator

```
dart run tool/hypothesis_anchor_compare.dart \
  --oracle "$ORACLE/match-quote.cjs" \
  --node "$(which node)" \
  --json /tmp/unseal-a05-oracle/report.json
```

`--node` defaults to `node` on the PATH; `--oracle` is required — the
comparator refuses to run (exit code 2) without the pinned bundle, and
a missing oracle never counts as a pass. Fixtures are the licensed
Gutenberg PDF corpus (`test/resources/pdf/gutenberg`), plus labeled
synthetic astral cases.

## Reproducing a divergence

Run with `--json` and judge the listed evidence. Each case reports the
oracle range and the Unseal outcome with both selected texts. Expected
divergences (ambiguity policy, declared-fuzzy budget) print as such;
a real divergence exits non-zero. When the oracle itself looks wrong
against human expectation, human expectation decides — record the call
in the handoff, not in this directory.
