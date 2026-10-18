/*
 * Development-only JPEG 2000 oracle built on the OpenJPEG library
 * (BSD-2-Clause). It exists because the opj_decompress/opj_compress
 * utilities cannot express two things the Unseal acceptance needs:
 *
 *   - `dump` writes every component's NATIVE samples (own width,
 *     height, dx, dy and precision) exactly as libopenjp2 decoded them,
 *     without the utility's sYCC heuristic, colour conversion,
 *     upsampling or the raw writer's "all components shall have the
 *     same subsampling" refusal.
 *   - `encode` builds a codestream from a planar sample file with a
 *     per-component grid, so 4:2:0 / 4:2:2 fixtures keep every chroma
 *     sample even at odd sizes and odd origins (the utility's raw
 *     reader reads floor(w*h/(dx*dy)) samples and zero-fills the rest).
 *
 * The library is the reference; this file never ships in the Dart
 * package and is compiled locally by tool/jpx_oracle/build.sh.
 *
 * Sample file layout (both directions): components in order, each
 * row-major with w_c x h_c samples, one byte per sample when the
 * precision is at most 8 and two little-endian bytes otherwise.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openjpeg.h>

static void on_error(const char *msg, void *client) {
    (void)client;
    fprintf(stderr, "[opj error] %s", msg);
}

static void on_warning(const char *msg, void *client) {
    (void)client;
    fprintf(stderr, "[opj warning] %s", msg);
}

static void on_info(const char *msg, void *client) {
    (void)client;
    fprintf(stderr, "[opj info] %s", msg);
}

static int ceil_div(int value, int divisor) {
    return (value + divisor - 1) / divisor;
}

static int is_jp2(const char *path) {
    unsigned char head[12];
    FILE *f = fopen(path, "rb");
    size_t n;
    if (!f) {
        return -1;
    }
    n = fread(head, 1, sizeof head, f);
    fclose(f);
    if (n < 4) {
        return -1;
    }
    if (head[0] == 0xFF && head[1] == 0x4F && head[2] == 0xFF && head[3] == 0x51) {
        return 0;
    }
    if (n >= 12 && memcmp(head, "\x00\x00\x00\x0c\x6a\x50\x20\x20", 8) == 0) {
        return 1;
    }
    return -1;
}

/* ---------------------------------------------------------------- dump */

static int dump(const char *input, const char *json_path, const char *bin_path) {
    opj_dparameters_t parameters;
    opj_codec_t *codec = NULL;
    opj_stream_t *stream = NULL;
    opj_image_t *image = NULL;
    FILE *json = NULL;
    FILE *bin = NULL;
    OPJ_UINT32 c;
    int kind = is_jp2(input);

    if (kind < 0) {
        fprintf(stderr, "dump: %s is neither a J2K codestream nor a JP2 file\n", input);
        return 2;
    }
    opj_set_default_decoder_parameters(&parameters);
    codec = opj_create_decompress(kind == 1 ? OPJ_CODEC_JP2 : OPJ_CODEC_J2K);
    opj_set_error_handler(codec, on_error, NULL);
    opj_set_warning_handler(codec, on_warning, NULL);
    opj_set_info_handler(codec, on_info, NULL);
    if (!opj_setup_decoder(codec, &parameters)) {
        fprintf(stderr, "dump: opj_setup_decoder failed\n");
        opj_destroy_codec(codec);
        return 1;
    }
    stream = opj_stream_create_default_file_stream(input, OPJ_TRUE);
    if (!stream) {
        fprintf(stderr, "dump: cannot open %s\n", input);
        opj_destroy_codec(codec);
        return 1;
    }
    if (!opj_read_header(stream, codec, &image)) {
        fprintf(stderr, "dump: opj_read_header failed\n");
        opj_stream_destroy(stream);
        opj_destroy_codec(codec);
        return 1;
    }
    if (!opj_decode(codec, stream, image) || !opj_end_decompress(codec, stream)) {
        fprintf(stderr, "dump: opj_decode failed\n");
        opj_image_destroy(image);
        opj_stream_destroy(stream);
        opj_destroy_codec(codec);
        return 1;
    }
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);

    json = fopen(json_path, "wb");
    bin = fopen(bin_path, "wb");
    if (!json || !bin) {
        fprintf(stderr, "dump: cannot write outputs\n");
        if (json) fclose(json);
        if (bin) fclose(bin);
        opj_image_destroy(image);
        return 1;
    }
    fprintf(json, "{\n  \"library\": \"%s\",\n  \"container\": \"%s\",\n", opj_version(),
            kind == 1 ? "jp2" : "j2k");
    fprintf(json, "  \"x0\": %u, \"y0\": %u, \"x1\": %u, \"y1\": %u,\n", image->x0, image->y0,
            image->x1, image->y1);
    fprintf(json, "  \"colorSpace\": %d,\n  \"numcomps\": %u,\n  \"comps\": [\n",
            (int)image->color_space, image->numcomps);
    for (c = 0; c < image->numcomps; c++) {
        opj_image_comp_t *comp = &image->comps[c];
        OPJ_UINT32 i, count = comp->w * comp->h;
        fprintf(json,
                "    {\"dx\": %u, \"dy\": %u, \"w\": %u, \"h\": %u, \"x0\": %u, \"y0\": %u, "
                "\"prec\": %u, \"sgnd\": %u, \"alpha\": %u, \"bytesPerSample\": %d}%s\n",
                comp->dx, comp->dy, comp->w, comp->h, comp->x0, comp->y0, comp->prec,
                comp->sgnd, comp->alpha, comp->prec <= 8 ? 1 : 2,
                c + 1 < image->numcomps ? "," : "");
        if (comp->sgnd || comp->prec > 16) {
            fprintf(stderr, "dump: component %u is signed or above 16 bits; refusing\n", c);
            fclose(json);
            fclose(bin);
            opj_image_destroy(image);
            return 3;
        }
        for (i = 0; i < count; i++) {
            OPJ_INT32 v = comp->data[i];
            if (comp->prec <= 8) {
                unsigned char b = (unsigned char)(v < 0 ? 0 : (v > 255 ? 255 : v));
                fwrite(&b, 1, 1, bin);
            } else {
                unsigned char b[2];
                OPJ_INT32 clipped = v < 0 ? 0 : (v > 65535 ? 65535 : v);
                b[0] = (unsigned char)(clipped & 0xFF);
                b[1] = (unsigned char)((clipped >> 8) & 0xFF);
                fwrite(b, 1, 2, bin);
            }
        }
    }
    fprintf(json, "  ]\n}\n");
    fclose(json);
    fclose(bin);
    opj_image_destroy(image);
    return 0;
}

/* -------------------------------------------------------------- encode */

typedef struct {
    int x0, y0, x1, y1;
    int numcomps;
    int dx[16], dy[16], prec[16];
    int lossless;
    float rate;
    int levels;
    int tdx, tdy, tx0, ty0;
    int mct;
    int prog;
    int cblkw, cblkh;
    int sop, eph;
    int color_space;
} encode_spec;

static int parse_spec(const char *path, encode_spec *spec) {
    char line[256];
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "encode: cannot read %s\n", path);
        return 0;
    }
    memset(spec, 0, sizeof *spec);
    spec->lossless = 1;
    spec->levels = 5;
    spec->cblkw = 64;
    spec->cblkh = 64;
    spec->color_space = OPJ_CLRSPC_UNKNOWN;
    while (fgets(line, sizeof line, f)) {
        char key[64];
        char value[128];
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        strncpy(key, line, sizeof key - 1);
        key[sizeof key - 1] = 0;
        strncpy(value, eq + 1, sizeof value - 1);
        value[sizeof value - 1] = 0;
        value[strcspn(value, "\r\n")] = 0;
        if (!strcmp(key, "x0")) spec->x0 = atoi(value);
        else if (!strcmp(key, "y0")) spec->y0 = atoi(value);
        else if (!strcmp(key, "x1")) spec->x1 = atoi(value);
        else if (!strcmp(key, "y1")) spec->y1 = atoi(value);
        else if (!strcmp(key, "comps")) spec->numcomps = atoi(value);
        else if (!strncmp(key, "comp", 4)) {
            int index = atoi(key + 4);
            if (index < 0 || index >= 16) continue;
            sscanf(value, "%d,%d,%d", &spec->dx[index], &spec->dy[index], &spec->prec[index]);
        } else if (!strcmp(key, "lossless")) spec->lossless = atoi(value);
        else if (!strcmp(key, "rate")) spec->rate = (float)atof(value);
        else if (!strcmp(key, "levels")) spec->levels = atoi(value);
        else if (!strcmp(key, "tile")) sscanf(value, "%d,%d,%d,%d", &spec->tdx, &spec->tdy, &spec->tx0, &spec->ty0);
        else if (!strcmp(key, "mct")) spec->mct = atoi(value);
        else if (!strcmp(key, "prog")) spec->prog = !strcmp(value, "RLCP") ? 1 : 0;
        else if (!strcmp(key, "cblk")) sscanf(value, "%d,%d", &spec->cblkw, &spec->cblkh);
        else if (!strcmp(key, "sop")) spec->sop = atoi(value);
        else if (!strcmp(key, "eph")) spec->eph = atoi(value);
        else if (!strcmp(key, "colorspace")) {
            if (!strcmp(value, "gray")) spec->color_space = OPJ_CLRSPC_GRAY;
            else if (!strcmp(value, "srgb")) spec->color_space = OPJ_CLRSPC_SRGB;
            else if (!strcmp(value, "sycc")) spec->color_space = OPJ_CLRSPC_SYCC;
            else spec->color_space = OPJ_CLRSPC_UNKNOWN;
        }
    }
    fclose(f);
    if (spec->numcomps < 1 || spec->numcomps > 16 || spec->x1 <= spec->x0 || spec->y1 <= spec->y0) {
        fprintf(stderr, "encode: spec geometry is invalid\n");
        return 0;
    }
    return 1;
}

static int encode(const char *spec_path, const char *samples_path, const char *output) {
    encode_spec spec;
    opj_cparameters_t parameters;
    opj_image_cmptparm_t cmptparm[16];
    opj_image_t *image = NULL;
    opj_codec_t *codec = NULL;
    opj_stream_t *stream = NULL;
    FILE *samples;
    int c;
    size_t name_length;
    int jp2;

    if (!parse_spec(spec_path, &spec)) {
        return 2;
    }
    name_length = strlen(output);
    jp2 = name_length > 4 && !strcmp(output + name_length - 4, ".jp2");

    /*
     * The encoder reads each input component with the stride
     * ceildiv(x1 - x0, dx) (opj_j2k_get_tile_data) although the
     * normative component width is ceil(x1/dx) - ceil(x0/dx); the two
     * differ when the image origin is not a multiple of dx. The buffer
     * therefore uses the encoder's stride while only the normative
     * columns and rows are filled from the sample file.
     */
    memset(cmptparm, 0, sizeof cmptparm);
    for (c = 0; c < spec.numcomps; c++) {
        cmptparm[c].dx = (OPJ_UINT32)spec.dx[c];
        cmptparm[c].dy = (OPJ_UINT32)spec.dy[c];
        cmptparm[c].prec = (OPJ_UINT32)spec.prec[c];
        cmptparm[c].sgnd = 0;
        cmptparm[c].x0 = (OPJ_UINT32)spec.x0;
        cmptparm[c].y0 = (OPJ_UINT32)spec.y0;
        cmptparm[c].w = (OPJ_UINT32)ceil_div(spec.x1 - spec.x0, spec.dx[c]);
        cmptparm[c].h = (OPJ_UINT32)ceil_div(spec.y1 - spec.y0, spec.dy[c]);
    }
    image = opj_image_create((OPJ_UINT32)spec.numcomps, cmptparm, (OPJ_COLOR_SPACE)spec.color_space);
    if (!image) {
        fprintf(stderr, "encode: opj_image_create failed\n");
        return 1;
    }
    image->x0 = (OPJ_UINT32)spec.x0;
    image->y0 = (OPJ_UINT32)spec.y0;
    image->x1 = (OPJ_UINT32)spec.x1;
    image->y1 = (OPJ_UINT32)spec.y1;

    samples = fopen(samples_path, "rb");
    if (!samples) {
        fprintf(stderr, "encode: cannot read %s\n", samples_path);
        opj_image_destroy(image);
        return 1;
    }
    for (c = 0; c < spec.numcomps; c++) {
        opj_image_comp_t *comp = &image->comps[c];
        OPJ_UINT32 stride = comp->w;
        OPJ_UINT32 useful_w = (OPJ_UINT32)(ceil_div(spec.x1, spec.dx[c]) - ceil_div(spec.x0, spec.dx[c]));
        OPJ_UINT32 useful_h = (OPJ_UINT32)(ceil_div(spec.y1, spec.dy[c]) - ceil_div(spec.y0, spec.dy[c]));
        OPJ_UINT32 row, col;
        for (row = 0; row < useful_h; row++) {
            for (col = 0; col < useful_w; col++) {
                unsigned char b[2];
                size_t need = comp->prec <= 8 ? 1 : 2;
                if (fread(b, 1, need, samples) != need) {
                    fprintf(stderr, "encode: sample file is shorter than the declared geometry\n");
                    fclose(samples);
                    opj_image_destroy(image);
                    return 1;
                }
                comp->data[row * stride + col] = need == 1 ? b[0] : (b[0] | (b[1] << 8));
            }
        }
    }
    if (fgetc(samples) != EOF) {
        fprintf(stderr, "encode: sample file is longer than the declared geometry\n");
        fclose(samples);
        opj_image_destroy(image);
        return 1;
    }
    fclose(samples);

    opj_set_default_encoder_parameters(&parameters);
    parameters.tcp_numlayers = 1;
    parameters.cp_disto_alloc = 1;
    parameters.tcp_rates[0] = spec.lossless ? 0 : spec.rate;
    parameters.irreversible = spec.lossless ? 0 : 1;
    parameters.numresolution = spec.levels + 1;
    parameters.tcp_mct = (char)spec.mct;
    parameters.prog_order = spec.prog == 1 ? OPJ_RLCP : OPJ_LRCP;
    parameters.cblockw_init = spec.cblkw;
    parameters.cblockh_init = spec.cblkh;
    parameters.image_offset_x0 = spec.x0;
    parameters.image_offset_y0 = spec.y0;
    if (spec.sop) parameters.csty |= 0x02;
    if (spec.eph) parameters.csty |= 0x04;
    if (spec.tdx > 0 && spec.tdy > 0) {
        parameters.tile_size_on = OPJ_TRUE;
        parameters.cp_tdx = spec.tdx;
        parameters.cp_tdy = spec.tdy;
        parameters.cp_tx0 = spec.tx0;
        parameters.cp_ty0 = spec.ty0;
    }
    strncpy(parameters.outfile, output, sizeof parameters.outfile - 1);

    codec = opj_create_compress(jp2 ? OPJ_CODEC_JP2 : OPJ_CODEC_J2K);
    opj_set_error_handler(codec, on_error, NULL);
    opj_set_warning_handler(codec, on_warning, NULL);
    opj_set_info_handler(codec, on_info, NULL);
    if (!opj_setup_encoder(codec, &parameters, image)) {
        fprintf(stderr, "encode: opj_setup_encoder failed\n");
        opj_destroy_codec(codec);
        opj_image_destroy(image);
        return 1;
    }
    stream = opj_stream_create_default_file_stream(output, OPJ_FALSE);
    if (!stream) {
        fprintf(stderr, "encode: cannot create %s\n", output);
        opj_destroy_codec(codec);
        opj_image_destroy(image);
        return 1;
    }
    if (!opj_start_compress(codec, image, stream) || !opj_encode(codec, stream) ||
        !opj_end_compress(codec, stream)) {
        fprintf(stderr, "encode: compression failed\n");
        opj_stream_destroy(stream);
        opj_destroy_codec(codec);
        opj_image_destroy(image);
        return 1;
    }
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    opj_image_destroy(image);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "version")) {
        printf("openjp2 %s\n", opj_version());
        return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "dump")) {
        return dump(argv[2], argv[3], argv[4]);
    }
    if (argc == 5 && !strcmp(argv[1], "encode")) {
        return encode(argv[2], argv[3], argv[4]);
    }
    fprintf(stderr,
            "usage:\n"
            "  opj_oracle version\n"
            "  opj_oracle dump <input.j2k|jp2> <out.json> <out.bin>\n"
            "  opj_oracle encode <spec.txt> <samples.bin> <out.j2k|jp2>\n");
    return 2;
}
