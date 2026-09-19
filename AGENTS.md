# Working in Unseal

Unseal is a pure-Dart library that turns ebook and document bytes into a
format-neutral reading model. It parses content. It does not own a reader UI,
audio playback, networking, or application persistence.

Read [the architecture guide](docs/architecture.md) before changing module
boundaries, public exports, format dispatch, archive limits, or worker code.
Use [the codebase guide](docs/unseal-codebase-guide.md) for the file-by-file
tour of formats, shared policies, and platform implementations.
The README is the public product contract. Tests are the behavioral contract.

## Repository map

- `lib/unseal.dart` is the main public entry point.
- `lib/<format>.dart` contains a format-specific public entry point.
- `lib/src/features/` owns format parsers and format-neutral reading features.
- `lib/src/foundation/` owns shared models and low-level policies.
- `lib/src/platform/` owns VM and browser execution adapters.
- `web/unseal_worker.dart` is the browser worker entry point.
- `test/` contains unit, integration, browser, and fuzz tests.
- `test/resources/` contains licensed or generated fixtures and provenance.
- `benchmark/` and `tool/` contain development-only programs.

## Architecture rules

- Keep `lib/` independent of Flutter.
- Keep rendering in Grimoire and audio playback in Grimoire Narration.
- Features may depend on `foundation`; `foundation` must not depend on a
  format feature.
- Put format-specific parsing, errors, entities, and rendering conversions in
  that format's directory.
- Put a type in `foundation` only when several independent features need the
  same contract.
- Route public parsing through `Unseal` or a format-specific public entry
  point. Do not expose a private `src` import to consumers.
- Preserve typed failures. Do not leak `RangeError`, `FormatException`, or
  parser implementation errors from public APIs.
- Apply archive and recursion limits before allocating untrusted output.
- Do not add compatibility aliases for APIs that have not been published.

## Working rules

- Inspect `git status --short` before editing. Preserve unrelated work.
- Treat binary fixtures as source data. Do not rewrite them to make a test
  pass.
- When a fixture changes, update its manifest or provenance record in the
  same commit.
- Keep public documentation and examples on `package:unseal/unseal.dart`.
- Add a focused regression test for every parser or security-boundary fix.
- Keep generated output, local dependency overrides, Steward files, and
  machine-specific paths out of Git.

## Verification

Use the smallest relevant check while editing. Before release, run the same
commands as CI:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --exclude-tags fuzz
dart test -p chrome test/web/
dart pub publish --dry-run
```

The extended deterministic fuzz campaign is separate:

```sh
dart test --tags fuzz
dart run tool/fuzz_corpus_inventory.dart --check-manifest
```

Run browser tests when changing conditional imports, worker messages, wire
codecs, or web-specific behavior. Run format-specific tests before the full
suite when changing one parser.

## Commit and release hygiene

- Stage explicit paths. Do not use broad staging in a dirty worktree.
- Keep generated docs, caches, reports, and local corpus output out of commits.
- Publish in dependency order: Unseal, Grimoire, then Grimoire Narration.
- Do not tag, push, or publish unless the user asks for that action.
