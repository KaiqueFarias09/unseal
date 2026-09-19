# Apply the library architecture standard

Use this plan to migrate one library at a time. Do not run full test suites from two packages at the same time.

## Done conditions

A migration is complete when all of these conditions are true:

- Every source file has one feature or shared-layer owner.
- Hand-written extracted modules have explicit import boundaries; `part` is not
  used to disguise a distributed large class.
- Multi-declaration files contain one cohesive vocabulary or one operation and
  its reachable private implementation.
- No feature contains `utils`, `helpers`, `common`, or `misc`.
- Package dependencies follow the documented direction.
- Public entrypoints expose every type used by their signatures.
- Tests and examples compile through public entrypoints.
- Focused tests, the full package test suite, static analysis, and Steward pass.
- Searches for each old path return no matches.
- Each target resolves the correct library, example, adapter, or application
  Steward profile.
- `git diff --check` returns no errors.

## Phase 1: record the baseline

1. Confirm that the working tree and external drive are healthy.
2. Record the current source paths, public entrypoints, package dependencies, test paths, and Steward findings.
3. Separate pre-existing changes from the migration. Do not discard or stage unrelated work.
4. List every generic directory with exact file paths. This list is the migration inventory.

## Phase 2: classify ownership

For each file, answer these questions in order:

1. Which capability would be incomplete without this file?
2. Does the file define a caller-visible concept, an operation, or an internal technical responsibility?
3. Do at least two unrelated features need the same format-independent concept?

Keep feature-specific code in its feature. Move code to `foundation` only when the third answer is yes.

## Phase 3: move one feature

1. Move the main operation to the feature root.
2. Keep a small feature flat.
3. Group a larger feature by concrete responsibility.
4. Use imported collaborators with narrow contracts for hand-written modules;
   do not replace a large file with a group of `part` files.
5. Update imports, exports, tests, examples, benchmarks, tools, and generated-worker inputs.
6. Search for every old path and obsolete compatibility surface.
7. Run static analysis and focused tests for that feature and its direct consumers.
8. Stop if the move changes behavior unintentionally. Intentional pre-release
   API changes migrate every caller and add a public contract test in the same
   wave.

Each agent owns one feature wave. Agents do not edit the same entrypoint at the same time.

## Phase 4: close public contracts

1. Compile a small contract test against each `lib/*.dart` entrypoint.
2. Export every caller-visible parameter and result type.
3. Replace test and example imports of `lib/src` with public imports.
4. Reject imports of another package's `lib/src` path.

## Phase 5: apply Steward rules

Implement the rules in [the architecture standard](library-architecture-standard.md#steward-rules) in Steward's Dart package scanner. Add a positive and negative fixture for each rule.

Fix these current Steward defects before enabling the new gates:

- Parse `pubspec.yaml` dependency sections instead of matching every indented `path:` key. The current regular expression mistakes the hosted package named `path` for a local dependency.
- Ignore `dependency_overrides` when checking production dependency sources. Pub does not publish overrides.
- Make `dart.declaration.ownership` honor the contract's function-owned module rule. One public operation followed by private helpers is one owner, not many peer declarations.
- Use relative imports between files below one package's `lib/src`. Disable `flutter.package-imports` for library targets because it currently requests the self-import form that `dart.library.internal-import` rejects.
- Give package examples an example contract. Do not require Riverpod, Dio, Lucide icons, or a full application feature tree unless the example opts into those policies.

Apply rules in this order:

1. Gate generic feature directories, foundation direction, external private imports, and pure Dart boundaries.
2. Warn on cross-feature implementation imports and missing feature tests.
3. Fix current warnings with exact path lists.
4. Change both warning rules to gates when all three libraries report zero findings.
5. Pin each repository to the new capability-library contract.
6. Regenerate `docs/architecture.md` and the managed blocks in agent instruction files.

## Phase 6: verify packages in dependency order

Run verification from the base package toward optional packages:

1. Verify `unseal` with Dart analysis, focused tests, the full VM suite, and browser tests.
2. Verify `grimoire` with Flutter analysis and its full test suite.
3. Verify `grimoire_narration` with Flutter analysis, its full test suite, and a publish dry run.
4. Run Steward against all three repositories.
5. Review each diff and create separate commits for source moves, behavior fixes, Steward rules, and generated architecture files.

## Agent handoff format

Each agent reports:

- the exact paths it changed;
- behavior changes, or `none`;
- focused commands and pass counts;
- remaining old-path matches;
- unrelated files it preserved;
- storage errors or unexplained command delays;
- whether it created a commit.

Stop the migration immediately if `/Volumes/SSD` disappears or macOS reports an input/output, filesystem, USB-reset, or APFS error.
