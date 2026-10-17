# PdfPig layout dump oracle

Produces the JSON layout dump `tool/pdf_layout_compare.dart` consumes:
per page, the words PdfPig extracts with their bounding boxes, plus the
page dimensions. This is the acceptance oracle for the layout port —
the port base is PdfPig's `DocumentLayoutAnalysis` (word extraction,
Docstrum segmentation), so its own word output is the reference the
comparator scores against.

## Pinned revision

- PdfPig `3452b9fb52440202fa30b8dd8bf57c5186f8de29` (Apache-2.0), the
  revision the parallel plan pins for the port.

## Producing a dump

Requires the .NET SDK (8.0 or newer):

```
cd tool/reference/pdfpig_layout_dump
dotnet run -- /path/to/book.pdf > /path/to/book.layout.json
```

The dump schema:

```json
{
  "tool": "PdfPig",
  "revision": "3452b9fb52440202fa30b8dd8bf57c5186f8de29",
  "pages": [
    {
      "index": 0,
      "width": 612.0,
      "height": 792.0,
      "words": [
        {"text": "Hello", "x": 72.0, "y": 62.4, "width": 27.3, "height": 9.6}
      ]
    }
  ]
}
```

Boxes use top-left-origin page points (PdfPig's `Width`/`Height` page
space), matching unseal's layout model, so the comparator overlaps
boxes directly. Rotated pages: PdfPig reports the rotated dimensions,
like unseal's `PdfPageGeometry`.

## Reproducing a divergence

Run the comparator with `--json` and judge the listed evidence:

```
dart run tool/pdf_layout_compare.dart --pdf book.pdf --oracle book.layout.json --json report.json
```

Word score below 0.8 or mean IoU below 0.5 fails the page. When the
oracle itself looks wrong against human expectation (reading order,
editorial headers), human expectation decides — record the call in the
handoff, not in this directory.
