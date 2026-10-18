/*
 * Re-encodes one TIFF directory through libtiff into a chosen layout, so
 * the tiled corpus can cover what tiffcp cannot write: CCITT modified
 * Huffman (compression 2), explicit Orientation and FillOrder tags, and
 * strip/tile geometry on any supported depth. Every output is a libtiff
 * 4.x product and is recorded as a derived fixture.
 *
 * Build: cc -O2 -o tiff_oracle_encode tiff_oracle_encode.c \
 *          -I/opt/homebrew/include -L/opt/homebrew/lib -ltiff
 * Usage: tiff_oracle_encode <input.tif> <output.tif> [options]
 *   --page N                 input directory (default 0)
 *   --tile WxL               write tiles of W by L pixels
 *   --rows N                 rows per strip (default: whole image)
 *   --compression NAME       none|packbits|lzw|zip|ccittrle|g3|g3-2d|g4
 *   --predictor 1|2          horizontal differencing (lzw/zip only)
 *   --bigtiff                write BigTIFF
 *   --big-endian             write MM byte order (default: host order)
 *   --little-endian          write II byte order
 *   --orientation N          write the Orientation tag
 *   --fillorder 1|2          write the FillOrder tag
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <tiffio.h>

static int fail(const char *message) {
    fprintf(stderr, "tiff_oracle_encode: %s\n", message);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3) return fail("usage: <input.tif> <output.tif> [options]");
    const char *inputPath = argv[1];
    const char *outputPath = argv[2];
    int page = 0;
    uint32_t tileWidth = 0, tileLength = 0, rowsPerStrip = 0;
    uint16_t compression = COMPRESSION_NONE;
    int predictor = 1;
    int bigTiff = 0;
    char byteOrder = 0;
    int orientation = 0;
    int fillOrder = 0;
    for (int i = 3; i < argc; i++) {
        const char *flag = argv[i];
        const char *value = i + 1 < argc ? argv[i + 1] : NULL;
        if (strcmp(flag, "--bigtiff") == 0) {
            bigTiff = 1;
        } else if (strcmp(flag, "--big-endian") == 0) {
            byteOrder = 'b';
        } else if (strcmp(flag, "--little-endian") == 0) {
            byteOrder = 'l';
        } else if (value == NULL) {
            return fail("option needs a value");
        } else if (strcmp(flag, "--page") == 0) {
            page = atoi(value);
            i++;
        } else if (strcmp(flag, "--tile") == 0) {
            if (sscanf(value, "%ux%u", &tileWidth, &tileLength) != 2) return fail("--tile WxL");
            i++;
        } else if (strcmp(flag, "--rows") == 0) {
            rowsPerStrip = (uint32_t)atoi(value);
            i++;
        } else if (strcmp(flag, "--compression") == 0) {
            if (strcmp(value, "none") == 0) compression = COMPRESSION_NONE;
            else if (strcmp(value, "packbits") == 0) compression = COMPRESSION_PACKBITS;
            else if (strcmp(value, "lzw") == 0) compression = COMPRESSION_LZW;
            else if (strcmp(value, "zip") == 0) compression = COMPRESSION_ADOBE_DEFLATE;
            else if (strcmp(value, "ccittrle") == 0) compression = COMPRESSION_CCITTRLE;
            else if (strcmp(value, "g3") == 0 || strcmp(value, "g3-2d") == 0) compression = COMPRESSION_CCITTFAX3;
            else if (strcmp(value, "g4") == 0) compression = COMPRESSION_CCITTFAX4;
            else return fail("unknown compression");
            if (strcmp(value, "g3-2d") == 0) predictor = -2; /* marker: 2D group 3 */
            i++;
        } else if (strcmp(flag, "--predictor") == 0) {
            predictor = atoi(value);
            i++;
        } else if (strcmp(flag, "--orientation") == 0) {
            orientation = atoi(value);
            i++;
        } else if (strcmp(flag, "--fillorder") == 0) {
            fillOrder = atoi(value);
            i++;
        } else {
            return fail("unknown option");
        }
    }
    int group3TwoD = predictor == -2;
    if (predictor == -2) predictor = 1;

    TIFF *in = TIFFOpen(inputPath, "r");
    if (!in) return fail("cannot open input");
    if (page > 0 && !TIFFSetDirectory(in, (tdir_t)page)) return fail("input page not found");
    uint32_t width = 0, height = 0;
    uint16_t bits = 1, spp = 1, photometric = 0, planar = 1;
    TIFFGetField(in, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(in, TIFFTAG_IMAGELENGTH, &height);
    TIFFGetFieldDefaulted(in, TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(in, TIFFTAG_SAMPLESPERPIXEL, &spp);
    TIFFGetFieldDefaulted(in, TIFFTAG_PLANARCONFIG, &planar);
    if (!TIFFGetField(in, TIFFTAG_PHOTOMETRIC, &photometric)) photometric = bits == 1 ? 0 : 1;
    if (planar != PLANARCONFIG_CONTIG) return fail("planar-separate input not supported");
    if (width == 0 || height == 0) return fail("empty input");
    size_t rowBytes = ((size_t)width * bits * spp + 7) / 8;
    unsigned char *pixels = calloc(rowBytes, height);
    if (!pixels) return fail("allocation failed");
    if (TIFFIsTiled(in)) {
        uint32_t inTileWidth = 0, inTileLength = 0;
        TIFFGetField(in, TIFFTAG_TILEWIDTH, &inTileWidth);
        TIFFGetField(in, TIFFTAG_TILELENGTH, &inTileLength);
        if (((size_t)inTileWidth * bits * spp) % 8 != 0) return fail("input tile rows are not byte aligned");
        size_t inTileRowBytes = (size_t)inTileWidth * bits * spp / 8;
        unsigned char *tile = malloc((size_t)TIFFTileSize(in));
        if (!tile) return fail("allocation failed");
        for (uint32_t y = 0; y < height; y += inTileLength) {
            for (uint32_t x = 0; x < width; x += inTileWidth) {
                if (TIFFReadTile(in, tile, x, y, 0, 0) < 0) return fail("input tile read failed");
                size_t columnByte = (size_t)x * bits * spp / 8;
                size_t copyBytes = inTileRowBytes < rowBytes - columnByte ? inTileRowBytes : rowBytes - columnByte;
                uint32_t rows = inTileLength < height - y ? inTileLength : height - y;
                for (uint32_t r = 0; r < rows; r++) {
                    memcpy(pixels + (size_t)(y + r) * rowBytes + columnByte, tile + (size_t)r * inTileRowBytes, copyBytes);
                }
            }
        }
        free(tile);
    } else {
        for (uint32_t y = 0; y < height; y++) {
            if (TIFFReadScanline(in, pixels + (size_t)y * rowBytes, y, 0) < 0) return fail("input scanline read failed");
        }
    }
    float xResolution = 0, yResolution = 0;
    uint16_t resolutionUnit = 0;
    int hasXResolution = TIFFGetField(in, TIFFTAG_XRESOLUTION, &xResolution);
    int hasYResolution = TIFFGetField(in, TIFFTAG_YRESOLUTION, &yResolution);
    int hasResolutionUnit = TIFFGetField(in, TIFFTAG_RESOLUTIONUNIT, &resolutionUnit);
    TIFFClose(in);

    char mode[8] = "w";
    size_t modeLength = 1;
    if (bigTiff) mode[modeLength++] = '8';
    if (byteOrder) mode[modeLength++] = byteOrder;
    mode[modeLength] = '\0';
    TIFF *out = TIFFOpen(outputPath, mode);
    if (!out) return fail("cannot open output");
    TIFFSetField(out, TIFFTAG_IMAGEWIDTH, width);
    TIFFSetField(out, TIFFTAG_IMAGELENGTH, height);
    TIFFSetField(out, TIFFTAG_BITSPERSAMPLE, bits);
    TIFFSetField(out, TIFFTAG_SAMPLESPERPIXEL, spp);
    TIFFSetField(out, TIFFTAG_PHOTOMETRIC, photometric);
    TIFFSetField(out, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(out, TIFFTAG_COMPRESSION, compression);
    if (predictor == 2) TIFFSetField(out, TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL);
    if (compression == COMPRESSION_CCITTFAX3 && group3TwoD) {
        TIFFSetField(out, TIFFTAG_GROUP3OPTIONS, GROUP3OPT_2DENCODING);
    }
    if (orientation > 0) TIFFSetField(out, TIFFTAG_ORIENTATION, (uint16_t)orientation);
    if (fillOrder > 0) TIFFSetField(out, TIFFTAG_FILLORDER, (uint16_t)fillOrder);
    if (hasXResolution) TIFFSetField(out, TIFFTAG_XRESOLUTION, xResolution);
    if (hasYResolution) TIFFSetField(out, TIFFTAG_YRESOLUTION, yResolution);
    if (hasResolutionUnit) TIFFSetField(out, TIFFTAG_RESOLUTIONUNIT, resolutionUnit);
    if (tileWidth > 0 && tileLength > 0) {
        if (!TIFFSetField(out, TIFFTAG_TILEWIDTH, tileWidth)) return fail("tile width rejected");
        if (!TIFFSetField(out, TIFFTAG_TILELENGTH, tileLength)) return fail("tile length rejected");
        size_t tileRowBytes = ((size_t)tileWidth * bits * spp + 7) / 8;
        if (((size_t)tileWidth * bits * spp) % 8 != 0) return fail("tile rows are not byte aligned");
        unsigned char *tile = calloc(tileRowBytes, tileLength);
        if (!tile) return fail("allocation failed");
        for (uint32_t y = 0; y < height; y += tileLength) {
            for (uint32_t x = 0; x < width; x += tileWidth) {
                memset(tile, 0, tileRowBytes * tileLength);
                size_t columnByte = (size_t)x * bits * spp / 8;
                size_t copyBytes = tileRowBytes < rowBytes - columnByte ? tileRowBytes : rowBytes - columnByte;
                uint32_t rows = tileLength < height - y ? tileLength : height - y;
                for (uint32_t r = 0; r < rows; r++) {
                    memcpy(tile + (size_t)r * tileRowBytes, pixels + (size_t)(y + r) * rowBytes + columnByte, copyBytes);
                }
                if (TIFFWriteTile(out, tile, x, y, 0, 0) < 0) return fail("tile write failed");
            }
        }
        free(tile);
    } else {
        TIFFSetField(out, TIFFTAG_ROWSPERSTRIP, rowsPerStrip > 0 ? rowsPerStrip : height);
        for (uint32_t y = 0; y < height; y++) {
            if (TIFFWriteScanline(out, pixels + (size_t)y * rowBytes, y, 0) < 0) return fail("scanline write failed");
        }
    }
    if (!TIFFWriteDirectory(out)) return fail("directory write failed");
    TIFFClose(out);
    free(pixels);
    return 0;
}
