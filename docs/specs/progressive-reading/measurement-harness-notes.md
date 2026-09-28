# Measurement harness notes — progressive-reading A/B

Handoff record for the benchmark harness built for the frozen metrics
contract in [design.md](design.md) section 6. The original probe was
smoke-verified on 2026-09-26; its session modes were subsequently
implemented and the campaign results are in
[the A/B report](ab-report-2026-09-26.md). The descriptions below reflect
the current harness, while the caveats record issues found during setup.

## Files

Unseal checkout:

| File | Role |
| --- | --- |
| `tool/large_fixture_kit.dart` | Shared kit: SplitMix64 PRNG, incompressible-noise PNG encoder (hand-built IHDR/IDAT/IEND), reproducible zip writer (stored `mimetype` first, deflate rest, pinned mtimes), seeded English word-bag prose. |
| `tool/generate_large_epub.dart` | `reflowable` (300 × ~40 KB chapters, 1 CSS, 20 × ~787 KB PNGs, EPUB 3 OPF + nav + NCX), `fxl` (60 pages, viewport 1200×1700, `layout-pre-paginated` manifest properties + `rendition:layout` OPF metadata, 60 × ~397 KB PNGs), `all`. Flags: `--out=<dir>` (default `build/fixtures/`), `--verify` (re-parses through `Unseal.parse`, checks reading order + PNG header round-trip). Prints a manifest JSON. |
| `tool/generate_large_cbz.dart` | 160 PNG pages ~507 KB each, `page-001.png…` + `ComicInfo.xml`. `--pages=<n>`, `--out=`, `--verify`. |
| `tool/progressive_bench.dart` | Per-process open probe with `parse-sync`, `read-isolate`, `read-file-isolate`, `session-header`, and `session-first-content` modes. Emits `rss_series_mb`/`rss_peak_mb` (whole-run series from a sampling isolate) and `t_first_content_ms` for the eager modes too (first resident content access per book type). |
| `tool/progressive_bench_sweep.dart` | Serial sweep driver: one fresh child process per (book, mode, repetition), mode order rotated per repetition (A/B alternation), aggregates min/median/p90/p95/max per (book, mode) for `t_open_ms`, `t_first_content_ms`, `rss_delta_mb`, `rss_peak_mb` (+ warm pair when present). |

Grimoire checkout:

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
rss_series_mb, rss_peak_mb,  (only when ps sampling works),
bookFormat, readingOrderLength, declaredUncompressedBytes,  (archive formats)
status ("ok"|"fail"|"unsupported"|"unimplemented"), error
```

`bookId` = SHA-256 of the resolved absolute path, first 12 hex; paths
never appear. `rss_before` is sampled after the input bytes are
resident and immediately before the open, so `rss_delta_mb` isolates
the open's retained cost.

## RSS series instrument (added 2026-09-28)

Per the format-expansion design §5, the probe now records a whole-run
RSS series and peak:

- **Where it samples**: inside the probe process, in a dedicated
  sampling isolate running `ps -o rss= -p <pid>` every ~10 ms
  (serialized — no new `ps` before the previous finished), covering the
  whole run: bytes load → open → warm open → teardown. Samples are
  rounded to 0.1 MB; `rss_peak_mb` is the max sample.
- **Why an isolate (not the sweep parent, not a main-isolate timer)**:
  `parse-sync` blocks the main isolate's event loop for the whole open,
  so a timer there would only catch the two endpoints, and the old
  endpoint pairs demonstrably miss the peak (a dracula `parse-sync` run
  measured `rss_delta_mb: -171` while its series peaked at +877 MB over
  startup). Parent-side sampling of the child pid would work too, but
  in-probe sampling needs no pid bookkeeping or kill-race cleanup and
  the sweep — which spawns one fresh child per measurement — simply
  inherits the series through the child's JSON line. The `ps` spawn
  latency (well above 10 ms under load) gates the effective cadence;
  overhead stays negligible against multi-second opens.
- **Failure posture**: if `ps` is unavailable (non-macOS/Unix), the
  fields are omitted and the probe still succeeds. The handshake
  between the probe and the sampler isolate uses per-message reply
  ports (a reply on the already-consumed startup port is silently
  dropped — found and fixed during the smoke run).
- **Sweep aggregation**: per (book, mode) the report now carries
  `rss_peak_mb` stats (`{min, median, p90, p95, max, samples}` — the
  peak of each repetition's series) alongside `rss_delta_mb`, plus
  `t_first_content_ms` stats, and every summary gained a `p95` next to
  `p90`. A child that exits nonzero but printed its JSON keeps its own
  typed status (`unsupported` for session modes over pdf/cbr until
  those waves land) in its failure cell.
- **`t_first_content_ms` in the eager modes** times the first content
  access right after the open, per book type: EPUB = first
  reading-order HTML text; PDF = first page's canonical text lines;
  comics = first page image bytes. Eager parses materialize all of
  that at open time, so the eager values are near-zero by construction
  (~0.5–1 ms measured) — the honest reading is that the first-content
  cost sits inside `t_open_ms`; the campaign's time-to-first-page A/B
  for the deferred path comes from the session modes (and the Grimoire
  reader probe), where the value is a real load (e.g. 3.1 ms for the
  sample CBZ's first page).

Sweep report (`build/progressive-open-sweep.json`): envelope
(`schemaVersion`, `kind="progressive-open-sweep"`, platform/sdk/commit,
repetitions, modeOrder note) with per-(bookId, mode) rows:
`t_open_ms` / `t_first_content_ms` / `rss_delta_mb` / `rss_peak_mb` /
`t_warm_ms` / `rss_warm_delta_mb` (the latter two when warmed)
objects `{min, median, p90, p95, max, samples}` plus `ok`/`fail`
counts. Failed child runs never abort the sweep.

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

## Session modes and reader integration

`session-header` measures `BookSession.open`; `session-first-content`
also fetches the first document and linked resources. Both use the
session header for structure fields rather than parsing the book a
second time. The Grimoire probe chooses full parse or `BookSession`
with `E2E_OPEN_BOOK_MODE`; both variants retain the same post-layout
page signal. The VM sweep with five repetitions is stored outside Git
as `unseal-ab-session.json` under the campaign artifact root.

`rss_delta_mb` in a probe or reader JSON is the difference between two
samples, **not peak RSS**. The original external reader sampler did not
save its computed peak. The corrected macOS sampler and run instructions
are in Grimoire's `tool/sample_app_peak_rss_macos.sh` and
`tool/measure_open_device.md`; the peak-memory A/B must be repeated.

## Measurement caveats found while building this

- `ProcessInfo.currentRss` deltas swing by HUNDREDS of MB at process
  start (cold `parse-sync` on dracula measured −157 MB; a warm open
  measured −398 MB right after a GC). Medians over ≥5 fresh processes
  are usable; single-run deltas on books < ~10 MB are not. This is
  exactly why the generator writes 24–83 MB books.
- Dart has no peak-RSS API; if the peak (not post-open resident) is
  needed for the A/B verdict, sample externally (`ps`/`footprint` on
  macOS, `dumpsys meminfo` on device — runbook section 4). Since
  2026-09-28 the probe does this for you on macOS/Unix: see the RSS
  series instrument section above.
- `example/assets/books/` bundling grows the app by the full book size
  (profile APK was already 98.9 MB on the S23); `E2E_OPEN_BOOK_PATH`
  avoids it on desktop. Device path config must use `--dart-define`
  (host env vars do not reach a phone process).
- Id caveat: `bookId` path hashes follow this spec, but
  `benchmark/library_sweep.dart` retired path-hash ids for the PRIVATE
  corpus (weak anonymization; it uses random ids + a private id map).
  Reports over the private library must stay in the artifacts folder
  only.
