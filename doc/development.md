# Develop and release Unseal

Use a source checkout for development. The published package does not include
the test fixtures, benchmark programs, or `tool/` scripts referenced here.
Start with the [architecture](architecture.md) before changing module
boundaries, dispatch, worker messages, or input limits.

## Set up the checkout

The SDK used by CI is pinned in `.dart-version`. The repository's `.fvmrc`
selects a Flutter SDK that supplies that Dart version. Install it with FVM,
or use a matching standalone Dart SDK.

```sh
dart pub get --no-example
```

The Flutter example has separate dependencies; run its commands from
`example/`. The library itself remains pure Dart.

## Check a change

Run the format-specific tests while editing. The normal VM checks are:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --exclude-tags fuzz
```

For worker, conditional-import, or wire changes, compile the test worker
before running Chrome:

```sh
dart compile js web/unseal_worker.dart -o test/web/unseal_worker.js
dart test -p chrome test/web/
```

The worker's `.js`, `.js.deps`, and `.js.map` files are generated output.
They are ignored by Git and excluded from the package with the test suite.

Extended deterministic fuzzing and corpus checks run separately:

```sh
dart test --tags fuzz
dart run tool/fuzz_corpus_inventory.dart --check-manifest
```

Fixture bytes are source data. Keep their license, provenance, hashes, and
expected results together under `test/resources/`. Do not rewrite a fixture
to hide a parser regression. See [parser references](format-parser-references.md).

The JPEG 2000 fixtures carry their own acceptance tooling: regenerate the
8-bit corpus with `tool/generate_jpx_fixtures.dart` (requires the pinned
OpenJPEG builds) and re-run its oracle comparison any time with
`dart run tool/compare_jpx_oracle.dart`. The precision/subsampling corpus
(8-16 bit, per-component grids, sYCC) regenerates with
`dart run tool/generate_jpx_precision_fixtures.dart --write` after
`sh tool/jpx_oracle/build.sh` (libopenjp2 2.5.4) and verifies without the
flag; `dart run tool/jpx_precision_reference.dart --out=build/evidence/C04`
executes the reference over read-only fixture copies and
`dart run tool/jpx_precision_compare.dart --out=build/evidence/C04` runs the
full acceptance matrix (format, analysis, VM, freshly compiled worker and
browser suites, fuzz, corpus inventory, pub dry-run, isolated benchmark).
Decoder latency (p50/mean/p95, VM and compiled JS) comes from
`dart run tool/measure_jpx.dart`; per-process time and peak RSS for the
precision cases come from `dart run tool/jpx_precision_bench.dart`. Note that
`dart format .` resolves `example/analysis_options.yaml` (page width 100)
through the example's own package resolution: run `flutter pub get` in
`example/` once per checkout, then `git checkout -- example/` if the upgrade
step touched tracked files.

## Measure performance

The benchmark suite measures library operations, not rendered page latency:

```sh
dart run benchmark/unseal_benchmarks.dart --quick
dart run benchmark/unseal_benchmarks.dart --json=build/current.json
dart run benchmark/compare_baselines.dart build/baseline.json build/current.json
```

For large-file session comparisons, generate fixtures or use licensed files:

```sh
dart run tool/generate_large_epub.dart all --verify
dart run tool/generate_large_cbz.dart --verify
dart run tool/progressive_bench.dart --mode=session-first-content --book=build/fixtures/large-reflowable.epub
dart run tool/progressive_bench_sweep.dart --book=build/fixtures/large-reflowable.epub --repetitions=5 --out=build/progressive-open-sweep.json
```

Use the actual output path printed by the generator. Probe modes are
`parse-sync`, `read-isolate`, `read-file-isolate`, `session-header`, and
`session-first-content`. The sweep starts a fresh process for each run and
rotates mode order between repetitions.

Interpret the measurements by their boundaries:

- `t_open_ms` measures opening. Add `t_first_content_ms` when comparing
  opening plus the first resource request. Full parsing performs most content
  work during opening, so its subsequent first-content access is cheap.
- `rss_delta_mb` is the difference between two samples, not peak memory.
  `rss_peak_mb` and `rss_series_mb` are available when process sampling works.
  Sampling can miss shorter peaks, and garbage collection can make a retained
  delta negative.
- Compare matching SDKs, platforms, builds, files, modes, and repetitions.
  Report distributions, absolute values, failures, and cases that worsen.
  Session startup overhead can outweigh savings for small books; compressed
  CBR entries still inflate while opening.
- Library timing does not measure a painted page. Test visible-page latency,
  transitions, and accessibility in the consuming application. Emulators are
  useful for behavior; they do not prove performance on a physical phone.

Keep generated fixtures and reports under ignored output directories.
Private-library sweeps require an external random-ID map; do not publish
paths, titles, authors, private files, or reports that identify them.

### TIFF strips, tiles, and the libtiff oracle

The TIFF lanes need libtiff 4.7.2 (`/opt/homebrew`, override with
`LIBTIFF_BIN`/`LIBTIFF_PREFIX`) and a C compiler. The reference stage runs
libtiff only; the comparison stage opens every case through `Unseal.parse`:

```sh
python3 tool/tiff_tiles_reference.py --version
python3 tool/tiff_tiles_reference.py --out build/evidence/C03
dart run tool/tiff_tiles_compare.dart --reference=build/evidence/C03/reference.json --out=build/evidence/C03/compare
dart run tool/tiff_tiles_evidence.dart --out=build/evidence/C03
dart run benchmark/tiff_tiles_benchmarks.dart --out=build/evidence/C03/bench.json
dart run tool/tiff_tiles_fixtures.dart check
```

The benchmark decodes strip and tiled twins of the same pixels in separate
AOT child processes, so each `peakRssBytes` is one process's high-water
mark above a bytes-only baseline. Tiles cost their padding: a 158×118 image
in 256×256 tiles decodes 3.5 times its own area. `doc/tiff-tiles.md` fixes
the comparison contract and the budgets.

## Prepare a release

Commit reviewed changes and start from a clean `main`. Match the version in
`pubspec.yaml` and its section in `CHANGELOG.md`, then run:

```sh
make release-check VERSION=1.3.0
```

Use `DART_BIN=/path/to/dart` if automatic SDK discovery does not select the
pinned version. The gate checks metadata, SDK version, formatting, analysis,
VM tests, a freshly compiled worker and Chrome tests, fuzz, the corpus
manifest, and the pub.dev dry-run. It removes generated worker outputs on
exit and checks Git cleanliness again before reporting success.

The check does not push, tag, or publish. When publishing is authorized,
record the actual release date, rerun the gate, push `main`, and wait for
green CI. Then run:

```sh
make release-github VERSION=1.3.0
make publish VERSION=1.3.0
```

These commands recheck release requirements. GitHub release creation requires
`main` to match `origin/main`; publication also requires the matching remote
tag and GitHub Release. Retry the matching command after a partial completion.
