# Project Gutenberg PDF corpus

Real-world fixtures for the PDF parser, validating extraction and reflow
against books produced outside this package's own fixture builders.

Every fixture below is **cupsfilter-generated**: Project Gutenberg no longer
publishes its auto-generated PDF editions (both
`https://www.gutenberg.org/files/<id>/<id>-pdf.pdf` and
`https://www.gutenberg.org/cache/epub/<id>/pg<id>-pdf.pdf` return 404 for
these ids as of September 2026), so each book was downloaded as the UTF-8
plain text and rendered locally with macOS `cupsfilter` (PDF 1.3, Type1
fonts) — the same real writer that produced `../dickens-sample.pdf`. The
`-generated` suffix marks that origin. Regenerate any missing fixture with:

```
dart run tool/fetch_pdf_corpus.dart
```

| File | PG id | Title | Source | Size (bytes) | Origin |
| --- | --- | --- | --- | ---: | --- |
| `pg11-generated.pdf` | 11 | Alice's Adventures in Wonderland | https://www.gutenberg.org/cache/epub/11/pg11.txt.utf-8 | 151733 | cupsfilter-generated |
| `pg84-generated.pdf` | 84 | Frankenstein; Or, The Modern Prometheus | https://www.gutenberg.org/cache/epub/84/pg84.txt.utf-8 | 365521 | cupsfilter-generated |
| `pg98-generated.pdf` | 98 | A Tale of Two Cities | https://www.gutenberg.org/cache/epub/98/pg98.txt.utf-8 | 682470 | cupsfilter-generated |
| `pg1342-generated.pdf` | 1342 | Pride and Prejudice | https://www.gutenberg.org/cache/epub/1342/pg1342.txt.utf-8 | 648584 | cupsfilter-generated |
| `pg1661-generated.pdf` | 1661 | The Adventures of Sherlock Holmes | https://www.gutenberg.org/cache/epub/1661/pg1661.txt.utf-8 | 547463 | cupsfilter-generated |
| `pg174-generated.pdf` | 174 | The Picture of Dorian Gray | https://www.gutenberg.org/cache/epub/174/pg174.txt.utf-8 | 393502 | cupsfilter-generated |
| `pg2701-generated.pdf` | 2701 | Moby Dick; Or, The Whale | https://www.gutenberg.org/cache/epub/2701/pg2701.txt.utf-8 | 1051718 | cupsfilter-generated |
| `pg5200-generated.pdf` | 5200 | Metamorphosis | https://www.gutenberg.org/cache/epub/5200/pg5200.txt.utf-8 | 110932 | cupsfilter-generated |

Total: 3,951,923 bytes — inside the 10 MB corpus cap, with no single file
larger than ~1.5 MB. If Gutenberg ever restores PG-native PDFs, the fetch
script prefers them and stores them as `pg<id>.pdf` without the suffix.

License: the underlying texts are public domain in the United States.
Project Gutenberg's license boilerplate ships inside each source text and
is rendered, intact, into the first and last pages of every generated PDF.
