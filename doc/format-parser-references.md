# Parser references and fixture provenance

Use these references when changing a parser or selecting compatibility
fixtures. The [README](../README.md#supported-formats) defines current
support. The [roadmap](roadmap.md) is the single list of pending extensions
and validation gaps.

## Format specifications and behavior references

| Format or feature | Reference | Use in Unseal |
| --- | --- | --- |
| EPUB and KEPUB | [EPUB 3.3](https://www.w3.org/TR/epub-33/), [Kobo EPUB guidelines](https://github.com/kobolabs/epub-spec), and [Kepubify](https://github.com/pgaskin/kepubify) | Package/spine semantics and independent KEPUB generation. KEPUB uses the EPUB parser. |
| EPUB compatibility | [EPUBCheck](https://github.com/w3c/epubcheck) and [W3C EPUB tests](https://github.com/w3c/epub-tests) | Classify source validity and choose interoperability cases. Validity alone does not prove rendering fidelity. |
| Markdown | [CommonMark](https://spec.commonmark.org/0.31.2/) and [Dart Markdown](https://pub.dev/packages/markdown) | Text-to-HTML semantics and conformance examples. |
| RTF | [Microsoft RTF 1.9.1](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf) | Groups, control words, Unicode, metadata, and declared codepages. |
| PalmDOC, eReader, Plucker, and MOBI | [Calibre format notes](https://github.com/kovidgoyal/calibre/tree/master/format_docs), [Plucker notes](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/plucker.html), and [Palm bitmap structures](https://www.fuw.edu.pl/~michalj/palmos/Bitmap.html) | Separate PDB identities, text compression, PML, resources, and bitmap layouts. |
| CHM | [CHM format notes](https://www.nongnu.org/chmspec/latest/), [Microsoft Intel E8 rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09), [Microsoft codepage identifiers](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers), and [jchmlib](https://github.com/chimenchen/jchmlib) | ITSF structure, LZX behavior, locale-selected decoding, and E8 restoration. |
| Sony LRF and LRX | [Calibre LRF implementation](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf) and [Sony format guidance](https://www.sony.com/electronics/support/articles/S1F0504) | LRF behavior and the distinction between unprotected BBeB and protected content. LRX support is plaintext metadata only. |
| PDF | [PDF.js](https://github.com/mozilla/pdf.js) and [Poppler](https://poppler.freedesktop.org/) | Independent extraction and bitmap behavior references. Unseal is not a complete PDF renderer. |
| DjVu | [DjVu 3 specification](https://www.sndjvu.org/spec.html), [djvu-rs](https://github.com/matyushkin/djvu-rs), and [DjVuLibre](https://djvu.sourceforge.net/) tools | Container/codec semantics, ZP constants, text output from `djvutxt`, and reference pixels from `ddjvu`. |
| TIFF and BigTIFF | [TIFF 6.0](https://download.osgeo.org/libtiff/doc/TIFF6.pdf), [BigTIFF](https://libtiff.gitlab.io/libtiff/specification/bigtiff.html), and [libtiff](https://libtiff.gitlab.io/libtiff/) | IFD/offset semantics, strip codecs, and `tiffcp`/`tiffcmp` pixel comparisons. |
| CBR (RAR 5) | [RAR 5 format technote](https://www.rarlab.com/technote.htm), [rardecode](https://github.com/nwaples/rardecode) at `ad22ba91a2ab`, and [libarchive](https://github.com/libarchive/libarchive) at `87dec938` | Container grammar, the version-0 LZ stream, and the two byte-for-byte extraction oracles (`tool/rar5_compare.dart`). |

Reference implementations are development tools, not mandatory runtime
executables. Preserve each source's license boundary. Attribution and bundled
license texts are recorded in [third-party notices](../THIRD_PARTY_NOTICES.md)
and `licenses/`. Do not copy source under an incompatible license.

## Fixture records in a source checkout

| Record | What it preserves |
| --- | --- |
| `test/resources/books/manifest.json` | Book identifiers, source, license, byte size, and hash. |
| Format-local `PROVENANCE.md` and license files | Producer/tool versions, original or derived status, generation commands, reference outputs, and rejected candidates. |
| `test/resources/fuzz/corpus-manifest.json` | Tracked fuzz inputs, hashes, families, and structural facts. |
| Format tests and reference goldens | Expected text, navigation, raster bytes, typed rejection, and resource-limit behavior. |

Keep these records next to the fixtures rather than duplicating them in
campaign reports. Never change original fixture bytes simply to make a test
pass. Generated cases cover exact boundaries; independent real files broaden
compatibility evidence. Label the distinction explicitly.

## Interpret reference comparisons

- DjVu hidden text is compared with `djvutxt`. Selected mask and photo pages
  match `ddjvu`; composed pages use Unseal's hard-mask convention and their
  own raster goldens. `FGbz` colors are not reproduced. A successful parse
  does not establish full DjVu v3 conformance.
- TIFF pages are compared with libtiff output and pinned raster hashes.
  The corpus contains libtiff test images and generated cases, not proof of
  compatibility with every scanner or TIFF layout.
- A derived indirect DjVu fixture checks component resolution. It does not
  substitute for a third-party indirect document.
- A file rejected by both the reference and Unseal is not evidence that
  either reader supports its producer. Keep rejected-candidate explanations
  in provenance instead of adding invalid output as a positive fixture.

See [development](development.md) for the maintained commands that exercise
these contracts and the [roadmap](roadmap.md#format-coverage-and-compatibility-evidence)
for the remaining corpus work.
