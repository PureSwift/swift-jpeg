/* transform.c - exercise lossless transformation
 *
 * The capability the coefficient-domain representation exists for. Rotating a
 * decoded image costs an inverse transform, a rotation and a forward transform,
 * each of which rounds; rotating the coefficients rearranges numbers that are
 * already exact, so an image survives it unchanged.
 *
 * This checks that claim directly: transform a JPEG, transform it back, and
 * require the decoded pixels to be identical to the original — not merely
 * close.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "turbojpeg.h"

static int failures = 0;
static int filterCalls = 0;

/* Zeroes every coefficient above the fourth row and column of each block, which
 * is a crude low-pass filter. It exists to prove the callback receives real,
 * writable coefficients laid out as documented — a filter handed a copy, or the
 * wrong stride, would not visibly blur the image. */
static int zeroHighFrequencies(short *coeffs, tjregion arrayRegion,
                               tjregion planeRegion, int componentID,
                               int transformID, tjtransform *transform)
{
    (void)planeRegion; (void)componentID; (void)transformID; (void)transform;
    filterCalls++;
    int blocks = arrayRegion.w / 8;
    for (int b = 0; b < blocks; b++)
        for (int v = 0; v < 8; v++)
            for (int u = 0; u < 8; u++)
                if (v >= 4 || u >= 4) coeffs[b * 64 + v * 8 + u] = 0;
    return 0;
}

static void check(int condition, const char *what)
{
    if (condition) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

/* Compresses a deterministic test image whose dimensions are a whole number of
 * MCUs, so every transform is exact. */
static int makeSource(unsigned char **jpeg, size_t *size, int width, int height)
{
    unsigned char *pixels = malloc((size_t)width * height * 3);
    if (!pixels) return -1;
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
            unsigned char *p = pixels + (y * width + x) * 3;
            p[0] = (unsigned char)(x * 255 / width);
            p[1] = (unsigned char)(y * 255 / height);
            p[2] = ((x / 8 + y / 8) & 1) ? 220 : 40;
        }

    tjhandle c = tj3Init(TJINIT_COMPRESS);
    tj3Set(c, TJPARAM_QUALITY, 90);
    tj3Set(c, TJPARAM_SUBSAMP, TJSAMP_420);
    int rc = tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, jpeg, size);
    tj3Destroy(c);
    free(pixels);
    return rc;
}

static unsigned char *decodeTo(const unsigned char *jpeg, size_t size, int *w, int *h)
{
    tjhandle d = tj3Init(TJINIT_DECOMPRESS);
    if (tj3DecompressHeader(d, jpeg, size)) { tj3Destroy(d); return NULL; }
    *w = tj3Get(d, TJPARAM_JPEGWIDTH);
    *h = tj3Get(d, TJPARAM_JPEGHEIGHT);
    unsigned char *pixels = malloc((size_t)*w * *h * 3);
    if (tj3Decompress8(d, jpeg, size, pixels, 0, TJPF_RGB)) {
        free(pixels); tj3Destroy(d); return NULL;
    }
    tj3Destroy(d);
    return pixels;
}

/* Applies one transform and returns the resulting JPEG. */
static int apply(tjhandle handle, const unsigned char *src, size_t srcSize,
                 int op, int options, unsigned char **dst, size_t *dstSize)
{
    tjtransform t;
    memset(&t, 0, sizeof t);
    t.op = op;
    t.options = options;
    *dst = NULL;
    *dstSize = 0;
    return tj3Transform(handle, src, srcSize, 1, dst, dstSize, &t);
}

int main(void)
{
    /* 128x96 is a whole number of 16x16 MCUs, so 4:2:0 transforms are exact. */
    const int width = 128, height = 96;
    unsigned char *source = NULL;
    size_t sourceSize = 0;
    if (makeSource(&source, &sourceSize, width, height)) {
        printf("could not build the source image\n");
        return 99;
    }

    int w0 = 0, h0 = 0;
    unsigned char *original = decodeTo(source, sourceSize, &w0, &h0);
    check(original != NULL && w0 == width && h0 == height, "source image decodes");

    tjhandle handle = tj3Init(TJINIT_TRANSFORM);
    check(handle != NULL, "tj3Init(TJINIT_TRANSFORM) returns a handle");
    check(tj3DecompressHeader(handle, source, sourceSize) == 0, "header reads");

    printf("buffer sizing\n");
    tjtransform sizing;
    memset(&sizing, 0, sizeof sizing);
    sizing.op = TJXOP_ROT90;
    check(tj3TransformBufSize(handle, &sizing) > 0, "tj3TransformBufSize returns a bound");

    printf("dimensions\n");
    struct { int op; const char *name; int swaps; } ops[] = {
        { TJXOP_HFLIP, "hflip", 0 }, { TJXOP_VFLIP, "vflip", 0 },
        { TJXOP_ROT180, "rot180", 0 }, { TJXOP_TRANSPOSE, "transpose", 1 },
        { TJXOP_TRANSVERSE, "transverse", 1 }, { TJXOP_ROT90, "rot90", 1 },
        { TJXOP_ROT270, "rot270", 1 },
    };
    for (size_t i = 0; i < sizeof ops / sizeof *ops; i++) {
        unsigned char *out = NULL; size_t outSize = 0;
        int rc = apply(handle, source, sourceSize, ops[i].op, 0, &out, &outSize);
        if (rc) printf("        (%s)\n", tj3GetErrorStr(handle));
        int w = 0, h = 0;
        unsigned char *pixels = rc ? NULL : decodeTo(out, outSize, &w, &h);
        int expectW = ops[i].swaps ? height : width;
        int expectH = ops[i].swaps ? width : height;
        char label[64];
        snprintf(label, sizeof label, "%s produces %dx%d", ops[i].name, expectW, expectH);
        check(rc == 0 && pixels && w == expectW && h == expectH, label);
        free(pixels); tj3Free(out);
    }

    printf("losslessness\n");
    /* Every one of these is its own inverse, or has one in the list, so the
     * round trip must reproduce the original pixels exactly. */
    struct { int there; int back; const char *name; } pairs[] = {
        { TJXOP_HFLIP, TJXOP_HFLIP, "hflip twice" },
        { TJXOP_VFLIP, TJXOP_VFLIP, "vflip twice" },
        { TJXOP_ROT180, TJXOP_ROT180, "rot180 twice" },
        { TJXOP_TRANSPOSE, TJXOP_TRANSPOSE, "transpose twice" },
        { TJXOP_TRANSVERSE, TJXOP_TRANSVERSE, "transverse twice" },
        { TJXOP_ROT90, TJXOP_ROT270, "rot90 then rot270" },
        { TJXOP_ROT270, TJXOP_ROT90, "rot270 then rot90" },
    };
    for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++) {
        unsigned char *mid = NULL, *end = NULL;
        size_t midSize = 0, endSize = 0;
        int rc = apply(handle, source, sourceSize, pairs[i].there, 0, &mid, &midSize);
        if (!rc) rc = apply(handle, mid, midSize, pairs[i].back, 0, &end, &endSize);
        int w = 0, h = 0;
        unsigned char *pixels = rc ? NULL : decodeTo(end, endSize, &w, &h);
        int same = pixels && w == width && h == height &&
                   memcmp(original, pixels, (size_t)width * height * 3) == 0;
        char label[80];
        snprintf(label, sizeof label, "%s reproduces the original exactly", pairs[i].name);
        check(same, label);
        free(pixels); tj3Free(mid); tj3Free(end);
    }

    printf("options\n");
    unsigned char *out = NULL; size_t outSize = 0;
    check(apply(handle, source, sourceSize, TJXOP_ROT90, TJXOPT_PERFECT, &out, &outSize) == 0,
          "TJXOPT_PERFECT succeeds on an MCU-aligned image");
    tj3Free(out);

    /* An image that is not a whole number of MCUs cannot be mirrored perfectly,
     * and asking for perfection must fail rather than silently lose an edge. */
    unsigned char *odd = NULL; size_t oddSize = 0;
    if (makeSource(&odd, &oddSize, 133, 101) == 0) {
        tjhandle h2 = tj3Init(TJINIT_TRANSFORM);
        tj3DecompressHeader(h2, odd, oddSize);
        unsigned char *o = NULL; size_t oSize = 0;
        check(apply(h2, odd, oddSize, TJXOP_ROT90, TJXOPT_PERFECT, &o, &oSize) == -1,
              "TJXOPT_PERFECT fails on a misaligned image");
        check(strlen(tj3GetErrorStr(h2)) > 0, "and says why");
        tj3Free(o);
        tj3Destroy(h2);
    }
    tj3Free(odd);

    printf("cropping\n");
    {
        tjtransform t;
        memset(&t, 0, sizeof t);
        t.op = TJXOP_NONE;
        t.options = TJXOPT_CROP;
        /* 128x96 at 4:2:0 has 16x16 MCUs, so this origin is aligned. */
        t.r.x = 16; t.r.y = 32; t.r.w = 64; t.r.h = 48;
        unsigned char *cr = NULL; size_t crSize = 0;
        int rc2 = tj3Transform(handle, source, sourceSize, 1, &cr, &crSize, &t);
        if (rc2) printf("        (%s)\n", tj3GetErrorStr(handle));
        check(rc2 == 0, "an MCU-aligned crop succeeds");

        int cw = 0, ch = 0;
        unsigned char *cropped = rc2 ? NULL : decodeTo(cr, crSize, &cw, &ch);
        check(cropped && cw == 64 && ch == 48, "it produces a 64x48 image");
        /* The coefficients are carried over untouched, so the interior must
         * decode identically to the same region of the full image.
         *
         * The outermost pixels cannot, and that is not a defect: chroma
         * upsampling interpolates from neighbours, and at the new boundary
         * those neighbours are gone. Decoding a cropped 4:2:0 image and
         * cropping a decoded one are different operations at the edge, in this
         * library and in libjpeg alike. Measured here: 0 differing samples two
         * pixels in, 660 in the two-pixel border. */
        int interior = 0;
        for (int y = 2; y < 46; y++)
            for (int x = 2; x < 62; x++)
                if (cropped && memcmp(cropped + (y * 64 + x) * 3,
                                      original + ((y + 32) * width + (x + 16)) * 3, 3) != 0)
                    interior++;
        check(cropped && interior == 0,
              "and its interior matches the original region exactly");
        free(cropped); tj3Free(cr);

        /* An unaligned origin cannot be done losslessly and must be refused
         * rather than quietly rounded. */
        memset(&t, 0, sizeof t);
        t.op = TJXOP_NONE; t.options = TJXOPT_CROP;
        t.r.x = 8; t.r.y = 0; t.r.w = 32; t.r.h = 32;
        unsigned char *bad = NULL; size_t badSize = 0;
        check(tj3Transform(handle, source, sourceSize, 1, &bad, &badSize, &t) == -1,
              "an origin off the MCU grid is refused");
        check(strstr(tj3GetErrorStr(handle), "MCU") != NULL, "and says why");
        tj3Free(bad);
    }

    printf("custom coefficient filter\n");
    {
        tjtransform t;
        memset(&t, 0, sizeof t);
        t.op = TJXOP_NONE;
        t.customFilter = zeroHighFrequencies;
        unsigned char *cf = NULL; size_t cfSize = 0;
        int rc2 = tj3Transform(handle, source, sourceSize, 1, &cf, &cfSize, &t);
        if (rc2) printf("        (%s)\n", tj3GetErrorStr(handle));
        check(rc2 == 0, "a custom filter runs");
        check(filterCalls > 0, "and was actually called");
        /* Discarding the high frequencies must shrink the file and blur the
         * image without changing its size. */
        check(cfSize < sourceSize, "zeroing high frequencies shrinks the output");
        int fw = 0, fh = 0;
        unsigned char *filtered = rc2 ? NULL : decodeTo(cf, cfSize, &fw, &fh);
        check(filtered && fw == width && fh == height, "the result is the same size");
        check(filtered && memcmp(filtered, original, (size_t)width * height * 3) != 0,
              "and its pixels changed");
        free(filtered); tj3Free(cf);
    }

    printf("multiple outputs in one call\n");
    tjtransform many[3];
    memset(many, 0, sizeof many);
    many[0].op = TJXOP_HFLIP;
    many[1].op = TJXOP_ROT180;
    many[2].op = TJXOP_TRANSPOSE;
    unsigned char *outs[3] = { NULL, NULL, NULL };
    size_t sizes[3] = { 0, 0, 0 };
    int rc = tj3Transform(handle, source, sourceSize, 3, outs, sizes, many);
    check(rc == 0, "three transforms in one call succeed");
    check(sizes[0] > 0 && sizes[1] > 0 && sizes[2] > 0, "each produced output");
    for (int i = 0; i < 3; i++) tj3Free(outs[i]);

    free(original);
    tj3Free(source);
    tj3Destroy(handle);

    printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
