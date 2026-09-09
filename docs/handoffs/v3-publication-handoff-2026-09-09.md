# Continue the eLivre v3 publication work

## Objective

Prepare eLivre 3.3.0 and its companion packages for publication:

- `/Volumes/SSD/Projects/eLivre`
- `/Volumes/SSD/Projects/e_livre_viewer`
- `/Volumes/SSD/Projects/e_livre_viewer_narration`
- `/Volumes/SSD/Projects/steward`

Finish the four Steward scanner corrections, run the module review in `docs/v3-module-review-guide.md`, resolve release blockers, and validate clean publication archives in dependency order.

## Read first

1. `/Volumes/SSD/Projects/eLivre/docs/v3-module-review-guide.md`
2. `/Volumes/SSD/Projects/eLivre/docs/library-architecture-standard.md`
3. `/Volumes/SSD/Projects/eLivre/docs/library-architecture-migration-plan.md`
4. The README and changelog in each package.

The module review guide is the human review workbook. The architecture standard decides ownership and module shape. Do not replace either document with a fresh generic architecture proposal.

## Current repository state

All repositories use branch `main`.

| Repository | Reviewed head | Refactor commits | Known uncommitted work |
| --- | --- | --- | --- |
| eLivre | `58ad807` | 17 commits from `d67a258` through `58ad807` | `pubspec.yaml` removes the `parser` topic. Preserve it unless the owner says otherwise. The two v3 documents were added after this head. |
| Viewer | `b46622a` | 12 commits from `5f8ae55` through `b46622a` | None at the last check. |
| Narration | `a7809b8` | 8 commits from `e50f58c` through `a7809b8` | Pre-existing `.DS_Store` and `docs/`. Preserve them. |
| Steward | `709133b` | No commits for the four defects | Concurrent edits under `internal/dartfix/readability/` and untracked `packages/steward_lints/.dart_tool/`. Do not stage or rewrite them. |

Inspect status again before every edit. Stage exact files. Never use `git add .`.

## Completed architecture work

The three libraries now have:

- no generic `utils`, `helpers`, `common`, `shared`, `misc`, or `constants` directories under `lib/src`;
- no handwritten `part` or `part of` decomposition;
- no private self-package imports under `lib/src`;
- public format entrypoints that compile independently;
- format parsing in eLivre, rendering in Viewer, and optional platform audio in Narration.

Major completed changes include DOCX, ODT, FB2, MOBI8, PDF security, Calibre SQLite, worker wire codecs, reader dispatch, navigation, page measurement, annotation state, annotation export, narration runners, and resource shutdown.

The remaining large files were reviewed. Lookup tables, bounded codecs, ordered HTML preparation, protocol vocabularies, and central lifecycle coordination remain together on purpose. Split a file only when the new module owns an independent decision or state transition behind a smaller interface.

## Last complete validation

The following evidence passed after the refactor:

- eLivre: `dart analyze`, 788 VM tests, and 23 Chrome tests.
- Viewer: 209 Flutter tests. Analysis had no errors or warnings and 127 informational lints.
- Narration: `dart analyze` and 13 Flutter tests.
- The SSD remained mounted at `/dev/disk7s1` with 315 GiB available.

Narration's publication dry-run produced one metadata warning and hints for local dependency overrides. Re-run every check because the worktrees can change after this handoff.

## Fix the four Steward defects

The current task that created this handoff could read Steward but could not write it. Implement these changes in a task where `/Volumes/SSD/Projects/steward` is writable.

### 1. Parse dependency sources as YAML

Defect: a hosted dependency named `path` matches a raw `^path:` expression and is reported as a path dependency.

Current implementation:

- `internal/scan/flutter/package_architecture_rules.go`
- `scanFlutterPackagePublishability`, near line 399
- `packageTargetForRoot`, near line 139, also uses a broad `strings.Contains(text, "path:")` capability check

Required behavior:

- Parse `pubspec.yaml` with the existing `gopkg.in/yaml.v3` dependency.
- Inspect values inside `dependencies` and `dev_dependencies`.
- Report a path source only when a dependency value is a map containing the key `path`.
- Do not mistake the hosted package whose name is `path` for a path source.
- Treat `dependency_overrides` as local validation configuration, not a production dependency-source gate. A separate release-hygiene diagnostic may still explain that overrides should be removed before the final dry-run.
- If YAML cannot be parsed, return one precise package-metadata issue instead of guessing from text.

Regression tests must cover:

- `dependencies: {path: ^1.9.0}` passes;
- a nested `some_package: {path: ../some_package}` fails;
- a hosted dependency map with `hosted` and `version` passes;
- `dependency_overrides` does not create a production path-dependency gate;
- malformed YAML produces deterministic behavior.

Completion criterion: focused package-architecture tests pass and eLivre no longer reports a path-dependency gate for its hosted `path` package.

### 2. Honor function-owned parser modules

Defect: the declaration analyzer recognizes a primary-owned function module, but `scanTopLevelDeclarationComposition` reports multiple supporting classes before it applies ownership and reachability.

Current implementation:

- `internal/scan/flutter/declaration_composition_rules.go`
- `primaryOwnedDeclarationModule`, near line 352
- `internal/scan/flutter/widget_composition_rules.go`
- `scanTopLevelDeclarationComposition`, near line 162
- the unconditional supporting-class count is near line 181
- `isPrimaryModuleHelperRole`, near line 307
- `internal/scan/flutter/declaration_ownership_test.go`
- `TestDeclarationOwnershipRejectsSupportingClassInFunctionModule`, near line 272

Required behavior:

- Determine the module kind before enforcing the generic one-supporting-class rule.
- For `dartModulePrimaryOwned`, allow private supporting classes that are reachable from the primary function and have no external consumers.
- Allow more than one such class when every class belongs to that function module.
- Keep reporting public peer classes, unreachable private classes, externally consumed classes, and helpers that precede the primary contrary to the ordering rule.
- Apply the same ownership model in diagnostics and autofix eligibility.

Replace the existing negative test with positive and negative cases. Include a parser function that calls two private builder or result classes, an unreachable private class, and a private class with an external consumer.

Completion criterion: the focused ownership tests pass and the eLivre parser modules no longer produce false ownership gates.

### 3. Make self-import guidance target-aware

Defect: `flutter.package-imports` tells package code to replace relative imports with `package:self/src/...`, while the private-import rule tells the same code to use relative imports.

Current implementation:

- `internal/scan/flutter/import_style_rules.go`
- `scanFlutterPackageImportConventions`, near line 19
- `internal/scan/flutter/run.go`
- the unconditional `PackageImportConventions` scan is near line 402
- `internal/scan/flutter/package_architecture_rules.go`
- the private package import diagnostic is near line 1241

Required behavior:

- For application targets, keep package imports for application-owned files if that remains the application convention.
- For Dart and Flutter library implementation files under `lib/src`, accept relative imports between private modules.
- Across packages, require a public `package:<dependency>/<entrypoint>.dart` import.
- In examples and public contract tests, reject imports of an upstream package's `src` path.
- Do not emit opposing fixes for one import.

Add tests for an app, a Dart library, a Flutter library, a nested example, and a cross-package private import.

Completion criterion: focused import tests pass, eLivre and Viewer receive no self-import warnings, and examples still reject upstream private imports.

### 4. Give examples a consumer profile

Defect: nested examples are classified as complete applications because they contain `lib/main.dart`. They receive Riverpod, Dio, feature-first, navigation-shell, repository, and complete application test rules.

Current implementation:

- `standards/architecture/example-app.yaml`
- `standards/architecture/fixtures/elivre.yaml`
- `standards/architecture/fixtures/elivre-viewer.yaml`
- `internal/scan/flutter/analysis_options_rules.go`
- `analysisOptionsTargetContext`, near line 49
- `internal/scan/flutter/package_architecture_rules.go`
- `isFlutterPackageTargetRoot`, near line 79
- `packageTargetForRoot`, near line 139
- `internal/scan/flutter/config.go`
- `Options`, near line 55
- `internal/validate/validate.go`
- `scanDartLikeTarget`, near line 156
- `internal/scan/flutter/run.go`
- full application scanners are guarded only by `!isPackageTarget`

Required behavior:

- Pass the resolved target artifact and capabilities from `projectstandard.Target` into `flutterscan.Options`.
- Derive `isExample` from the resolved `example` capability rather than from the presence of `lib/main.dart`.
- Apply public-import, compilation, basic analysis, accessibility, and package-consumer checks to examples.
- Apply Riverpod, Dio, feature-first, navigation-shell, repository, backend, and full application architecture rules only when the resolved target requests those capabilities.
- Keep full application rules available to a deliberately complete example through explicit capabilities. Do not infer them from `main.dart`.
- Update `example-app.yaml` so its name describes a package consumer rather than a production application if renaming can be done without breaking contract identity. Otherwise keep the ID and correct its selectors.

Regression tests must show that a small package example with `runApp` and `lib/main.dart` passes without Riverpod or Dio. Add a second fixture that opts into full application rules and still receives them.

Completion criterion: focused target-resolution and Flutter scan tests pass. eLivre and Viewer examples retain public-import checks but lose unrelated Riverpod, Dio, and full application findings.

## Validate Steward after the fixes

Run focused tests first:

```text
GOCACHE=/private/tmp/steward-gocache go test ./internal/scan/flutter -count=1
GOCACHE=/private/tmp/steward-gocache go test ./internal/validate ./internal/projectstandard ./internal/analysisoptions -count=1
```

Then run the repository gates:

```text
make test
make lint
make cover
go build -o .steward/bin/steward ./cmd/steward
```

Re-run Steward against:

- eLivre library and example;
- Viewer library and example;
- Narration library.

Inspect counts by rule. A zero process exit is not enough when the profile records Warn or Info findings.

Completion criterion: all Steward tests pass, the tracked launcher matches the source, and none of the four false-positive families remain in downstream reports.

## Run the package review

Use `docs/v3-module-review-guide.md` in dependency order. This is a structural code-quality review. The automated tests remain responsible for implementation behavior and format correctness.

For each review unit, record one decision:

- **Keep** when ownership, interface, dependency direction, and naming are clear enough for v3;
- **Refactor later** when the current design is publishable and the note names a concrete concept and owner;
- **Block v3** when a public contract, lifecycle, dependency, or failure boundary is unsafe to publish.

Do not split files to satisfy a line count. Split when the new module owns a coherent decision or state machine and callers learn a smaller interface.

Do not convert the checklist into manual format acceptance testing. Inspect representative tests only as evidence that public interfaces and intended seams are usable.

Completion criterion: every review unit has a decision, every **Block v3** item is resolved, every deferred refactor names its owner and reason, and the automated suite remains green.

## Publication sequence

1. Publish eLivre 3.3.0 from a clean checkout. Remove local overrides and run the dry-run again.
2. Replace Viewer's local override with the hosted eLivre constraint. Run analysis, tests, and the dry-run. Publish Viewer 0.2.0.
3. Replace Narration's local overrides with hosted constraints. Run analysis, tests, and the dry-run. Publish Narration 0.1.0.
4. Tag the exact published commits and verify that a new consumer project resolves all three packages from the hosted registry.

Completion criterion: the clean consumer opens one reflowable book, one comic, one PDF, and one narrated EPUB without sibling repository paths.

## Guardrails

- Preserve concurrent changes listed in the repository-state table.
- Stop immediately if `/Volumes/SSD` disappears, reads stall, or I/O errors appear.
- Treat FVM cache permission errors as environment failures unless storage checks also fail.
- Keep eLivre independent of Flutter.
- Keep Viewer independent of audio plugins.
- Keep Narration optional.
- Import upstream packages through public entrypoints.
- Preserve real fixtures and their manifest hashes. Do not edit a fixture to make a parser pass.
- Do not rewrite Git history without renewed approval.
- Do not claim publication readiness from tests that ran only with local path overrides.
