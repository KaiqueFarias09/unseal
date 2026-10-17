// The PdfPig layout dump oracle: prints one JSON document with every
// page's words and their bounding boxes, for
// `tool/pdf_layout_compare.dart`.
//
// Pinned to the revision the parallel plan ports from:
//   PdfPig 3452b9fb52440202fa30b8dd8bf57c5186f8de29 (Apache-2.0)
//
// Build once with:
//   dotnet new console -o . (then replace Program.cs and csproj)
//   dotnet add package UglyToad.PdfPig --version 0.1.11-daily-2025*-*
// (resolve to the commit above; see README.md)
//
// Usage: dotnet run -- <pdf> > dump.json

using System.Text.Json;
using UglyToad.PdfPig;

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: dotnet run -- <pdf>");
    return 2;
}

using var document = PdfDocument.Open(args[0]);

var pages = new List<object>();
foreach (var page in document.GetPages())
{
    var words = new List<object>();
    foreach (var word in page.GetWords())
    {
        var box = word.BoundingBox;
        words.Add(new
        {
            text = word.Text,
            // PdfPig boxes are bottom-left-origin; flip to top-left to
            // match unseal's layout model.
            x = box.BottomLeft.X,
            y = page.Height - box.TopRight.Y,
            width = box.Width,
            height = box.Height,
        });
    }

    pages.Add(new
    {
        index = page.Number - 1,
        width = page.Width,
        height = page.Height,
        words,
    });
}

var dump = new
{
    tool = "PdfPig",
    revision = "3452b9fb52440202fa30b8dd8bf57c5186f8de29",
    pages,
};

Console.WriteLine(JsonSerializer.Serialize(dump, new JsonSerializerOptions
{
    WriteIndented = true,
}));

return 0;
