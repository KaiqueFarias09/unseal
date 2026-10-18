/*
 * Dumps every directory of a TIFF through libtiff so Unseal's decoder can
 * be compared against an independent implementation at two levels:
 *
 *   <prefix>.pN.native  samples as libtiff decodes them (codec + predictor
 *                       applied, host byte order, FillOrder normalized to
 *                       MSB-first, sub-byte depths unpacked to one byte per
 *                       sample, no orientation applied, no cropping beyond
 *                       the declared image size). Planar-separate pages are
 *                       assembled from per-band reads, plane 0 first, so the
 *                       interleaved layout matches a contiguous page;
 *   <prefix>.pN.rgba    TIFFReadRGBAImageOriented(ORIENTATION_TOPLEFT), the
 *                       display conversion libtiff ships (tiff2rgba level);
 *   <prefix>.pN.colormap  the raw ColorMap of a palette page (photometric 3)
 *                       as stored: 3 * 2^BitsPerSample little-endian uint16
 *                       values in red, green, blue table order.
 *
 * <prefix>.json records the layout tags of each directory, the status of
 * both dumps, and every libtiff warning/error raised while reading.
 *
 * Build: cc -O2 -o tiff_oracle_dump tiff_oracle_dump.c \
 *          -I/opt/homebrew/include -L/opt/homebrew/lib -ltiff
 * Usage: tiff_oracle_dump --version | <input.tif> <output-prefix>
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <tiffio.h>
#include <tiffvers.h>

static char diagnostics[1 << 16];
static size_t diagnosticsLength;

static void appendDiagnostic(const char *kind, const char *module, const char *fmt, va_list ap) {
    char line[2048];
    int n = snprintf(line, sizeof line, "%s %s: ", kind, module ? module : "libtiff");
    if (n < 0) return;
    size_t used = (size_t)n;
    if (used < sizeof line) {
        int m = vsnprintf(line + used, sizeof line - used, fmt, ap);
        if (m > 0) used += (size_t)m;
        if (used >= sizeof line) used = sizeof line - 1;
    }
    if (diagnosticsLength + used + 2 >= sizeof diagnostics) return;
    memcpy(diagnostics + diagnosticsLength, line, used);
    diagnosticsLength += used;
    diagnostics[diagnosticsLength++] = '\n';
    diagnostics[diagnosticsLength] = '\0';
}

static void onError(const char *module, const char *fmt, va_list ap) {
    appendDiagnostic("error", module, fmt, ap);
}

static void onWarning(const char *module, const char *fmt, va_list ap) {
    appendDiagnostic("warning", module, fmt, ap);
}

static void writeJsonString(FILE *out, const char *text) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '"' || *p == '\\') {
            fputc('\\', out);
            fputc(*p, out);
        } else if (*p == '\n') {
            fputs("\\n", out);
        } else if (*p < 0x20) {
            fprintf(out, "\\u%04x", *p);
        } else {
            fputc(*p, out);
        }
    }
    fputc('"', out);
}

static unsigned readSample(const unsigned char *row, uint32_t index, uint16_t bits) {
    if (bits == 8) return row[index];
    if (bits == 16) return ((const uint16_t *)row)[index];
    uint32_t bitOffset = index * bits;
    unsigned byte = row[bitOffset >> 3];
    int shift = 8 - bits - (int)(bitOffset & 7);
    return (byte >> shift) & ((1u << bits) - 1u);
}

static void storeSample(unsigned char *out, size_t index, unsigned value, int bytesPerSample) {
    if (bytesPerSample == 1) {
        out[index] = (unsigned char)value;
    } else {
        ((uint16_t *)out)[index] = (uint16_t)value;
    }
}

/* Returns NULL on success or a static status string on failure. */
static const char *dumpNative(TIFF *tif, uint32_t width, uint32_t height, uint16_t bits,
                              uint16_t spp, uint16_t planar, const char *path) {
    if (bits != 1 && bits != 2 && bits != 4 && bits != 8 && bits != 16) return "depth-not-dumped";
    int bytesPerSample = bits == 16 ? 2 : 1;
    size_t samples = (size_t)width * height * spp;
    unsigned char *out = calloc(samples, (size_t)bytesPerSample);
    if (!out) return "allocation-failed";
    const char *status = NULL;
    if (TIFFIsTiled(tif)) {
        uint32_t tileWidth = 0, tileLength = 0;
        TIFFGetField(tif, TIFFTAG_TILEWIDTH, &tileWidth);
        TIFFGetField(tif, TIFFTAG_TILELENGTH, &tileLength);
        tmsize_t tileSize = TIFFTileSize(tif);
        tmsize_t tileRowBytes = TIFFTileRowSize(tif);
        unsigned char *tile = tileSize > 0 ? malloc((size_t)tileSize) : NULL;
        if (!tile || tileWidth == 0 || tileLength == 0) {
            free(tile);
            free(out);
            return "tile-geometry-invalid";
        }
        if (planar == PLANARCONFIG_SEPARATE) {
            /* Plane-major reads: libtiff's codecs decode a plane's tiles
             * sequentially, so the bands are walked one at a time. */
            for (uint16_t s = 0; s < spp && !status; s++) {
                for (uint32_t y = 0; y < height && !status; y += tileLength) {
                    for (uint32_t x = 0; x < width && !status; x += tileWidth) {
                        if (TIFFReadTile(tif, tile, x, y, 0, s) < 0) {
                            status = "tile-read-failed";
                            break;
                        }
                        uint32_t rows = tileLength < height - y ? tileLength : height - y;
                        uint32_t columns = tileWidth < width - x ? tileWidth : width - x;
                        for (uint32_t r = 0; r < rows; r++) {
                            const unsigned char *row = tile + (size_t)r * tileRowBytes;
                            for (uint32_t c = 0; c < columns; c++) {
                                unsigned value = readSample(row, c, bits);
                                size_t index = ((size_t)(y + r) * width + (x + c)) * spp + s;
                                storeSample(out, index, value, bytesPerSample);
                            }
                        }
                    }
                }
            }
        } else {
            for (uint32_t y = 0; y < height && !status; y += tileLength) {
                for (uint32_t x = 0; x < width && !status; x += tileWidth) {
                    if (TIFFReadTile(tif, tile, x, y, 0, 0) < 0) {
                        status = "tile-read-failed";
                        break;
                    }
                    uint32_t rows = tileLength < height - y ? tileLength : height - y;
                    uint32_t columns = tileWidth < width - x ? tileWidth : width - x;
                    for (uint32_t r = 0; r < rows; r++) {
                        const unsigned char *row = tile + (size_t)r * tileRowBytes;
                        for (uint32_t c = 0; c < columns; c++) {
                            for (uint16_t s = 0; s < spp; s++) {
                                unsigned value = readSample(row, c * spp + s, bits);
                                size_t index = ((size_t)(y + r) * width + (x + c)) * spp + s;
                                storeSample(out, index, value, bytesPerSample);
                            }
                        }
                    }
                }
            }
        }
        free(tile);
    } else {
        tmsize_t scanline = TIFFScanlineSize(tif);
        unsigned char *row = scanline > 0 ? malloc((size_t)scanline) : NULL;
        if (!row) {
            free(out);
            return "scanline-geometry-invalid";
        }
        if (planar == PLANARCONFIG_SEPARATE) {
            for (uint16_t s = 0; s < spp && !status; s++) {
                for (uint32_t y = 0; y < height && !status; y++) {
                    if (TIFFReadScanline(tif, row, y, s) < 0) {
                        status = "scanline-read-failed";
                        break;
                    }
                    for (uint32_t c = 0; c < width; c++) {
                        unsigned value = readSample(row, c, bits);
                        size_t index = ((size_t)y * width + c) * spp + s;
                        storeSample(out, index, value, bytesPerSample);
                    }
                }
            }
        } else {
            for (uint32_t y = 0; y < height && !status; y++) {
                if (TIFFReadScanline(tif, row, y, 0) < 0) {
                    status = "scanline-read-failed";
                    break;
                }
                for (uint32_t c = 0; c < width; c++) {
                    for (uint16_t s = 0; s < spp; s++) {
                        unsigned value = readSample(row, c * spp + s, bits);
                        size_t index = ((size_t)y * width + c) * spp + s;
                        storeSample(out, index, value, bytesPerSample);
                    }
                }
            }
        }
        free(row);
    }
    if (!status) {
        FILE *file = fopen(path, "wb");
        if (!file || fwrite(out, (size_t)bytesPerSample, samples, file) != samples) {
            status = "native-write-failed";
        }
        if (file) fclose(file);
    }
    free(out);
    return status;
}

/* Dumps the raw ColorMap of a palette page: 3 * 2^bits uint16 values in
 * red, green, blue order, host byte order (little-endian here). */
static const char *dumpColormap(TIFF *tif, uint16_t bits, const char *path, uint32_t *entries) {
    uint16_t *red = NULL, *green = NULL, *blue = NULL;
    if (!TIFFGetField(tif, TIFFTAG_COLORMAP, &red, &green, &blue)) return "colormap-missing";
    if (bits > 16) return "depth-not-dumped";
    size_t perTable = (size_t)1 << bits;
    uint16_t *out = malloc(perTable * 3 * sizeof(uint16_t));
    if (!out) return "allocation-failed";
    memcpy(out, red, perTable * sizeof(uint16_t));
    memcpy(out + perTable, green, perTable * sizeof(uint16_t));
    memcpy(out + perTable * 2, blue, perTable * sizeof(uint16_t));
    *entries = (uint32_t)(perTable * 3);
    const char *status = NULL;
    FILE *file = fopen(path, "wb");
    if (!file || fwrite(out, sizeof(uint16_t), perTable * 3, file) != perTable * 3) {
        status = "colormap-write-failed";
    }
    if (file) fclose(file);
    free(out);
    return status;
}

static const char *dumpRgba(TIFF *tif, uint32_t width, uint32_t height, const char *path) {
    size_t pixels = (size_t)width * height;
    uint32_t *raster = (uint32_t *)_TIFFmalloc((tmsize_t)(pixels * sizeof(uint32_t)));
    if (!raster) return "allocation-failed";
    if (!TIFFReadRGBAImageOriented(tif, width, height, raster, ORIENTATION_TOPLEFT, 1)) {
        _TIFFfree(raster);
        return "rgba-read-failed";
    }
    unsigned char *bytes = malloc(pixels * 4);
    if (!bytes) {
        _TIFFfree(raster);
        return "allocation-failed";
    }
    for (size_t i = 0; i < pixels; i++) {
        uint32_t v = raster[i];
        bytes[i * 4] = (unsigned char)TIFFGetR(v);
        bytes[i * 4 + 1] = (unsigned char)TIFFGetG(v);
        bytes[i * 4 + 2] = (unsigned char)TIFFGetB(v);
        bytes[i * 4 + 3] = (unsigned char)TIFFGetA(v);
    }
    _TIFFfree(raster);
    const char *status = NULL;
    FILE *file = fopen(path, "wb");
    if (!file || fwrite(bytes, 4, pixels, file) != pixels) status = "rgba-write-failed";
    if (file) fclose(file);
    free(bytes);
    return status;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("%s\nTIFFLIB_VERSION %d\n", TIFFGetVersion(), TIFFLIB_VERSION);
        return 0;
    }
    if (argc != 3) {
        fprintf(stderr, "usage: %s --version | <input.tif> <output-prefix>\n", argv[0]);
        return 64;
    }
    TIFFSetErrorHandler(onError);
    TIFFSetWarningHandler(onWarning);
    const char *input = argv[1];
    const char *prefix = argv[2];
    char jsonPath[4096];
    snprintf(jsonPath, sizeof jsonPath, "%s.json", prefix);
    FILE *json = fopen(jsonPath, "w");
    if (!json) {
        fprintf(stderr, "cannot write %s\n", jsonPath);
        return 1;
    }
    fputs("{\n  \"tool\": \"tiff_oracle_dump\",\n  \"libtiff\": ", json);
    writeJsonString(json, TIFFGetVersion());
    fprintf(json, ",\n  \"libtiffVersion\": %d,\n  \"input\": ", TIFFLIB_VERSION);
    writeJsonString(json, input);
    TIFF *tif = TIFFOpen(input, "r");
    if (!tif) {
        fputs(",\n  \"openStatus\": \"open-failed\",\n  \"diagnostics\": ", json);
        writeJsonString(json, diagnostics);
        fputs(",\n  \"directories\": []\n}\n", json);
        fclose(json);
        return 0;
    }
    fputs(",\n  \"openStatus\": \"opened\",\n  \"openDiagnostics\": ", json);
    writeJsonString(json, diagnostics);
    fputs(",\n  \"directories\": [", json);
    int index = 0;
    do {
        diagnosticsLength = 0;
        diagnostics[0] = '\0';
        uint32_t width = 0, height = 0, tileWidth = 0, tileLength = 0, rowsPerStrip = 0;
        uint16_t bits = 1, spp = 1, photometric = 0xFFFF, compression = 1, planar = 1;
        uint16_t orientation = 1, fillOrder = 1, predictor = 1, sampleFormat = 1;
        TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &width);
        TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &height);
        TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &bits);
        TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &spp);
        TIFFGetField(tif, TIFFTAG_PHOTOMETRIC, &photometric);
        TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &compression);
        TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &planar);
        TIFFGetFieldDefaulted(tif, TIFFTAG_ORIENTATION, &orientation);
        TIFFGetFieldDefaulted(tif, TIFFTAG_FILLORDER, &fillOrder);
        TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLEFORMAT, &sampleFormat);
        if (!TIFFGetField(tif, TIFFTAG_PREDICTOR, &predictor)) predictor = 1;
        int tiled = TIFFIsTiled(tif);
        if (tiled) {
            TIFFGetField(tif, TIFFTAG_TILEWIDTH, &tileWidth);
            TIFFGetField(tif, TIFFTAG_TILELENGTH, &tileLength);
        } else {
            TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &rowsPerStrip);
        }
        char nativePath[4096], rgbaPath[4096], colormapPath[4096];
        snprintf(nativePath, sizeof nativePath, "%s.p%d.native", prefix, index + 1);
        snprintf(rgbaPath, sizeof rgbaPath, "%s.p%d.rgba", prefix, index + 1);
        snprintf(colormapPath, sizeof colormapPath, "%s.p%d.colormap", prefix, index + 1);
        const char *nativeStatus = NULL;
        const char *rgbaStatus = NULL;
        const char *colormapStatus = NULL;
        uint32_t colormapEntries = 0;
        if (width == 0 || height == 0) {
            nativeStatus = "empty-geometry";
            rgbaStatus = "empty-geometry";
        } else {
            nativeStatus = dumpNative(tif, width, height, bits, spp, planar, nativePath);
            rgbaStatus = dumpRgba(tif, width, height, rgbaPath);
            if (photometric == PHOTOMETRIC_PALETTE) {
                colormapStatus = dumpColormap(tif, bits, colormapPath, &colormapEntries);
            }
        }
        fprintf(json, "%s\n    {\n      \"index\": %d,\n      \"width\": %u,\n      \"height\": %u,\n",
                index == 0 ? "" : ",", index, width, height);
        fprintf(json, "      \"bitsPerSample\": %u,\n      \"samplesPerPixel\": %u,\n", bits, spp);
        fprintf(json, "      \"photometric\": %d,\n      \"compression\": %u,\n",
                photometric == 0xFFFF ? -1 : (int)photometric, compression);
        fprintf(json, "      \"planarConfiguration\": %u,\n      \"orientation\": %u,\n", planar,
                orientation);
        fprintf(json, "      \"fillOrder\": %u,\n      \"predictor\": %u,\n      \"sampleFormat\": %u,\n",
                fillOrder, predictor, sampleFormat);
        fprintf(json, "      \"tiled\": %s,\n      \"tileWidth\": %u,\n      \"tileLength\": %u,\n",
                tiled ? "true" : "false", tileWidth, tileLength);
        fprintf(json, "      \"rowsPerStrip\": %u,\n", rowsPerStrip);
        fputs("      \"nativeFile\": ", json);
        if (nativeStatus) {
            fputs("null", json);
        } else {
            writeJsonString(json, nativePath);
        }
        fputs(",\n      \"nativeStatus\": ", json);
        writeJsonString(json, nativeStatus ? nativeStatus : "ok");
        fputs(",\n      \"rgbaFile\": ", json);
        if (rgbaStatus) {
            fputs("null", json);
        } else {
            writeJsonString(json, rgbaPath);
        }
        fputs(",\n      \"rgbaStatus\": ", json);
        writeJsonString(json, rgbaStatus ? rgbaStatus : "ok");
        fputs(",\n      \"colormapFile\": ", json);
        if (photometric == PHOTOMETRIC_PALETTE && !colormapStatus) {
            writeJsonString(json, colormapPath);
        } else {
            fputs("null", json);
        }
        fputs(",\n      \"colormapStatus\": ", json);
        if (photometric == PHOTOMETRIC_PALETTE) {
            writeJsonString(json, colormapStatus ? colormapStatus : "ok");
        } else {
            fputs("\"not-palette\"", json);
        }
        fprintf(json, ",\n      \"colormapEntries\": %u", colormapEntries);
        fputs(",\n      \"diagnostics\": ", json);
        writeJsonString(json, diagnostics);
        fputs("\n    }", json);
        index++;
    } while (TIFFReadDirectory(tif));
    diagnosticsLength = 0;
    diagnostics[0] = '\0';
    TIFFClose(tif);
    fprintf(json, "\n  ],\n  \"directoryCount\": %d\n}\n", index);
    fclose(json);
    return 0;
}
