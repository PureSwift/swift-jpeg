/* extras.c - the entry points added last: scaling, cropping, precision,
 * image files, and ICC profiles.
 *
 * These are the ones most likely to be wrong in a way that links cleanly, since
 * several of them touch the filesystem or hand back allocations the caller
 * frees.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "turbojpeg.h"

static int failures = 0;

static void check(int condition, const char *what)
{
    if (condition) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

static unsigned char *makePixels(int width, int height)
{
    unsigned char *p = malloc((size_t)width * height * 3);
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
            unsigned char *q = p + (y * width + x) * 3;
            q[0] = (unsigned char)(x * 255 / width);
            q[1] = (unsigned char)(y * 255 / height);
            q[2] = ((x / 8 + y / 8) & 1) ? 220 : 40;
        }
    return p;
}

int main(void)
{
    const int width = 128, height = 96;
    unsigned char *pixels = makePixels(width, height);
    tjhandle c = tj3Init(TJINIT_COMPRESS);
    tj3Set(c, TJPARAM_QUALITY, 90);
    tj3Set(c, TJPARAM_SUBSAMP, TJSAMP_420);

    unsigned char *jpeg = NULL;
    size_t jpegSize = 0;
    check(tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &jpeg, &jpegSize) == 0,
          "source image compresses");

    printf("scaling factors\n");
    int n = 0;
    tjscalingfactor *factors = tj3GetScalingFactors(&n);
    check(factors && n == 8, "eight scaling factors are advertised");

    tjhandle d = tj3Init(TJINIT_DECOMPRESS);
    for (int i = 0; i < n; i++) {
        check(tj3SetScalingFactor(d, factors[i]) == 0, "an advertised factor is accepted");
    }
    tjscalingfactor bogus = { 3, 7 };
    check(tj3SetScalingFactor(d, bogus) == -1, "an unadvertised factor is refused");

    printf("scaled decompression\n");
    for (int i = 0; i < n; i++) {
        tj3SetScalingFactor(d, factors[i]);
        if (tj3DecompressHeader(d, jpeg, jpegSize)) { check(0, "header"); continue; }
        int w = TJSCALED(tj3Get(d, TJPARAM_JPEGWIDTH), factors[i]);
        int h = TJSCALED(tj3Get(d, TJPARAM_JPEGHEIGHT), factors[i]);
        unsigned char *out = malloc((size_t)w * h * 3);
        int rc = tj3Decompress8(d, jpeg, jpegSize, out, 0, TJPF_RGB);
        if (rc) printf("        (%s)\n", tj3GetErrorStr(d));
        char label[64];
        snprintf(label, sizeof label, "%d/%d decodes to %dx%d",
                 factors[i].num, factors[i].denom, w, h);
        /* A correct scaled decode has a plausible mean; a wrong one is either
         * black or garbage. */
        long total = 0;
        for (long k = 0; k < (long)w * h * 3; k++) total += out[k];
        double mean = (double)total / ((double)w * h * 3);
        check(rc == 0 && mean > 20 && mean < 235, label);
        free(out);
    }
    tjscalingfactor unscaled = { 1, 1 };
    tj3SetScalingFactor(d, unscaled);

    printf("cropping\n");
    tjregion region = { 32, 16, 64, 48 };
    check(tj3SetCroppingRegion(d, region) == 0, "a region inside the image is accepted");
    unsigned char *cropped = malloc(64 * 48 * 3);
    check(tj3Decompress8(d, jpeg, jpegSize, cropped, 0, TJPF_RGB) == 0, "it decompresses");

    /* The cropped pixels must equal the corresponding pixels of a full decode. */
    tjregion none = { 0, 0, 0, 0 };
    tj3SetCroppingRegion(d, none);
    unsigned char *whole = malloc((size_t)width * height * 3);
    tj3Decompress8(d, jpeg, jpegSize, whole, 0, TJPF_RGB);
    int same = 1;
    for (int y = 0; y < 48 && same; y++)
        for (int x = 0; x < 64; x++)
            if (memcmp(cropped + (y * 64 + x) * 3,
                       whole + ((y + 16) * width + (x + 32)) * 3, 3) != 0) { same = 0; break; }
    check(same, "the cropped region matches the full decode exactly");

    tjregion outside = { 100, 100, 100, 100 };
    tj3SetCroppingRegion(d, outside);
    check(tj3Decompress8(d, jpeg, jpegSize, cropped, 0, TJPF_RGB) == -1,
          "a region outside the image is refused");
    tj3SetCroppingRegion(d, none);

    printf("12-bit precision\n");
    short *wide = malloc((size_t)width * height * 3 * sizeof(short));
    for (long k = 0; k < (long)width * height * 3; k++) wide[k] = (short)(pixels[k] << 4);
    tjhandle c12 = tj3Init(TJINIT_COMPRESS);
    tj3Set(c12, TJPARAM_QUALITY, 95);
    tj3Set(c12, TJPARAM_SUBSAMP, TJSAMP_444);
    unsigned char *jpeg12 = NULL; size_t size12 = 0;
    int rc = tj3Compress12(c12, wide, width, 0, height, TJPF_RGB, &jpeg12, &size12);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(c12));
    check(rc == 0 && size12 > 0, "tj3Compress12 succeeds");

    tjhandle d12 = tj3Init(TJINIT_DECOMPRESS);
    check(tj3DecompressHeader(d12, jpeg12, size12) == 0, "its header reads");
    check(tj3Get(d12, TJPARAM_PRECISION) == 12, "the image reports 12-bit precision");
    short *back = malloc((size_t)width * height * 3 * sizeof(short));
    rc = tj3Decompress12(d12, jpeg12, size12, back, 0, TJPF_RGB);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(d12));
    check(rc == 0, "tj3Decompress12 succeeds");
    long worst = 0;
    for (long k = 0; k < (long)width * height * 3; k++) {
        long e = labs((long)wide[k] - (long)back[k]);
        if (e > worst) worst = e;
    }
    printf("  info  12-bit worst-case deviation %ld of 4095\n", worst);
    check(worst < 400, "12-bit survives the round trip");

    /* 16-bit was checked here as a refusal until the lossless process made it
     * real. It is exercised properly further down. */


    printf("progressive compression\n");
    tj3Set(c, TJPARAM_PROGRESSIVE, 1);
    unsigned char *prog = NULL; size_t progSize = 0;
    rc = tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &prog, &progSize);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(c));
    check(rc == 0, "TJPARAM_PROGRESSIVE compresses");
    /* SOF2 is the progressive start-of-frame marker. */
    int sof2 = 0, scans = 0;
    for (size_t k = 0; prog && k + 1 < progSize; k++) {
        if (prog[k] != 0xFF) continue;
        if (prog[k + 1] == 0xC2) sof2 = 1;
        if (prog[k + 1] == 0xDA) scans++;
    }
    check(sof2, "the output is SOF2");
    check(scans == 10, "it has the expected ten scans");
    check(progSize < jpegSize, "and is smaller than the sequential encoding");

    tj3Set(d, TJPARAM_PROGRESSIVE, 0);
    check(tj3DecompressHeader(d, prog, progSize) == 0, "its header reads");
    check(tj3Get(d, TJPARAM_PROGRESSIVE) == 1, "and reports the image as progressive");
    unsigned char *progPixels = malloc((size_t)width * height * 3);
    check(tj3Decompress8(d, prog, progSize, progPixels, 0, TJPF_RGB) == 0, "it decompresses");
    /* Same coefficients as the sequential encoding, so the decodes must match
     * exactly rather than merely closely. */
    check(memcmp(progPixels, whole, (size_t)width * height * 3) == 0,
          "and decodes identically to the sequential encoding");
    tj3Free(prog); free(progPixels);
    tj3Set(c, TJPARAM_PROGRESSIVE, 0);

    printf("lossless\n");
    tj3Set(c, TJPARAM_LOSSLESS, 1);
    tj3Set(c, TJPARAM_LOSSLESSPSV, 4);
    unsigned char *ll = NULL; size_t llSize = 0;
    rc = tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &ll, &llSize);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(c));
    check(rc == 0, "TJPARAM_LOSSLESS compresses");
    int sof3 = 0;
    for (size_t k = 0; ll && k + 1 < llSize; k++)
        if (ll[k] == 0xFF && ll[k + 1] == 0xC3) sof3 = 1;
    check(sof3, "the output is SOF3");

    check(tj3DecompressHeader(d, ll, llSize) == 0, "its header reads");
    check(tj3Get(d, TJPARAM_LOSSLESS) == 1, "and reports the image as lossless");
    unsigned char *llPixels = malloc((size_t)width * height * 3);
    rc = tj3Decompress8(d, ll, llSize, llPixels, 0, TJPF_RGB);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(d));
    check(rc == 0, "it decompresses");
    /* The whole point: every sample identical, not merely close. */
    check(memcmp(llPixels, pixels, (size_t)width * height * 3) == 0,
          "and reproduces the source pixels exactly");

    /* All seven predictors must be exact. */
    int predictorFailures = 0;
    for (int psv = 1; psv <= 7; psv++) {
        tj3Set(c, TJPARAM_LOSSLESSPSV, psv);
        unsigned char *p = NULL; size_t pn = 0;
        if (tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &p, &pn) ||
            tj3Decompress8(d, p, pn, llPixels, 0, TJPF_RGB) ||
            memcmp(llPixels, pixels, (size_t)width * height * 3) != 0)
            predictorFailures++;
        tj3Free(p);
    }
    check(predictorFailures == 0, "all seven predictors round trip exactly");

    printf("16-bit precision\n");
    unsigned short *deep = malloc((size_t)width * height * 3 * sizeof(unsigned short));
    for (long k = 0; k < (long)width * height * 3; k++)
        deep[k] = (unsigned short)(pixels[k] * 257);
    tj3Set(c, TJPARAM_LOSSLESSPSV, 1);
    unsigned char *j16b = NULL; size_t s16b = 0;
    rc = tj3Compress16(c, deep, width, 0, height, TJPF_RGB, &j16b, &s16b);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(c));
    check(rc == 0, "tj3Compress16 succeeds");
    check(tj3DecompressHeader(d, j16b, s16b) == 0, "its header reads");
    check(tj3Get(d, TJPARAM_PRECISION) == 16, "it reports 16-bit precision");
    unsigned short *back16 = malloc((size_t)width * height * 3 * sizeof(unsigned short));
    rc = tj3Decompress16(d, j16b, s16b, back16, 0, TJPF_RGB);
    if (rc) printf("        (%s)\n", tj3GetErrorStr(d));
    check(rc == 0, "tj3Decompress16 succeeds");
    check(memcmp(deep, back16, (size_t)width * height * 3 * sizeof(unsigned short)) == 0,
          "and 16-bit samples survive exactly");
    tj3Free(ll); tj3Free(j16b); free(llPixels); free(deep); free(back16);
    tj3Set(c, TJPARAM_LOSSLESS, 0);

    printf("image files\n");
    check(tj3SaveImage8(c, "/tmp/extras-test.ppm", pixels, width, 0, height, TJPF_RGB) == 0,
          "tj3SaveImage8 writes a PPM");
    int lw = 0, lh = 0, lf = TJPF_UNKNOWN;
    unsigned char *loaded = tj3LoadImage8(c, "/tmp/extras-test.ppm", &lw, 4, &lh, &lf);
    check(loaded && lw == width && lh == height, "tj3LoadImage8 reads it back");
    check(lf == TJPF_RGB, "and reports RGB");
    int identical = 1;
    for (int y = 0; y < height && identical; y++) {
        int stride = ((width * 3) + 3) & ~3;
        if (memcmp(loaded + (size_t)y * stride, pixels + (size_t)y * width * 3,
                   (size_t)width * 3) != 0) identical = 0;
    }
    check(identical, "a PPM round trip is byte exact");
    tj3Free(loaded);

    check(tj3SaveImage8(c, "/tmp/extras-test.bmp", pixels, width, 0, height, TJPF_RGB) == 0,
          "tj3SaveImage8 writes a BMP");
    lw = lh = 0; lf = TJPF_UNKNOWN;
    loaded = tjLoadImage("/tmp/extras-test.bmp", &lw, 1, &lh, &lf, 0);
    check(loaded && lw == width && lh == height, "tjLoadImage reads the BMP back");
    identical = memcmp(loaded, pixels, (size_t)width * height * 3) == 0;
    check(identical, "a BMP round trip is byte exact");
    tj3Free(loaded);

    printf("ICC profiles\n");
    /* A profile large enough to need more than one APP2 segment. */
    size_t profileSize = 150000;
    unsigned char *profile = malloc(profileSize);
    for (size_t k = 0; k < profileSize; k++) profile[k] = (unsigned char)(k * 31 + 7);

    check(tj3SetICCProfile(c, profile, profileSize) == 0, "a profile is accepted");
    unsigned char *tagged = NULL; size_t taggedSize = 0;
    check(tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &tagged, &taggedSize) == 0,
          "an image compresses with it embedded");
    check(taggedSize > jpegSize + profileSize - 1000, "the output grew by about the profile");

    unsigned char *recovered = NULL; size_t recoveredSize = 0;
    check(tj3DecompressHeader(d, tagged, taggedSize) == 0, "the tagged image reads");
    check(tj3GetICCProfile(d, &recovered, &recoveredSize) == 0, "the profile comes back");
    check(recoveredSize == profileSize, "at its original size");
    check(recovered && memcmp(recovered, profile, profileSize) == 0, "byte for byte");
    tj3Free(recovered);

    check(tj3DecompressHeader(d, jpeg, jpegSize) == 0, "an untagged image reads");
    check(tj3GetICCProfile(d, &recovered, &recoveredSize) == -1,
          "and reports that it has no profile");

    printf("pixel density\n");
    tj3SetICCProfile(c, NULL, 0); /* stop embedding the profile from above */
    check(tj3DecompressHeader(d, jpeg, jpegSize) == 0, "an untouched image reads");
    check(tj3Get(d, TJPARAM_XDENSITY) == 1 && tj3Get(d, TJPARAM_YDENSITY) == 1,
          "and reports the default 1x1 density");
    check(tj3Get(d, TJPARAM_DENSITYUNITS) == 0, "with no units");

    tj3Set(c, TJPARAM_XDENSITY, 300);
    tj3Set(c, TJPARAM_YDENSITY, 600);
    tj3Set(c, TJPARAM_DENSITYUNITS, 1);
    unsigned char *dense = NULL; size_t denseSize = 0;
    check(tj3Compress8(c, pixels, width, 0, height, TJPF_RGB, &dense, &denseSize) == 0,
          "an image compresses with a density set");
    check(tj3DecompressHeader(d, dense, denseSize) == 0, "it reads back");
    check(tj3Get(d, TJPARAM_XDENSITY) == 300 && tj3Get(d, TJPARAM_YDENSITY) == 600,
          "the density survives the round trip");
    check(tj3Get(d, TJPARAM_DENSITYUNITS) == 1, "and so does its unit");
    unsigned char *densePixels = malloc((size_t)width * height * 3);
    check(tj3Decompress8(d, dense, denseSize, densePixels, 0, TJPF_RGB) == 0,
          "a full decompress also reads it");
    check(tj3Get(d, TJPARAM_XDENSITY) == 300 && tj3Get(d, TJPARAM_DENSITYUNITS) == 1,
          "and reports the same density");

    tj3Free(jpeg); tj3Free(jpeg12); tj3Free(tagged); tj3Free(dense);
    tj3Destroy(c); tj3Destroy(d); tj3Destroy(c12); tj3Destroy(d12);
    free(pixels); free(cropped); free(whole); free(wide); free(back); free(profile);
    free(densePixels);

    printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
