/* yuv.c - exercise the planar YUV entry points
 *
 * These are the API's window onto the intermediate representation: the
 * component planes as they are actually coded, before upsampling and color
 * conversion. Software that pipes JPEG into a video encoder or a GPU texture
 * uses them to skip two conversions it would only have to undo.
 *
 * The geometry is the part worth testing hardest. Plane dimensions are padded
 * by rules that are not the obvious ones, and a mistake produces a buffer of
 * the right shape and the wrong size, which reads as a heap overrun in the
 * caller rather than as a visibly broken image.
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

static double deviation(const unsigned char *a, const unsigned char *b, long n)
{
    long total = 0;
    for (long i = 0; i < n; i++) total += labs((long)a[i] - (long)b[i]);
    return (double)total / (double)n;
}

int main(void)
{
    const int width = 133, height = 101;
    const int subsamp = TJSAMP_420;
    unsigned char *source = malloc((size_t)width * height * 3);
    unsigned char *result = malloc((size_t)width * height * 3);
    if (!source || !result) return 99;
    fill(source, width, height);

    printf("geometry\n");
    size_t yuvSize = tj3YUVBufSize(width, 4, height, subsamp);
    check(yuvSize > 0, "tj3YUVBufSize returns a size");
    check(tj3YUVPlaneWidth(0, width, subsamp) == 134, "luma pads to the sampling factor");
    check(tj3YUVPlaneWidth(1, width, subsamp) == 67, "chroma is half the padded width");
    check(tj3YUVPlaneHeight(0, height, subsamp) == 102, "luma height pads");
    check(tj3YUVPlaneHeight(1, height, subsamp) == 51, "chroma is half the padded height");
    /* The sum of the padded planes is exactly what the buffer must hold. */
    size_t sum = 0;
    for (int i = 0; i < 3; i++) {
        int pw = tj3YUVPlaneWidth(i, width, subsamp);
        int ph = tj3YUVPlaneHeight(i, height, subsamp);
        sum += (size_t)((pw + 3) & ~3) * (size_t)ph;
    }
    check(sum == yuvSize, "the buffer size is the sum of its padded planes");

    unsigned char *yuv = malloc(yuvSize);
    unsigned char *yuv2 = malloc(yuvSize);
    if (!yuv || !yuv2) return 99;
    /* Zeroed because the row padding between a plane's width and its stride is
     * not image data and is deliberately never written — by this library or by
     * libjpeg-turbo. Comparing buffers without this would be comparing
     * uninitialized malloc garbage. */
    memset(yuv, 0, yuvSize);
    memset(yuv2, 0, yuvSize);

    printf("packed pixels to YUV and back\n");
    tjhandle handle = tj3Init(TJINIT_COMPRESS);
    check(tj3Set(handle, TJPARAM_SUBSAMP, subsamp) == 0, "subsampling is set");

    int rc = tj3EncodeYUV8(handle, source, width, 0, height, TJPF_RGB, yuv, 4);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(handle));
    check(rc == 0, "tj3EncodeYUV8 succeeds");

    rc = tj3DecodeYUV8(handle, yuv, 4, result, width, 0, height, TJPF_RGB);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(handle));
    check(rc == 0, "tj3DecodeYUV8 succeeds");

    double d = deviation(source, result, (long)width * height * 3);
    printf("  info  YUV round trip mean error %.3f\n", d);
    /* No JPEG involved, so the only loss is chroma subsampling and the two
     * color conversions. */
    check(d < 12.0, "the YUV round trip preserves the image");

    printf("YUV to JPEG and back\n");
    unsigned char *jpeg = NULL;
    size_t jpegSize = 0;
    tj3Set(handle, TJPARAM_QUALITY, 90);
    rc = tj3CompressFromYUV8(handle, yuv, width, 4, height, &jpeg, &jpegSize);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(handle));
    check(rc == 0, "tj3CompressFromYUV8 succeeds");
    check(jpeg != NULL && jpegSize > 0, "it produced a JPEG");
    check(jpeg && jpeg[0] == 0xFF && jpeg[1] == 0xD8, "which starts with SOI");

    tjhandle decompressor = tj3Init(TJINIT_DECOMPRESS);
    rc = tj3DecompressToYUV8(decompressor, jpeg, jpegSize, yuv2, 4);
    if (rc != 0) printf("        (%s)\n", tj3GetErrorStr(decompressor));
    check(rc == 0, "tj3DecompressToYUV8 succeeds");
    check(tj3Get(decompressor, TJPARAM_SUBSAMP) == subsamp,
          "the decoded image kept its subsampling");

    /* The planes went through one generation of quantization, so they should be
     * close to what went in without being identical. */
    d = deviation(yuv, yuv2, (long)yuvSize);
    printf("  info  plane round trip mean error %.3f\n", d);
    check(d < 6.0, "the planes survive a JPEG generation");

    printf("full circle\n");
    rc = tj3DecodeYUV8(handle, yuv2, 4, result, width, 0, height, TJPF_RGB);
    check(rc == 0, "the recovered planes decode to pixels");
    d = deviation(source, result, (long)width * height * 3);
    printf("  info  end to end mean error %.3f\n", d);
    check(d < 14.0, "RGB to YUV to JPEG to YUV to RGB preserves the image");

    printf("plane pointer forms agree with the packed form\n");
    unsigned char *planes[3];
    int strides[3];
    size_t offset = 0;
    for (int i = 0; i < 3; i++) {
        int pw = tj3YUVPlaneWidth(i, width, subsamp);
        int ph = tj3YUVPlaneHeight(i, height, subsamp);
        strides[i] = (pw + 3) & ~3;
        planes[i] = yuv2 + offset;
        offset += (size_t)strides[i] * (size_t)ph;
    }
    unsigned char *viaPlanes = malloc((size_t)width * height * 3);
    rc = tj3DecodeYUVPlanes8(handle, (const unsigned char * const *)planes, strides,
                             viaPlanes, width, 0, height, TJPF_RGB);
    check(rc == 0, "tj3DecodeYUVPlanes8 succeeds");
    check(memcmp(result, viaPlanes, (size_t)width * height * 3) == 0,
          "it produces exactly what the packed form did");

    printf("the 1.x and 2.x spellings agree with the modern ones\n");
    unsigned char *legacyYUV = malloc(yuvSize);
    memset(legacyYUV, 0, yuvSize);
    check(tjEncodeYUV3(handle, source, width, 0, height, TJPF_RGB, legacyYUV, 4,
                       subsamp, 0) == 0,
          "tjEncodeYUV3 succeeds");
    check(memcmp(yuv, legacyYUV, yuvSize) == 0,
          "tjEncodeYUV3 produces exactly what tj3EncodeYUV8 did");
    check(tjBufSizeYUV2(width, 4, height, subsamp) == yuvSize,
          "tjBufSizeYUV2 agrees with tj3YUVBufSize");
    check(tjBufSizeYUV(width, height, subsamp) == yuvSize,
          "tjBufSizeYUV assumes four-byte alignment");

    unsigned char *legacyRGB = malloc((size_t)width * height * 3);
    check(tjDecodeYUV(handle, yuv, 4, subsamp, legacyRGB, width, 0, height,
                      TJPF_RGB, 0) == 0,
          "tjDecodeYUV succeeds");

    unsigned char *legacyJPEG = NULL;
    unsigned long legacySize = 0;
    check(tjCompressFromYUV(handle, yuv, width, 4, height, subsamp, &legacyJPEG,
                            &legacySize, 90, 0) == 0,
          "tjCompressFromYUV succeeds");
    check(legacySize == jpegSize && legacyJPEG &&
          memcmp(legacyJPEG, jpeg, jpegSize) == 0,
          "it produces byte-identical output to tj3CompressFromYUV8");

    tjFree(legacyJPEG);
    free(legacyYUV);
    free(legacyRGB);

    tj3Free(jpeg);
    tj3Destroy(handle);
    tj3Destroy(decompressor);
    free(source); free(result); free(yuv); free(yuv2); free(viaPlanes);

    printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
