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
 *   --planar                 write PlanarConfiguration 2 (separate planes;
 *                            input must be contiguous RGB)
 *   --palette-bits N         convert a 1..8-bit single-sample input into an
 *                            N-bit (1,2,4,8) palette page with a fixed
 *                            full-range colormap (see paletteEntry below)
 *   --legacy-cmap            with --palette-bits, store the synthesized
 *                            colormap scaled down to byte values, the
 *                            legacy 8-bit-colormap shape libtiff assumes
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

/* The fixed full-range colormap used by --palette-bits: entry i of
 * 2^bits maps to red ramp up, green ramp down, blue stepped by 5. */
static uint16_t paletteEntry(int bits, uint32_t table, uint32_t i) {
    uint32_t n = 1u << bits;
    uint32_t last = n - 1;
    switch (table) {
    case 0: return (uint16_t)((i * 65535u) / last);
    case 1: return (uint16_t)(((last - i) * 65535u) / last);
    default: return (uint16_t)((((i * 5u) % n) * 65535u) / last);
    }
}

/* Reads one packed sub-byte sample, MSB first. */
static unsigned readPackedSample(const unsigned char *row, uint32_t index, uint16_t bits) {
    if (bits >= 8) return row[index];
    uint32_t bitOffset = index * bits;
    unsigned byte = row[bitOffset >> 3];
    int shift = 8 - bits - (int)(bitOffset & 7);
    return (byte >> shift) & ((1u << bits) - 1u);
}

static void storePackedSample(unsigned char *row, uint32_t index, uint16_t bits, unsigned value) {
    if (bits == 8) {
        row[index] = (unsigned char)value;
    } else if (bits == 16) {
        ((uint16_t *)row)[index] = (uint16_t)value;
    } else {
        uint32_t bitOffset = index * bits;
        int shift = 8 - bits - (int)(bitOffset & 7);
        unsigned char mask = (unsigned char)(((1u << bits) - 1u) << shift);
        unsigned char *byte = row + (bitOffset >> 3);
        *byte = (unsigned char)((*byte & ~mask) | ((value << shift) & mask));
    }
}

/* One sample of the contiguous pixel buffer, in host byte order. */
static unsigned pixelSample(const unsigned char *pixels, uint32_t width, uint16_t bits,
                            uint16_t spp, uint32_t y, uint32_t x, uint16_t s) {
    if (bits == 16) {
        return ((const uint16_t *)(pixels + (((size_t)y * width + x) * spp + s) * 2))[0];
    }
    if (bits == 8) return pixels[((size_t)y * width + x) * spp + s];
    return readPackedSample(
        pixels + (size_t)y * (((size_t)width * bits * spp + 7) / 8), (size_t)x * spp + s, bits);
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
    int planarOut = 0;
    int paletteBits = 0;
    int legacyCmap = 0;
    for (int i = 3; i < argc; i++) {
        const char *flag = argv[i];
        const char *value = i + 1 < argc ? argv[i + 1] : NULL;
        if (strcmp(flag, "--bigtiff") == 0) {
            bigTiff = 1;
        } else if (strcmp(flag, "--big-endian") == 0) {
            byteOrder = 'b';
        } else if (strcmp(flag, "--little-endian") == 0) {
            byteOrder = 'l';
        } else if (strcmp(flag, "--planar") == 0) {
            planarOut = 1;
        } else if (strcmp(flag, "--legacy-cmap") == 0) {
            legacyCmap = 1;
        } else if (value == NULL) {
            return fail("option needs a value");
        } else if (strcmp(flag, "--page") == 0) {
            page = atoi(value);
            i++;
        } else if (strcmp(flag, "--palette-bits") == 0) {
            paletteBits = atoi(value);
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
    if (width == 0 || height == 0) return fail("empty input");
    size_t rowBytes = ((size_t)width * bits * spp + 7) / 8;
    unsigned char *pixels = calloc(rowBytes, height);
    if (!pixels) return fail("allocation failed");
    if (planar != PLANARCONFIG_CONTIG) {
        /* De-planarize into the contiguous buffer: bands are read one at
         * a time (libtiff's codecs walk a plane sequentially), then
         * interleaved, so planar inputs can be transcoded too. */
        if (bits != 8 && bits != 16) return fail("planar-separate input not supported");
        int bps = bits == 16 ? 2 : 1;
        if (TIFFIsTiled(in)) {
            uint32_t inTileWidth = 0, inTileLength = 0;
            TIFFGetField(in, TIFFTAG_TILEWIDTH, &inTileWidth);
            TIFFGetField(in, TIFFTAG_TILELENGTH, &inTileLength);
            size_t inTileRowBytes = (size_t)inTileWidth * bps;
            unsigned char *tile = malloc((size_t)TIFFTileSize(in));
            if (!tile) return fail("allocation failed");
            for (uint16_t s = 0; s < spp; s++) {
                for (uint32_t y = 0; y < height; y += inTileLength) {
                    for (uint32_t x = 0; x < width; x += inTileWidth) {
                        if (TIFFReadTile(in, tile, x, y, 0, s) < 0) {
                            return fail("input tile read failed");
                        }
                        uint32_t rows = inTileLength < height - y ? inTileLength : height - y;
                        uint32_t columns = inTileWidth < width - x ? inTileWidth : width - x;
                        for (uint32_t r = 0; r < rows; r++) {
                            const unsigned char *row = tile + (size_t)r * inTileRowBytes;
                            unsigned char *outRow =
                                pixels + (size_t)(y + r) * rowBytes + (size_t)x * bps;
                            for (uint32_t c = 0; c < columns; c++) {
                                for (int b = 0; b < bps; b++) {
                                    outRow[c * spp * bps + s * bps + b] = row[c * bps + b];
                                }
                            }
                        }
                    }
                }
            }
            free(tile);
        } else {
            size_t planeRowBytes = (size_t)width * bps;
            unsigned char *row = malloc(planeRowBytes);
            if (!row) return fail("allocation failed");
            for (uint16_t s = 0; s < spp; s++) {
                for (uint32_t y = 0; y < height; y++) {
                    if (TIFFReadScanline(in, row, y, s) < 0) {
                        return fail("input scanline read failed");
                    }
                    unsigned char *outRow = pixels + (size_t)y * rowBytes + (size_t)s * bps;
                    for (uint32_t c = 0; c < width; c++) {
                        for (int b = 0; b < bps; b++) {
                            outRow[c * spp * bps + b] = row[c * bps + b];
                        }
                    }
                }
            }
            free(row);
        }
    } else if (TIFFIsTiled(in)) {
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
    /* Palette pass-through: copy the stored colormap out of the handle
     * before it is closed. */
    uint16_t *inColormap[3] = {NULL, NULL, NULL};
    int hasColormap = 0;
    if (photometric == PHOTOMETRIC_PALETTE) {
        hasColormap = TIFFGetField(in, TIFFTAG_COLORMAP, &inColormap[0], &inColormap[1],
                                   &inColormap[2]);
        if (hasColormap) {
            size_t perTable = (size_t)1 << bits;
            for (int t = 0; t < 3; t++) {
                uint16_t *copy = malloc(perTable * sizeof(uint16_t));
                memcpy(copy, inColormap[t], perTable * sizeof(uint16_t));
                inColormap[t] = copy;
            }
        }
    }
    TIFFClose(in);

    if (planarOut && paletteBits) return fail("--planar and --palette-bits are exclusive");
    if (paletteBits) {
        if (predictor == 2) return fail("palette indices take no horizontal differencing");
        if (bits < 1 || bits > 8 || spp != 1) {
            return fail("palette conversion needs a 1..8-bit single-sample input");
        }
        uint16_t mappedBits = (uint16_t)paletteBits;
        if (mappedBits != 1 && mappedBits != 2 && mappedBits != 4 && mappedBits != 8) {
            return fail("--palette-bits must be 1, 2, 4, or 8");
        }
        size_t outRowBytes = ((size_t)width * mappedBits + 7) / 8;
        unsigned char *packed = calloc(outRowBytes ? outRowBytes : 1, height);
        if (!packed) return fail("allocation failed");
        for (uint32_t y = 0; y < height; y++) {
            for (uint32_t x = 0; x < width; x++) {
                unsigned index = readPackedSample(pixels + (size_t)y * rowBytes, x, bits);
                unsigned mapped = bits == mappedBits
                    ? index
                    : bits > mappedBits ? index >> (bits - mappedBits)
                                        : index << (mappedBits - bits);
                storePackedSample(packed + (size_t)y * outRowBytes, x, mappedBits,
                                  mapped & ((1u << mappedBits) - 1u));
            }
        }
        free(pixels);
        pixels = packed;
        bits = mappedBits;
        rowBytes = outRowBytes;
        photometric = PHOTOMETRIC_PALETTE;
        hasColormap = 0; /* use the synthesized ramp below, not the input's */
    }
    if (planarOut && compression >= COMPRESSION_CCITTRLE && compression <= COMPRESSION_CCITTFAX4) {
        return fail("CCITT coding stays bilevel contiguous");
    }

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
    TIFFSetField(out, TIFFTAG_PLANARCONFIG, planarOut ? PLANARCONFIG_SEPARATE : PLANARCONFIG_CONTIG);
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
    if (photometric == PHOTOMETRIC_PALETTE) {
        if (hasColormap) {
            TIFFSetField(out, TIFFTAG_COLORMAP, inColormap[0], inColormap[1], inColormap[2]);
        } else if (paletteBits) {
            uint32_t n = 1u << bits;
            uint16_t *cr = malloc(n * sizeof(uint16_t));
            uint16_t *cg = malloc(n * sizeof(uint16_t));
            uint16_t *cb = malloc(n * sizeof(uint16_t));
            if (!cr || !cg || !cb) return fail("allocation failed");
            for (uint32_t i = 0; i < n; i++) {
                cr[i] = paletteEntry(bits, 0, i);
                cg[i] = paletteEntry(bits, 1, i);
                cb[i] = paletteEntry(bits, 2, i);
                if (legacyCmap) {
                    cr[i] >>= 8;
                    cg[i] >>= 8;
                    cb[i] >>= 8;
                }
            }
            TIFFSetField(out, TIFFTAG_COLORMAP, cr, cg, cb);
            free(cr);
            free(cg);
            free(cb);
        } else {
            return fail("palette output needs a colormap");
        }
    }
    if (tileWidth > 0 && tileLength > 0) {
        if (!TIFFSetField(out, TIFFTAG_TILEWIDTH, tileWidth)) return fail("tile width rejected");
        if (!TIFFSetField(out, TIFFTAG_TILELENGTH, tileLength)) return fail("tile length rejected");
        if ((bits < 8 || planarOut) && ((size_t)tileWidth * bits * spp) % 8 != 0) {
            return fail("tile rows are not byte aligned");
        }
        if (bits >= 8 && !planarOut) {
            size_t tileRowBytes = ((size_t)tileWidth * bits * spp + 7) / 8;
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
            /* Sub-byte depths and separate planes fill per pixel. */
            size_t tileRowBytes = ((size_t)tileWidth * bits * (planarOut ? 1 : spp) + 7) / 8;
            unsigned char *tile = calloc(tileRowBytes ? tileRowBytes : 1, tileLength);
            if (!tile) return fail("allocation failed");
            for (uint32_t y = 0; y < height; y += tileLength) {
                for (uint32_t x = 0; x < width; x += tileWidth) {
                    uint32_t rows = tileLength < height - y ? tileLength : height - y;
                    uint32_t columns = tileWidth < width - x ? tileWidth : width - x;
                    if (planarOut) {
                        for (uint16_t s = 0; s < spp; s++) {
                            memset(tile, 0, tileRowBytes * tileLength);
                            for (uint32_t r = 0; r < rows; r++) {
                                for (uint32_t c = 0; c < columns; c++) {
                                    storePackedSample(tile + (size_t)r * tileRowBytes, c, bits,
                                                      pixelSample(pixels, width, bits, spp,
                                                                  y + r, x + c, s));
                                }
                            }
                            if (TIFFWriteTile(out, tile, x, y, 0, s) < 0) {
                                return fail("tile write failed");
                            }
                        }
                    } else {
                        memset(tile, 0, tileRowBytes * tileLength);
                        for (uint32_t r = 0; r < rows; r++) {
                            for (uint32_t c = 0; c < columns; c++) {
                                for (uint16_t s = 0; s < spp; s++) {
                                    storePackedSample(tile + (size_t)r * tileRowBytes,
                                                      (size_t)c * spp + s, bits,
                                                      pixelSample(pixels, width, bits, spp,
                                                                  y + r, x + c, s));
                                }
                            }
                        }
                        if (TIFFWriteTile(out, tile, x, y, 0, 0) < 0) {
                            return fail("tile write failed");
                        }
                    }
                }
            }
            free(tile);
        }
    } else if (planarOut) {
        /* Plane-major strip writes: libtiff's sequential codecs cannot
         * jump between strips, so each plane is written whole. */
        TIFFSetField(out, TIFFTAG_ROWSPERSTRIP, rowsPerStrip > 0 ? rowsPerStrip : height);
        uint32_t rowsPer = rowsPerStrip > 0 ? rowsPerStrip : height;
        uint32_t stripsPerPlane = (height + rowsPer - 1) / rowsPer;
        size_t planeRowBytes = ((size_t)width * bits + 7) / 8;
        unsigned char *stripBuf = malloc(planeRowBytes * rowsPer);
        if (!stripBuf) return fail("allocation failed");
        for (uint16_t s = 0; s < spp; s++) {
            for (uint32_t strip = 0; strip < stripsPerPlane; strip++) {
                uint32_t stripRows = rowsPer < height - strip * rowsPer
                    ? rowsPer
                    : height - strip * rowsPer;
                for (uint32_t r = 0; r < stripRows; r++) {
                    uint32_t y = strip * rowsPer + r;
                    for (uint32_t x = 0; x < width; x++) {
                        storePackedSample(stripBuf + (size_t)r * planeRowBytes, x, bits,
                                          pixelSample(pixels, width, bits, spp, y, x, s));
                    }
                }
                if (TIFFWriteEncodedStrip(out, s * stripsPerPlane + strip, stripBuf,
                                          (tmsize_t)(stripRows * planeRowBytes)) < 0) {
                    return fail("strip write failed");
                }
            }
        }
        free(stripBuf);
    } else {
        TIFFSetField(out, TIFFTAG_ROWSPERSTRIP, rowsPerStrip > 0 ? rowsPerStrip : height);
        for (uint32_t y = 0; y < height; y++) {
            if (TIFFWriteScanline(out, pixels + (size_t)y * rowBytes, y, 0) < 0) return fail("scanline write failed");
        }
    }
    if (!TIFFWriteDirectory(out)) return fail("directory write failed");
    TIFFClose(out);
    free(pixels);
    for (int t = 0; t < 3; t++) free(inColormap[t]);
    return 0;
}
