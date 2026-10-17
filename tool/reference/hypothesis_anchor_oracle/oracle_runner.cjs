// JSONL oracle runner for Hypothesis client's `matchQuote` (the DOM-free
// string anchoring of src/annotator/anchoring/match-quote.ts).
//
// stdin: one JSON case per line —
//   {"text": "...", "exact": "...", "prefix": "...", "suffix": "..."}
// stdout: one JSON result per line —
//   {"start": <int|null>, "end": <int|null>, "score": <number|null>}
//
// The implementation bundle is built OUTSIDE this repository from the
// pinned revision; see README.md. This runner only marshals cases.
const {matchQuote} = require(process.env.MATCH_QUOTE_BUNDLE);
const lines = require('readline').createInterface({input: process.stdin});
lines.on('line', (line) => {
  if (!line.trim()) return;
  const testCase = JSON.parse(line);
  const match = matchQuote(testCase.text, testCase.exact, {
    prefix: testCase.prefix || undefined,
    suffix: testCase.suffix || undefined,
  });
  process.stdout.write(
    JSON.stringify({
      start: match ? match.start : null,
      end: match ? match.end : null,
      score: match ? match.score : null,
    }) + '\n',
  );
});
