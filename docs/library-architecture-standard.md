# Capability-first library architecture

This document defines the default source layout for reusable libraries. eLivre,
eLivre Viewer, and eLivre Viewer Narration are the reference implementation, but
the rules apply to future pure Dart libraries, Flutter libraries, and optional
platform packages.

## Package direction

Dependencies point from optional behavior toward stable data and parsing:

```text
e_livre_viewer_narration
        |
        v
e_livre_viewer
        |
        v
e_livre
```

`e_livre_viewer_narration` may also import the public API of `e_livre`. The reverse edges are forbidden.

- `e_livre` owns format detection, parsing, book data, metadata, search, and reading-order concepts. It stays independent of Flutter.
- `e_livre_viewer` owns Flutter rendering, reader interaction, navigation, and reader presentation state.
- `e_livre_viewer_narration` owns optional speech, audio playback, media-session integration, and narration controls.

Packages import another package through `lib/*.dart` entrypoints. They never import another package's `lib/src` files.

## What counts as a feature

A feature is an independently useful capability with its own vocabulary, tests, and public or internal entry operation. A feature does not need a screen.

Detection and search are features because callers can use each capability on its own. Media overlays are part of EPUB because the parser reads EPUB package and SMIL data to produce them. Narration is a separate package because it adds optional Flutter plugins and platform behavior.

## Use the smallest structure that explains the code

Small features stay flat:

```text
search/
├── book_search.dart
├── search_match.dart
├── search_mode.dart
└── search_results.dart
```

Add a folder when a feature has at least two files with the same responsibility, or when the folder separates a technical boundary that a maintainer must see.

```text
epub/
├── parse_epub_book.dart
├── entities/
├── container/
├── content/
├── encryption/
├── media_overlays/
├── metadata/
├── navigation/
└── package/
```

Large decoder features may add deeper technical groups:

```text
pdf/
├── parse_pdf_book.dart
├── codec/
│   ├── ccitt/
│   └── jbig2/
├── image/
├── reader/
└── text/
```

Do not create empty layers or one-file folders to match a template. A new feature starts flat and grows after the second responsibility appears.

## Make extracted files real modules

An extracted file is a module only when its dependencies and ownership are
explicit. Hand-written implementation files use imports and exports. Reserve
`part` for generated code or the rare case where shared library-private state is
itself the intentional boundary; do not use it merely to distribute one large
class across several files.

A module should expose a small operation or vocabulary and hide the mechanics
needed to implement it. Prefer passing a narrow context or port over giving a
collaborator access to its owner's entire controller.

Keep declarations together when they form one concept that callers learn and
change as a unit, such as an event enum and its event value, a sealed result
family, or a small immutable aggregate. Split declarations when one of these is
true:

- a declaration has independent callers, tests, or lifecycle;
- it introduces a different dependency or platform boundary;
- it implements a distinct stage such as decoding, metadata extraction,
  rendering, resource resolution, or persistence;
- a reader must understand unrelated declarations before finding the primary
  operation;
- the declarations change for different reasons.

Line count is a review signal, not an architectural rule. Review a file around
300 lines and require an explicit cohesion justification around 500 lines.
Large lookup tables, protocol vocabularies, parsers, and codecs may remain large
when splitting would hide invariants or create procedural fragments. A small
file can still be poorly designed when it has no clear owner.

Function-owned parser modules are valid: one public parse/decode operation may
own multiple private value types and helpers when they are reachable only from
that operation. Steward should evaluate reachability and ownership, not count
top-level declarations mechanically.

## Name folders by responsibility

Feature folders name the work they own. Accepted examples include `archive`, `codec`, `container`, `content`, `encryption`, `image`, `media_overlays`, `metadata`, `navigation`, `package`, `parsing`, `playback`, `presentation`, `reader`, `rendering`, `security`, `sources`, and `text`.

Do not create `utils`, `helpers`, `common`, or `misc` below a feature. Those names hide ownership. Do not use `services` or `managers` when a concrete responsibility name exists.

`foundation` contains format-independent concepts that at least two unrelated features need. A parser helper does not move to `foundation` only because several files inside one format use it.

## Keep dependencies local and directed

Code inside a feature may import other files in the same feature and `foundation`.

`foundation` must not import a feature. A feature must not reach into another feature's private implementation. If two features need the same format-independent concept, move that concept to `foundation`. If one feature uses another capability, import the owning feature's public contract.

Static factories may delegate to an operation in the same feature when the factory is part of the established public API. `EpubBook.fromBytes` is one such case. This exception does not permit cross-feature imports.

## Design public entrypoints as contracts

Every caller-visible type in a public signature must be reachable from a documented `lib/*.dart` entrypoint. Tests and examples import those entrypoints instead of `lib/src`.

Each entrypoint owns one capability or one deliberate package facade. An entrypoint must not re-export another entrypoint as an accidental alias.

## Mirror source ownership in tests

Each feature has focused tests under a matching feature path. A public contract change adds an entrypoint contract test. A bug fix adds a regression test that fails before the fix.

Pure Dart packages run Dart analysis and tests. Flutter packages run Flutter analysis and tests. Platform adapters also need focused tests that use fakes instead of a device when possible.

## Steward rules

The library contract must enforce these rules:

| Rule | Default level | Condition |
| --- | --- | --- |
| `dart.library.generic-feature-directory` | gate | A path below `lib/src/features/<feature>` contains `utils`, `helpers`, `common`, or `misc`. |
| `dart.library.foundation-direction` | gate | A file below `foundation` imports a feature. |
| `dart.library.external-private-import` | gate | A package imports `package:<other-package>/src/...`. |
| `dart.library.feature-boundary` | warn, then gate | A feature imports another feature's implementation instead of its public contract. |
| `dart.library.public-api-closure` | gate | A public signature exposes a type that its entrypoint does not export. |
| `dart.library.feature-test-parity` | warn | A feature has source files but no focused test path. |
| `dart.library.pure-dart-boundary` | gate | A Dart target imports Flutter or a platform plugin. |
| `dart.library.architecture-doc-sync` | gate | Steward's generated architecture files do not match the pinned contract. |

Start a new rule at `warn` only when the current repositories have known violations that need a migration window. Move the rule to `gate` after the count reaches zero. Do not add wildcard exceptions.

Steward resolves a profile from the target being checked; it must not infer an
application contract merely from the presence of `main.dart`.

| Target profile | Required policy |
| --- | --- |
| pure library | public API closure, dependency direction, tests, publishability |
| Flutter library | pure-library policy plus Flutter/platform boundary checks |
| package example | public-consumer imports and the minimum runnable-example policy |
| application | application architecture and explicitly selected framework policies |
| platform adapter | public port conformance, lifecycle, and platform-focused tests |

Riverpod, Dio, icon-library, routing, and application feature-tree rules are
opt-in application policies. They never apply to a library or package example
unless its target contract explicitly selects them.

Inside one package's `lib/src`, use relative imports. Across packages, use the
dependency's public `package:` entrypoint. These rules are complementary: a
package must neither self-import through `package:<self>/src` nor reach into a
dependency's private `src` tree.

Publishability checks parse `pubspec.yaml` structurally. A dependency named
`path` is not a path source; only a dependency value containing a `path` source
is local. `dependency_overrides` are development resolution inputs and are not
production dependency-source failures.

## Compatibility policy

Published libraries preserve public contracts by default and use staged
deprecation when a replacement is required. Before the first release, prefer a
coherent final contract over compatibility façades: migrate all repositories in
dependency order, delete obsolete entrypoints, and prove the new contract with
consumer tests. Never leave both designs indefinitely merely to avoid changing
unpublished callers.

## Current repository state

As of 2026-09-08, `e_livre`, `e_livre_viewer`, and `e_livre_viewer_narration` contain no `utils`, `helpers`, `common`, or `misc` directory below a feature root.

eLivre keeps media-overlay parsing under `epub/media_overlays`. The viewer uses the public search API. The narration package separates playback coordination, sources, platform adapters, media-session integration, and presentation.
