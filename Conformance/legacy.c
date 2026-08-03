/* legacy.c - exercise the TurboJPEG 1.x and 2.x API as an ordinary client would
 *
 * Separate from roundtrip.c because it is testing a different contract. The TJ3
 * API is what new code calls; this is what the large body of already-compiled
 * software calls, and a replacement that satisfies only the former is not a
 * drop-in for anything already installed.
 *
 * The old API differs in more than spelling: options travel in a flags bitmask,
 * sizes are unsigned long rather than size_t, and several calls return values
 * the modern equivalents report through the handle instead.
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
    tjhandle compressor = tjInitCompress();
    check(compressor != NULL, "tjInitCompress returns a handle");
    check(tjInitTransform() != NULL, "tjInitTransform returns a handle");
    check(tjGetErrorStr() != NULL, "the handleless tjGetErrorStr works");

    printf("plane geometry\n");
    check(tjPlaneWidth(0, 128, TJSAMP_420) == 128, "luma plane is full width");
    check(tjPlaneWidth(1, 128, TJSAMP_420) == 64, "4:2:0 chroma is half width");
    check(tjPlaneHeight(1, 128, TJSAMP_420) == 64, "4:2:0 chroma is half height");
    check(tjPlaneWidth(1, 128, TJSAMP_422) == 64, "4:2:2 chroma is half width");
    check(tjPlaneHeight(1, 128, TJSAMP_422) == 128, "4:2:2 chroma is full height");
    check(tjPlaneWidth(1, 133, TJSAMP_420) == 67, "an odd width rounds up");
    check(tjPlaneWidth(3, 128, TJSAMP_420) == -1, "a fourth component is rejected");

    printf("scaling factors\n");
    int count = 0;
    tjscalingfactor *factors = tjGetScalingFactors(&count);
    check(factors != NULL && count >= 1, "at least one scaling factor is offered");
    int unscaled = 0;
    for (int i = 0; i < count; i++) {
        if (factors[i].num == 1 && factors[i].denom == 1) unscaled = 1;
    }
    check(unscaled, "1/1 is among them");

    printf("compress\n");
    unsigned long bound = tjBufSize(width, height, TJSAMP_420);
    check(bound > 0, "tjBufSize returns a bound");

    unsigned char *jpeg = NULL;
    unsigned long jpegSize = 0;
    int rc = tjCompress2(compressor, source, width, 0, height, TJPF_RGB,
                         &jpeg, &jpegSize, TJSAMP_420, 90, 0);
    if (rc != 0) printf("        (%s)\n", tjGetErrorStr2(compressor));
    check(rc == 0, "tjCompress2 succeeds");
    check(jpeg != NULL && jpegSize > 0, "it produced a buffer");
    check(jpegSize <= bound, "output fits the advertised bound");

    printf("header\n");
    tjhandle decompressor = tjInitDecompress();
    int w = 0, h = 0, subsamp = -1, colorspace = -1;

    rc = tjDecompressHeader3(decompressor, jpeg, jpegSize, &w, &h, &subsamp, &colorspace);
    check(rc == 0, "tjDecompressHeader3 succeeds");
    check(w == width && h == height, "dimensions round trip");
    check(subsamp == TJSAMP_420, "subsampling round trips");
    check(colorspace == TJCS_YCbCr, "colorspace is YCbCr");

    w = h = 0;
    check(tjDecompressHeader2(decompressor, jpeg, jpegSize, &w, &h, &subsamp) == 0,
          "tjDecompressHeader2 succeeds");
    check(w == width && h == height, "the 2-argument form agrees");

    w = h = 0;
    check(tjDecompressHeader(decompressor, jpeg, jpegSize, &w, &h) == 0,
          "tjDecompressHeader succeeds");
    check(w == width && h == height, "the 1.x form agrees");

    printf("decompress\n");
    rc = tjDecompress2(decompressor, jpeg, jpegSize, result, 0, 0, 0, TJPF_RGB, 0);
    if (rc != 0) printf("        (%s)\n", tjGetErrorStr2(decompressor));
    check(rc == 0, "tjDecompress2 with zero dimensions succeeds");

    long total = 0;
    for (long i = 0; i < (long)width * height * 3; i++)
        total += labs((long)source[i] - (long)result[i]);
    double mean = (double)total / ((double)width * height * 3);
    printf("  info  mean error %.3f\n", mean);
    check(mean < 12.0, "decoded image resembles the original");

    printf("flags\n");
    /* Bottom-up should flip the output, so the first row of one must equal the
     * last row of the other. */
    unsigned char *flipped = malloc((size_t)width * height * 3);
    rc = tjDecompress2(decompressor, jpeg, jpegSize, flipped, 0, 0, 0, TJPF_RGB,
                       TJFLAG_BOTTOMUP);
    check(rc == 0, "TJFLAG_BOTTOMUP is accepted");
    check(memcmp(result, flipped + (size_t)(height - 1) * width * 3,
                 (size_t)width * 3) == 0,
          "TJFLAG_BOTTOMUP actually flips the image");

    printf("unsupported requests fail rather than corrupt\n");
    /* Scaled output is not implemented. The dangerous outcome would be writing
     * full-size pixels into a half-size buffer, so this must fail. */
    check(tjDecompress2(decompressor, jpeg, jpegSize, result, width / 2, 0,
                        height / 2, TJPF_RGB, 0) == -1,
          "a scaled request is refused");
    check(strlen(tjGetErrorStr2(decompressor)) > 0, "and says why");

    printf("cleanup\n");
    tjFree(jpeg);
    check(tjDestroy(compressor) == 0, "tjDestroy reports success");
    check(tjDestroy(decompressor) == 0, "tjDestroy reports success again");
    free(source);
    free(result);
    free(flipped);

    printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
