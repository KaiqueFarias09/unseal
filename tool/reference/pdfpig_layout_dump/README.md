# PdfPig layout dump oracle

Produces the JSON layout dump `tool/pdf_layout_compare.dart` consumes:
per page, the words PdfPig extracts with their bounding boxes, plus the
page dimensions. This is the acceptance oracle for the layout port —
the port base is PdfPig's `DocumentLayoutAnalysis` (word extraction,
Docstrum segmentation), so its own word output is the reference the
comparator scores against.

## Pinned revision

- PdfPig `3452b9fb52440202fa30b8dd8bf57c5186f8de29` (Apache-2.0), the
  revision the parallel plan pins for the port (master, just past the
  `0.1.16` release). The nearest published package is `PdfPig` `0.1.16`
  on NuGet (the package id is `PdfPig`, not `UglyToad.PdfPig`).

## Producing a dump

Requires the .NET SDK 9 (installs user-local without sudo:

```
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 9.0 --install-dir ~/.dotnet9
export DOTNET_ROOT=~/.dotnet9 PATH=~/.dotnet9:$PATH
```

). Two ways to get the library:

**Package (simplest, any OS):** create a console project, add
`<PackageReference Include="PdfPig" Version="0.1.16" />`, copy
`Program.cs` in, and run it.

**Exact pinned commit (what the validated numbers in the handoff used):**

```
mkdir -p /tmp/pdfpig-src && cd /tmp/pdfpig-src
git init && git remote add origin https://github.com/UglyToad/PdfPig
git fetch --depth 1 origin 3452b9fb52440202fa30b8dd8bf57c5186f8de29
git checkout -q FETCH_HEAD
```

On macOS/Linux, the Fonts csproj embeds its AFM/GlyphList resources
through Windows-style globs, which collapse the manifest names on Unix;
give them explicit logical names (or build on Windows, where the stock
csproj produces the folder-bearing names the code looks up):

```xml
<EmbeddedResource Include="Resources/AdobeFontMetrics/*">
  <LogicalName>UglyToad.PdfPig.Fonts.Resources.AdobeFontMetrics.%(Filename)%(Extension)</LogicalName>
</EmbeddedResource>
<EmbeddedResource Include="Resources/GlyphList/*">
  <LogicalName>UglyToad.PdfPig.Fonts.Resources.GlyphList.%(Filename)%(Extension)</LogicalName>
</EmbeddedResource>
```

Then reference `UglyToad.PdfPig.csproj`, `*.Core.csproj`,
`*.DocumentLayoutAnalysis.csproj` and `*.Fonts.csproj` from the console
project, copy `Program.cs` in, and run:

```
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

## Validated results

Both real Gutenberg books, every page, against this exact setup:

- `pg5200-generated.pdf` (31 pages): 31/31 PASS, word score 1.0 on
  every page, mean IoU 0.93–0.95, after unseal's text-matrix
  composition fix (see the 1.3.0 changelog).
- `pg11-generated.pdf` (55 pages): 55/55 PASS, word score 1.0, mean
  IoU 0.93–0.96.

## Reproducing a divergence

Run the comparator with `--json` and judge the listed evidence:

```
dart run tool/pdf_layout_compare.dart --pdf book.pdf --oracle book.layout.json --json report.json
```

Word score below 0.8 or mean IoU below 0.5 fails the page. When the
oracle itself looks wrong against human expectation (reading order,
editorial headers), human expectation decides — record the call in the
handoff, not in this directory.
