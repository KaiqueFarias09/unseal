# Capability-first library architecture

This document defines the default source layout for eLivre libraries. It applies to pure Dart libraries, Flutter libraries, and optional platform packages.

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

## Current repository state

As of 2026-09-08, `e_livre`, `e_livre_viewer`, and `e_livre_viewer_narration` contain no `utils`, `helpers`, `common`, or `misc` directory below a feature root.

eLivre keeps media-overlay parsing under `epub/media_overlays`. The viewer uses the public search API. The narration package separates playback coordination, sources, platform adapters, media-session integration, and presentation.
