/* roundtrip.c - exercise the TurboJPEG API as an ordinary C client would
 *
 * Compiled against the vendored header and linked against whichever
 * libturbojpeg is on the library path, so the same program can be run against
 * this library and against the reference build and the results compared. That
 * is the only test that actually proves substitutability; everything inside the
 * Swift package proves the codec works, not that the ABI does.
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

/* A deterministic test image with sharp edges and smooth gradients, since the
 * two stress different parts of the codec. */
static void fill(unsigned char *pixels, int width, int height)
{
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            unsigned char *p = pixels + (y * width + x) * 3;
            p[0] = (unsigned char)(x * 255 / width);
            p[1] = (unsigned char)(y * 255 / height);
            p[2] = ((x / 8 + y / 8) & 1) ? 220 : 40;
        }
    }
}

int main(void)
{
    const int width = 133, height = 101;
    unsigned char *source = malloc((size_t)width * height * 3);
    unsigned char *result = malloc((size_t)width * height * 3);
    if (!source || !result) return 99;
    fill(source, width, height);

    printf("lifecycle\n");
    tjhandle compressor = tj3Init(TJINIT_COMPRESS);
    check(compressor != NULL, "tj3Init(TJINIT_COMPRESS) returns a handle");
    check(tj3GetErrorCode(compressor) == TJERR_WARNING ||
          tj3GetErrorCode(compressor) == 0, "a fresh handle reports no error");
    check(tj3GetErrorStr(NULL) != NULL, "tj3GetErrorStr tolerates a NULL handle");
    tj3Destroy(NULL); /* documented as a no-op, must not crash */

    printf("parameters\n");
    check(tj3Set(compressor, TJPARAM_QUALITY, 90) == 0, "quality 90 is accepted");
    check(tj3Get(compressor, TJPARAM_QUALITY) == 90, "quality reads back");
    check(tj3Set(compressor, TJPARAM_QUALITY, 0) == -1, "quality 0 is rejected");
    check(tj3Set(compressor, TJPARAM_QUALITY, 101) == -1, "quality 101 is rejected");
    check(tj3Set(compressor, TJPARAM_SUBSAMP, TJSAMP_420) == 0, "4:2:0 is accepted");
    check(tj3Set(compressor, TJPARAM_QUALITY, 90) == 0, "quality restored");

    printf("buffer sizing\n");
    size_t bound = tj3JPEGBufSize(width, height, TJSAMP_420);
    check(bound > 0, "tj3JPEGBufSize returns a bound");

    printf("compress\n");
    unsigned char *jpeg = NULL;
    size_t jpegSize = 0;
    int rc = tj3Compress8(compressor, source, width, 0, height, TJPF_RGB,
                          &jpeg, &jpegSize);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(compressor));
    check(rc == 0, "tj3Compress8 succeeds");
    check(jpeg != NULL && jpegSize > 0, "it produced a buffer");
    check(jpegSize <= bound, "output fits the advertised bound");
    check(jpeg && jpeg[0] == 0xFF && jpeg[1] == 0xD8, "output starts with SOI");

    printf("decompress header\n");
    tjhandle decompressor = tj3Init(TJINIT_DECOMPRESS);
    check(decompressor != NULL, "tj3Init(TJINIT_DECOMPRESS) returns a handle");
    rc = tj3DecompressHeader(decompressor, jpeg, jpegSize);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(decompressor));
    check(rc == 0, "tj3DecompressHeader succeeds");
    check(tj3Get(decompressor, TJPARAM_JPEGWIDTH) == width, "width round trips");
    check(tj3Get(decompressor, TJPARAM_JPEGHEIGHT) == height, "height round trips");
    check(tj3Get(decompressor, TJPARAM_SUBSAMP) == TJSAMP_420, "subsampling round trips");
    check(tj3Get(decompressor, TJPARAM_PRECISION) == 8, "precision is 8");

    printf("decompress\n");
    rc = tj3Decompress8(decompressor, jpeg, jpegSize, result, 0, TJPF_RGB);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(decompressor));
    check(rc == 0, "tj3Decompress8 succeeds");

    long total = 0, worst = 0;
    for (long i = 0; i < (long)width * height * 3; i++) {
        long e = labs((long)source[i] - (long)result[i]);
        total += e;
        if (e > worst) worst = e;
    }
    double mean = (double)total / ((double)width * height * 3);
    printf("  info  mean error %.3f, worst %ld\n", mean, worst);
    /* 4:2:0 at quality 90 on a deliberately hostile checkerboard: chroma is
     * quartered, so a loose bound is correct here. A broken codec lands in the
     * tens, not near one. */
    check(mean < 12.0, "decoded image resembles the original");

    printf("error reporting\n");
    unsigned char garbage[64];
    memset(garbage, 0xAB, sizeof garbage);
    check(tj3DecompressHeader(decompressor, garbage, sizeof garbage) == -1,
          "garbage input is rejected");
    check(strlen(tj3GetErrorStr(decompressor)) > 0, "an error message is set");
    check(tj3GetErrorCode(decompressor) == TJERR_FATAL, "the error code is fatal");

    printf("unimplemented entry points\n");
    /* These are published but stubbed. They must fail through the API's own
     * convention rather than crash or return something plausible.
     *
     * Which symbols belong here changes as the library grows — tjInitCompress
     * was checked here until it was implemented, and this list shrinking is the
     * point rather than a maintenance burden. */
    check(tj3SetScalingFactor(decompressor, TJUNSCALED) == -1,
          "the unimplemented tj3SetScalingFactor reports failure");
    check(tj3Compress12(decompressor, NULL, 0, 0, 0, 0, NULL, NULL) == -1,
          "the unimplemented 12-bit path reports failure");

    tj3Free(jpeg);
    tj3Destroy(compressor);
    tj3Destroy(decompressor);
    free(source);
    free(result);

    printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
