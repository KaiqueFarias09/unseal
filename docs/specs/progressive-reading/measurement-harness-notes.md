# Measurement harness notes — progressive-reading A/B

Handoff record for the benchmark harness built for the frozen metrics
contract in [design.md](design.md) section 6. Everything below was
smoke-verified on 2026-09-26; no heavy campaign was started from this
session (a parallel compilation was running).

## Files

Unseal (`/Volumes/SSD/Projects/eLivre`):

| File | Role |
| --- | --- |
| `tool/large_fixture_kit.dart` | Shared kit: SplitMix64 PRNG, incompressible-noise PNG encoder (hand-built IHDR/IDAT/IEND), reproducible zip writer (stored `mimetype` first, deflate rest, pinned mtimes), seeded English word-bag prose. |
| `tool/generate_large_epub.dart` | `reflowable` (300 × ~40 KB chapters, 1 CSS, 20 × ~787 KB PNGs, EPUB 3 OPF + nav + NCX), `fxl` (60 pages, viewport 1200×1700, `layout-pre-paginated` manifest properties + `rendition:layout` OPF metadata, 60 × ~397 KB PNGs), `all`. Flags: `--out=<dir>` (default `build/fixtures/`), `--verify` (re-parses through `Unseal.parse`, checks reading order + PNG header round-trip). Prints a manifest JSON. |
| `tool/generate_large_cbz.dart` | 160 PNG pages ~507 KB each, `page-001.png…` + `ComicInfo.xml`. `--pages=<n>`, `--out=`, `--verify`. |
| `tool/progressive_bench.dart` | Per-process open probe. Modes now: `parse-sync`, `read-isolate`, `read-file-isolate`. Session stubs: `session-header`, `session-first-content` (throw `UnimplementedError`, exit 69). |
| `tool/progressive_bench_sweep.dart` | Serial sweep driver: one fresh child process per (book, mode, repetition), mode order rotated per repetition (A/B alternation), aggregates median/p90/min/max per (book, mode). |

Grimoire (`/Volumes/SSD/Projects/e_livre_viewer`):

| File | Role |
| --- | --- |
| `example/integration_test/e2e_open_probe_test.dart` | Real-reader open probe: one book, `Unseal.read` timing, mount → first post-layout position report (same signal as `e2e_real_reader_test.dart`), RSS around open/first page, 3 timed transitions with the spare-engine assertion. |
| `example/integration_test/real_reader_support.dart` | Helpers extracted from `e2e_real_reader_test.dart` (`PageChangeQueue`, `waitForSection`, `waitForEnginePosition`, `nextHtmlIndex`, `htmlSectionCount`). The original test still has private copies; migrating it is left to its owners. |
| `example/integration_test/open_probe_env.dart` + `_io.dart` + `_stub.dart` | Conditional env/file/RSS access (`if (dart.library.io)`); browser stub returns nulls. |
| `example/test_driver/e2e_open_probe_driver.dart` | `integrationDriver` writing `build/integration_open_probe.json` (same convention as the scenario driver's `integration_response_data.json`). |
| `example/.gitignore` | Added the three exact large-fixture filenames under `assets/books/` (additive only). |
| `tool/measure_open_device.md` | Device re-measurement runbook (flutter drive profile, `am start -W`, `dumpsys meminfo`, dart-define book config). Diagnostics-not-proof is stated at the top. |

## Commands

```sh
# Unseal, fixtures (deterministic; same SDK → byte-identical)
dart run tool/generate_large_epub.dart all --verify
dart run tool/generate_large_cbz.dart --verify      # ~83 MB, takes a while

# Unseal, one probe per FRESH process (RSS isolates that open)
dart run tool/progressive_bench.dart --mode=parse-sync \
  --book=<path> [--password=x] [--warm]

# Unseal, serial sweep with A/B alternation (default 5 reps)
dart run tool/progressive_bench_sweep.dart \
  --book=<path> --book=<path> [--mode=<m> ...] [--repetitions=5] \
  [--library=<root>] --out=build/progressive-open-sweep.json

# Grimoire, real reader
cd example
flutter drive --profile -d macos \
  --driver=test_driver/e2e_open_probe_driver.dart \
  --target=integration_test/e2e_open_probe_test.dart
# Chrome/device + dart-define book config: see tool/measure_open_device.md
```

`--library` sources: `--library=<root>`, `ELIVRE_BENCH_LIBRARY`, then
`UNSEAL_BENCH_LIBRARY` / `UNSEAL_CALIBRE_LIBRARY` (the latter two kept
for operators of the existing sweep). Enumeration reuses `scanLibrary`
from `benchmark/library_sweep.dart` (read-only, book candidates only).

## JSON contracts

Probe stdout — ONE compact JSON line, identical across modes:

```
schemaVersion, kind="progressive-open-probe", mode, bookId, bytes,
t_open_ms, t_first_content_ms (null in full modes),
t_warm_ms, rss_warm_before, rss_warm_after, rss_warm_delta_mb  (--warm only),
rss_before, rss_after (bytes), rss_delta_mb,
bookFormat, readingOrderLength, declaredUncompressedBytes,  (archive formats)
status ("ok"|"fail"|"unimplemented"), error
```

`bookId` = SHA-256 of the resolved absolute path, first 12 hex; paths
never appear. `rss_before` is sampled after the input bytes are
resident and immediately before the open, so `rss_delta_mb` isolates
the open's retained cost.

Sweep report (`build/progressive-open-sweep.json`): envelope
(`schemaVersion`, `kind="progressive-open-sweep"`, platform/sdk/commit,
repetitions, modeOrder note) with per-(bookId, mode) rows:
`t_open_ms` / `rss_delta_mb` / `t_warm_ms` / `rss_warm_delta_mb`
objects `{min, median, p90, max, samples}` plus `ok`/`fail` counts.
Failed child runs never abort the sweep.

Open-probe integration report (`example/build/integration_open_probe.json`):
`scenario: "open-probe"`, `bookSource` (`path`|`asset`|`fallback-dracula`),
`bookFormat`, `bytes`, `parseMs`, `firstPostLayoutReportMs`, `onReadyMs`,
`rssBeforeOpenBytes`/`rssAfterOpenBytes`/`rssAfterFirstPageBytes` (null on
web), `rssDeltaOpenMb`/`rssDeltaFirstPageMb`, `chapterTransitions`,
`transitionSamplesMs`, `transitionMedianMs`, optional
`transitionsSkipped` (books with <4 HTML sections, e.g. a CBZ).

Fixture manifest (generator stdout): `{schemaVersion, kind:
"large-fixture-manifest", seed, files: [{path, bytes, chapters|pages,
images, verification?}]}`.

## Extension points the parent agent must fill (session modes)

All in `tool/progressive_bench.dart`:

1. `_openSession(...)` — replace the `UnimplementedError` throw:
   - `session-header`: time `BookSession.open(bytes, password: …)`
     into `t_open_ms`; leave `t_first_content_ms` null.
   - `session-first-content`: after the header, load the first-page
     content recipe (first spine item document + the CSS files it
     links) via `session.loadResources([...])`; time that span into
     `t_first_content_ms` (header time stays in `t_open_ms`).
2. Structure fields: read `readingOrderLength` /
   `declaredUncompressedBytes` from `session.book` (the header), NOT a
   second parse — restructure `_inspectStructure` to accept it (see the
   TODO in `_openSession` / `_inspectStructure` doc comments).
3. RSS sampling stays valid as long as the session's worker/isolate is
   spawned inside the measured window; keep the record fields identical
   so the sweep needs no changes.
4. Then sweep them: `dart run tool/progressive_bench_sweep.dart --mode=session-header
   --mode=session-first-content …` already aggregates their exit-69
   runs as `unimplemented`; once implemented they aggregate as `ok`.
   In Grimoire, `e2e_open_probe_test.dart`'s open step
   (`Unseal.read`) is the session insertion point
   (`BookSession.openFile` / controller session wiring) — keep the
   first-post-layout-report signal untouched.

## Measurement caveats found while building this

- `ProcessInfo.currentRss` deltas swing by HUNDREDS of MB at process
  start (cold `parse-sync` on dracula measured −157 MB; a warm open
  measured −398 MB right after a GC). Medians over ≥5 fresh processes
  are usable; single-run deltas on books < ~10 MB are not. This is
  exactly why the generator writes 24–83 MB books.
- Dart has no peak-RSS API; if the peak (not post-open resident) is
  needed for the A/B verdict, sample externally (`ps`/`footprint` on
  macOS, `dumpsys meminfo` on device — runbook section 4).
- `example/assets/books/` bundling grows the app by the full book size
  (profile APK was already 98.9 MB on the S23); `E2E_OPEN_BOOK_PATH`
  avoids it on desktop. Device path config must use `--dart-define`
  (host env vars do not reach a phone process).
- Id caveat: `bookId` path hashes follow this spec, but
  `benchmark/library_sweep.dart` retired path-hash ids for the PRIVATE
  corpus (weak anonymization; it uses random ids + a private id map).
  Reports over the private library must stay in the artifacts folder
  only.
