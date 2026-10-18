# Unseal documentation

Start with the [package README](../README.md) to install Unseal, parse your
first book, and check supported formats and limits. Import
`package:unseal/unseal.dart` for the public API.

## Use the library

| Task | Read |
| --- | --- |
| Install and parse bytes | [Installation and quick start](../README.md#installation) |
| Scan metadata without loading content | [Metadata reads](../README.md#quick-start) |
| Read large EPUB, PDF, or comic files on demand | [Progressive sessions](../README.md#progressive-sessions-for-large-books) |
| Preserve EPUB fixed-layout data | [Format-specific APIs](../README.md#format-specific-apis) |
| Run parsing in a browser worker | [Browser usage](../README.md#browser-usage) |
| Handle unsupported or damaged input | [Limits](../README.md#limitations-and-security-boundaries) and [errors](../README.md#errors) |
| Exchange reading positions with Readium | [Locators and position lists](readium-locators.md) |
| Import positioned OCR text | [ALTO](../README.md#alto-ocr-import), [PAGE](../README.md#page-xml-import), and [hOCR](hocr.md) |
| Check changes between versions | [Changelog](../CHANGELOG.md) |

Unseal returns reading data. Your application owns rendering, downloads,
storage, synchronization, OCR execution, and audio playback.

## Contribute to Unseal

| Document | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Module boundaries, parsing flow, sessions, and safety policies. |
| [Codebase guide](unseal-codebase-guide.md) | Find the implementation of a format or reading feature. |
| [Development](development.md) | Run checks, reproduce measurements, and prepare a release. |
| [Parser references](format-parser-references.md) | Format specifications, reference implementations, and fixture provenance. |
| [hOCR](hocr.md) | The supported HTML vocabulary, geometry, limits, and snapshot binding. |
| [Readium locators](readium-locators.md) | Locator interchange and versioned position-list generation. |
| [TIFF planar and palette pages](tiff-planar-palette.md) | Native sample and ColorMap comparisons with libtiff. |
| [DjVu foreground palettes](djvu-fgbz.md) | Per-blit palette decoding and native/foreground comparison. |
| [RAR5 BLAKE2sp](rar5-blake2sp.md) | Declared data-hash verification and solid-state integrity. |
| [TIFF tiles](tiff-tiles.md) | The tiled TIFF/BigTIFF contract, decode budgets, and the libtiff comparison. |
| [Roadmap](roadmap.md) | The single list of pending work and proposals. |

The README describes the current public contract. The roadmap describes
future work, not supported behavior or a release commitment. Fixture licenses,
hashes, and reference outputs stay beside their fixtures under
`test/resources/` in a source checkout.
