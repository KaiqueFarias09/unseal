// C++ oracle extractor for the D04 FGbz mission.
//
// Links the pinned DjVuLibre implementation and dumps, per page: the INFO
// geometry, the native Sjbz JB2 blit list (position, shape number, shape
// dimensions), and the FGbz palette plus its per-blit color indices, all
// read through the library itself (DjVuDocument/DjVuImage/JB2Image/
// DjVuPalette). The Dart decoder is never involved.
//
// Build (homebrew layout):
//   c++ -std=c++17 -O2 -I/opt/homebrew/include/libdjvu \
//     tool/djvu_fgbz_oracle.cpp -o build/evidence/D04/djvu_fgbz_oracle \
//     -L/opt/homebrew/lib -ldjvulibre
//
// Usage:
//   djvu_fgbz_oracle <file.djvu> [outdir]
//
// Writes <outdir>/<basename>.fgbz-oracle.json (or stdout when outdir is
// omitted). Exit codes: 0 comparison data produced, 1 usage error,
// 2 the DjVu library refused the input (GException) — the comparator
// treats every nonzero exit as a refusal of the reference.

#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <sstream>

#include <GException.h>
#include <GURL.h>
#include <DjVuDocument.h>
#include <DjVuImage.h>
#include <DjVuFile.h>
#include <DjVuInfo.h>
#include <DjVuPalette.h>
#include <GBitmap.h>
#include <JB2Image.h>
#include <ddjvuapi.h>

namespace {

std::string
jsonEscape(const char *text)
{
  std::string out;
  for (const char *p = text; *p; ++p)
  {
    const unsigned char c = (unsigned char)*p;
    if (c == '"' || c == '\\')
    {
      out += '\\';
      out += (char)c;
    }
    else if (c < 0x20)
    {
      char buf[8];
      snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    }
    else
    {
      out += (char)c;
    }
  }
  return out;
}

void
dumpPage(std::ostream &out, const int pageNumber, const GP<DjVuImage> &image)
{
  out << "    {\n";
  out << "      \"page\": " << pageNumber << ",\n";

  const GP<DjVuInfo> info = image->get_info();
  if (info)
  {
    out << "      \"width\": " << info->width << ",\n";
    out << "      \"height\": " << info->height << ",\n";
    out << "      \"dpi\": " << info->dpi << ",\n";
    out << "      \"gamma\": " << info->gamma << ",\n";
  }
  else
  {
    out << "      \"width\": null,\n";
    out << "      \"height\": null,\n";
    out << "      \"dpi\": null,\n";
    out << "      \"gamma\": null,\n";
  }
  out << "      \"realWidth\": " << image->get_real_width() << ",\n";
  out << "      \"realHeight\": " << image->get_real_height() << ",\n";

  // The native Sjbz decode: blit list in decode order with the combined
  // (shared-then-local) shape index and the shape's bitmap dimensions.
  const GP<JB2Image> jimg = image->get_fgjb();
  if (!jimg)
  {
    out << "      \"sjbz\": null\n";
    out << "    }";
    return;
  }
  out << "      \"sjbz\": {\n";
  out << "        \"width\": " << jimg->get_width() << ",\n";
  out << "        \"height\": " << jimg->get_height() << ",\n";
  out << "        \"shapeCount\": " << jimg->get_shape_count() << ",\n";
  out << "        \"blitCount\": " << jimg->get_blit_count() << ",\n";
  out << "        \"blits\": [\n";
  for (int i = 0; i < jimg->get_blit_count(); ++i)
  {
    const JB2Blit *blit = jimg->get_blit(i);
    const JB2Shape &shape = jimg->get_shape(blit->shapeno);
    int columns = 0;
    int rows = 0;
    if (shape.bits)
    {
      columns = shape.bits->columns();
      rows = shape.bits->rows();
    }
    out << "          {\"left\": " << blit->left
        << ", \"bottom\": " << blit->bottom
        << ", \"shape\": " << blit->shapeno
        << ", \"w\": " << columns
        << ", \"h\": " << rows << ", \"bits\": \"";
    const char *hex = "0123456789abcdef";
    for (int y = rows - 1; y >= 0; --y)
      for (int x = 0; x < columns; x += 8) {
        unsigned char packed = 0;
        for (int bit = 0; bit < 8 && x + bit < columns; ++bit)
          if ((*shape.bits)[y][x + bit]) packed |= 0x80 >> bit;
        out << hex[packed >> 4] << hex[packed & 15];
      }
    out << "\"}"
        << (i + 1 < jimg->get_blit_count() ? "," : "") << "\n";
  }
  out << "        ]\n";
  out << "      },\n";

  // The native FGbz decode through DjVuPalette::decode (DjVuFile already
  // ran it when the page carries an FGbz chunk; get_fgbc also walks the
  // page's INCL includes, mirroring the library's own lookup order).
  const GP<DjVuPalette> pal = image->get_fgbc();
  const GP<GPixmap> fgpm = image->get_fgpm();
  out << "      \"fgbz\": ";
  if (!pal)
  {
    out << "null,\n";
  }
  else
  {
    out << "{\n";
    out << "        \"paletteSize\": " << pal->size() << ",\n";
    out << "        \"palette\": [\n";
    for (int i = 0; i < pal->size(); ++i)
    {
      GPixel color;
      pal->index_to_color(i, color);
      out << "          [" << (int)color.r << ", " << (int)color.g << ", "
          << (int)color.b << "]" << (i + 1 < pal->size() ? "," : "") << "\n";
    }
    out << "        ],\n";
    out << "        \"colorDataSize\": " << pal->colordata.size() << ",\n";
    out << "        \"colordata\": [";
    for (int i = 0; i < pal->colordata.size(); ++i)
    {
      out << (i ? ", " : "") << (int)pal->colordata[i];
    }
    out << "]\n";
    out << "      },\n";
  }
  out << "      \"fg44Foreground\": " << (fgpm ? "true" : "false") << "\n";
  out << "    }";
}

} // namespace

int
main(int argc, char **argv)
{
  if (argc < 2 || argc > 3)
  {
    fprintf(stderr, "usage: djvu_fgbz_oracle <file.djvu> [outdir]\n");
    return 1;
  }
  setlocale(LC_ALL, "");
  try
  {
    const GURL url = GURL::Filename::UTF8(argv[1]);
    GP<DjVuDocument> doc = DjVuDocument::create_wait(url);
    const int pages = doc->get_pages_num();

    std::ostringstream out;
    out << "{\n";
    out << "  \"tool\": \"djvu_fgbz_oracle\",\n";
    out << "  \"djvulibre\": \""
        << jsonEscape(ddjvu_get_version_string()) << "\",\n";
    out << "  \"file\": \"" << jsonEscape(argv[1]) << "\",\n";
    out << "  \"pages\": [\n";
    for (int p = 0; p < pages; ++p)
    {
      const GP<DjVuImage> image = doc->get_page(p);
      dumpPage(out, p + 1, image);
      out << (p + 1 < pages ? ",\n" : "\n");
    }
    out << "  ]\n";
    out << "}\n";

    std::string body = out.str();
    if (argc == 3)
    {
      const char *slash = strrchr(argv[1], '/');
      const char *base = slash ? slash + 1 : argv[1];
      std::string path = std::string(argv[2]) + "/" + base + ".fgbz-oracle.json";
      FILE *f = fopen(path.c_str(), "wb");
      if (!f)
      {
        fprintf(stderr, "cannot write %s\n", path.c_str());
        return 1;
      }
      fwrite(body.data(), 1, body.size(), f);
      fclose(f);
      printf("%s\n", path.c_str());
    }
    else
    {
      fwrite(body.data(), 1, body.size(), stdout);
      fputc('\n', stdout);
    }
    return 0;
  }
  catch (const GException &ex)
  {
    fprintf(stderr, "djvulibre error: %s\n", (const char *)ex.get_cause());
    return 2;
  }
  catch (const std::exception &ex)
  {
    fprintf(stderr, "error: %s\n", ex.what());
    return 2;
  }
}
