#include "include/jpeg_accel.h"

/* AVX2 YCbCr to RGB conversion.
 *
 * Eight pixels per iteration. The arithmetic is trivially parallel — nine
 * multiplies and three clamps per pixel, with no dependency between pixels —
 * so the whole problem is getting the data into and out of the registers.
 *
 * Both ends are three-channel interleaved, which is the one layout a vector
 * unit is bad at: eight pixels are twenty-four uint16_t in and twenty-four
 * uint8_t out, and neither divides the register width. So the loads are three
 * 128-bit reads shuffled into three planes, and the stores are three planes
 * shuffled back into a 16-byte write and an 8-byte one. Twenty-four bytes
 * exactly, which is why there is no tail-overrun to guard: the vector body
 * never writes a byte the scalar tail would also write.
 *
 * The clamp is free. Both narrowing packs saturate, and saturating from int32
 * to int16 to uint8 lands on exactly 0 ... 255 — the same result as the
 * portable min-of-max, without the compare.
 */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)

#include <immintrin.h>

#define TARGET_AVX2 __attribute__((target("avx2")))

/* JFIF §7 in 16-bit fixed point. The same constants as Format.swift, which is
 * what makes the two agree exactly rather than approximately. */
#define HALF 32768
#define CR_TO_R 91881
#define CB_TO_G (-22554)
#define CR_TO_G (-46802)
#define CB_TO_B 116130

/* The two bytes of one uint16_t lane, and a lane that shuffles in as zero.
 * pshufb zeroes a destination byte whose index has its high bit set. */
#define S(i) (char)((i) * 2), (char)((i) * 2 + 1)
#define Z (char)-1, (char)-1
/* A byte lane that shuffles in as zero, for the eight-bit shuffles. */
#define N (char)-1

/* Splits twenty-four interleaved samples into three planes of eight. */
TARGET_AVX2 static inline void deinterleave(const uint16_t *p, __m128i *y,
                                            __m128i *cb, __m128i *cr) {
    const __m128i v0 = _mm_loadu_si128((const __m128i *)p);
    const __m128i v1 = _mm_loadu_si128((const __m128i *)(p + 8));
    const __m128i v2 = _mm_loadu_si128((const __m128i *)(p + 16));

    /* Each plane takes three lanes from the first vector, three from the
     * second and two from the third, or a permutation of that — the period of
     * the interleave is three and the period of the register is eight, so the
     * pattern only repeats every twenty-four samples. */
    *y = _mm_or_si128(
        _mm_or_si128(
            _mm_shuffle_epi8(v0, _mm_setr_epi8(S(0), S(3), S(6), Z, Z, Z, Z, Z)),
            _mm_shuffle_epi8(v1, _mm_setr_epi8(Z, Z, Z, S(1), S(4), S(7), Z, Z))),
        _mm_shuffle_epi8(v2, _mm_setr_epi8(Z, Z, Z, Z, Z, Z, S(2), S(5))));

    *cb = _mm_or_si128(
        _mm_or_si128(
            _mm_shuffle_epi8(v0, _mm_setr_epi8(S(1), S(4), S(7), Z, Z, Z, Z, Z)),
            _mm_shuffle_epi8(v1, _mm_setr_epi8(Z, Z, Z, S(2), S(5), Z, Z, Z))),
        _mm_shuffle_epi8(v2, _mm_setr_epi8(Z, Z, Z, Z, Z, S(0), S(3), S(6))));

    *cr = _mm_or_si128(
        _mm_or_si128(
            _mm_shuffle_epi8(v0, _mm_setr_epi8(S(2), S(5), Z, Z, Z, Z, Z, Z)),
            _mm_shuffle_epi8(v1, _mm_setr_epi8(Z, Z, S(0), S(3), S(6), Z, Z, Z))),
        _mm_shuffle_epi8(v2, _mm_setr_epi8(Z, Z, Z, Z, Z, S(1), S(4), S(7))));
}

/* Descales by sixteen places, clamps to 0 ... 255 and packs into the low eight
 * bytes. Both packs saturate, which is where the clamp comes from. */
TARGET_AVX2 static inline __m128i pack(__m256i v) {
    const __m256i shifted = _mm256_srai_epi32(v, 16);
    const __m128i words = _mm_packs_epi32(_mm256_castsi256_si128(shifted),
                                          _mm256_extracti128_si256(shifted, 1));
    return _mm_packus_epi16(words, words);
}

TARGET_AVX2 static void ycc_to_rgb_avx2(const uint16_t *interleaved,
                                        ptrdiff_t count, int32_t left,
                                        int32_t right, uint8_t *rgb) {
    /* Narrowing is a shift each way rather than a branch on the sign, so the
     * loop body is the same instructions whatever the precision was. One of
     * the two counts is always zero. */
    const __m128i up = _mm_cvtsi32_si128(left);
    const __m128i down = _mm_cvtsi32_si128(right);
    const __m128i byte = _mm_set1_epi16(0x00FF);

    const __m256i half = _mm256_set1_epi32(HALF);
    const __m256i bias = _mm256_set1_epi32(128);
    const __m256i crToR = _mm256_set1_epi32(CR_TO_R);
    const __m256i cbToG = _mm256_set1_epi32(CB_TO_G);
    const __m256i crToG = _mm256_set1_epi32(CR_TO_G);
    const __m256i cbToB = _mm256_set1_epi32(CB_TO_B);

    for (ptrdiff_t i = 0; i < count; i += 8) {
        __m128i y16, cb16, cr16;
        deinterleave(interleaved + 3 * i, &y16, &cb16, &cr16);

        y16 = _mm_and_si128(_mm_srl_epi16(_mm_sll_epi16(y16, up), down), byte);
        cb16 = _mm_and_si128(_mm_srl_epi16(_mm_sll_epi16(cb16, up), down), byte);
        cr16 = _mm_and_si128(_mm_srl_epi16(_mm_sll_epi16(cr16, up), down), byte);

        const __m256i y = _mm256_add_epi32(
            _mm256_slli_epi32(_mm256_cvtepu16_epi32(y16), 16), half);
        const __m256i cb = _mm256_sub_epi32(_mm256_cvtepu16_epi32(cb16), bias);
        const __m256i cr = _mm256_sub_epi32(_mm256_cvtepu16_epi32(cr16), bias);

        const __m128i r = pack(
            _mm256_add_epi32(y, _mm256_mullo_epi32(cr, crToR)));
        const __m128i g = pack(_mm256_add_epi32(
            y, _mm256_add_epi32(_mm256_mullo_epi32(cb, cbToG),
                                _mm256_mullo_epi32(cr, crToG))));
        const __m128i b = pack(
            _mm256_add_epi32(y, _mm256_mullo_epi32(cb, cbToB)));

        uint8_t *out = rgb + 3 * i;
        _mm_storeu_si128(
            (__m128i *)out,
            _mm_or_si128(
                _mm_or_si128(
                    _mm_shuffle_epi8(r, _mm_setr_epi8(0, N, N, 1, N, N, 2, N, N,
                                                       3, N, N, 4, N, N, 5)),
                    _mm_shuffle_epi8(g, _mm_setr_epi8(N, 0, N, N, 1, N, N, 2, N,
                                                       N, 3, N, N, 4, N, N))),
                _mm_shuffle_epi8(b, _mm_setr_epi8(N, N, 0, N, N, 1, N, N, 2, N,
                                                   N, 3, N, N, 4, N))));
        _mm_storel_epi64(
            (__m128i *)(out + 16),
            _mm_or_si128(
                _mm_or_si128(
                    _mm_shuffle_epi8(r, _mm_setr_epi8(N, N, 6, N, N, 7, N, N, N,
                                                       N, N, N, N, N, N, N)),
                    _mm_shuffle_epi8(g, _mm_setr_epi8(5, N, N, 6, N, N, 7, N, N,
                                                       N, N, N, N, N, N, N))),
                _mm_shuffle_epi8(b, _mm_setr_epi8(N, 5, N, N, 6, N, N, 7, N, N,
                                                   N, N, N, N, N, N))));
    }
}

/* The encoding direction. Same constants, transposed. */
#define R_TO_Y 19595
#define G_TO_Y 38470
#define B_TO_Y 7471
#define R_TO_CB (-11059)
#define G_TO_CB (-21709)
#define B_TO_CB 32768
#define R_TO_CR 32768
#define G_TO_CR (-27439)
#define B_TO_CR (-5329)

/* Builds the pair of shuffle masks that gathers one channel of eight pixels
 * into the low eight bytes of a register.
 *
 * The masks depend on the caller's pixel layout, so they are computed rather
 * than written out — once per call, which is nothing against a megapixel, and it
 * covers every channel order and both pixel sizes with one piece of code
 * instead of a table of twelve. */
static void channel_masks(int32_t size, int32_t offset, char *low, char *high) {
    for (int j = 0; j < 16; j++) {
        low[j] = N;
        high[j] = N;
    }
    for (int j = 0; j < 8; j++) {
        const int at = offset + j * size;
        if (at < 16) {
            low[j] = (char)at;
        } else {
            high[j] = (char)(at - 16);
        }
    }
}

/* Clamps to 0 ... 255 and packs into eight 16-bit lanes.
 *
 * Explicit min and max rather than relying on the pack to saturate: the pack
 * saturates at 65535, and what is wanted is 255. */
TARGET_AVX2 static inline __m128i clamp16(__m256i v) {
    const __m256i floored = _mm256_max_epi32(v, _mm256_setzero_si256());
    const __m256i capped = _mm256_min_epi32(floored, _mm256_set1_epi32(255));
    return _mm_packus_epi32(_mm256_castsi256_si128(capped),
                            _mm256_extracti128_si256(capped, 1));
}

TARGET_AVX2 static void rgb_to_ycc_avx2(const uint8_t *pixels, int32_t size,
                                        int32_t red, int32_t green, int32_t blue,
                                        ptrdiff_t count, uint16_t *interleaved) {
    char low[16], high[16];
    channel_masks(size, red, low, high);
    const __m128i redLow = _mm_loadu_si128((const __m128i *)low);
    const __m128i redHigh = _mm_loadu_si128((const __m128i *)high);
    channel_masks(size, green, low, high);
    const __m128i greenLow = _mm_loadu_si128((const __m128i *)low);
    const __m128i greenHigh = _mm_loadu_si128((const __m128i *)high);
    channel_masks(size, blue, low, high);
    const __m128i blueLow = _mm_loadu_si128((const __m128i *)low);
    const __m128i blueHigh = _mm_loadu_si128((const __m128i *)high);

    const __m256i half = _mm256_set1_epi32(HALF);
    const __m256i bias = _mm256_set1_epi32(128);

    for (ptrdiff_t i = 0; i < count; i += 8) {
        const uint8_t *p = pixels + i * size;
        const __m128i v0 = _mm_loadu_si128((const __m128i *)p);
        /* Eight pixels are 24 bytes at three per pixel and 32 at four. Reading
         * sixteen more would run past the buffer in the first case, on the last
         * iteration, so the narrower load is not an optimization. */
        const __m128i v1 = size == 3
            ? _mm_loadl_epi64((const __m128i *)(p + 16))
            : _mm_loadu_si128((const __m128i *)(p + 16));

        const __m256i r = _mm256_cvtepu8_epi32(
            _mm_or_si128(_mm_shuffle_epi8(v0, redLow),
                         _mm_shuffle_epi8(v1, redHigh)));
        const __m256i g = _mm256_cvtepu8_epi32(
            _mm_or_si128(_mm_shuffle_epi8(v0, greenLow),
                         _mm_shuffle_epi8(v1, greenHigh)));
        const __m256i b = _mm256_cvtepu8_epi32(
            _mm_or_si128(_mm_shuffle_epi8(v0, blueLow),
                         _mm_shuffle_epi8(v1, blueHigh)));

        const __m256i luma = _mm256_add_epi32(
            _mm256_add_epi32(_mm256_mullo_epi32(r, _mm256_set1_epi32(R_TO_Y)),
                             _mm256_mullo_epi32(g, _mm256_set1_epi32(G_TO_Y))),
            _mm256_add_epi32(_mm256_mullo_epi32(b, _mm256_set1_epi32(B_TO_Y)),
                             half));
        const __m256i blueDiff = _mm256_add_epi32(
            _mm256_add_epi32(_mm256_mullo_epi32(r, _mm256_set1_epi32(R_TO_CB)),
                             _mm256_mullo_epi32(g, _mm256_set1_epi32(G_TO_CB))),
            _mm256_mullo_epi32(b, _mm256_set1_epi32(B_TO_CB)));
        const __m256i redDiff = _mm256_add_epi32(
            _mm256_add_epi32(_mm256_mullo_epi32(r, _mm256_set1_epi32(R_TO_CR)),
                             _mm256_mullo_epi32(g, _mm256_set1_epi32(G_TO_CR))),
            _mm256_mullo_epi32(b, _mm256_set1_epi32(B_TO_CR)));

        /* Chrominance is biased by 128 so that a naturally signed difference
         * fits an unsigned sample, which is why a gray pixel comes out as
         * (y, 128, 128) rather than (y, 0, 0). */
        const __m128i y = clamp16(_mm256_srai_epi32(luma, 16));
        const __m128i cb = clamp16(_mm256_add_epi32(
            _mm256_srai_epi32(_mm256_add_epi32(blueDiff, half), 16), bias));
        const __m128i cr = clamp16(_mm256_add_epi32(
            _mm256_srai_epi32(_mm256_add_epi32(redDiff, half), 16), bias));

        /* Back to three-channel interleaved: the inverse of the deinterleave at
         * the top of this file, and forty-eight bytes exactly. */
        uint16_t *out = interleaved + 3 * i;
        _mm_storeu_si128(
            (__m128i *)out,
            _mm_or_si128(
                _mm_or_si128(
                    _mm_shuffle_epi8(y, _mm_setr_epi8(S(0), Z, Z, S(1), Z, Z, S(2), Z)),
                    _mm_shuffle_epi8(cb, _mm_setr_epi8(Z, S(0), Z, Z, S(1), Z, Z, S(2)))),
                _mm_shuffle_epi8(cr, _mm_setr_epi8(Z, Z, S(0), Z, Z, S(1), Z, Z))));
        _mm_storeu_si128(
            (__m128i *)(out + 8),
            _mm_or_si128(
                _mm_or_si128(
                    _mm_shuffle_epi8(y, _mm_setr_epi8(Z, S(3), Z, Z, S(4), Z, Z, S(5))),
                    _mm_shuffle_epi8(cb, _mm_setr_epi8(Z, Z, S(3), Z, Z, S(4), Z, Z))),
                _mm_shuffle_epi8(cr, _mm_setr_epi8(S(2), Z, Z, S(3), Z, Z, S(4), Z))));
        _mm_storeu_si128(
            (__m128i *)(out + 16),
            _mm_or_si128(
                _mm_or_si128(
                    _mm_shuffle_epi8(y, _mm_setr_epi8(Z, Z, S(6), Z, Z, S(7), Z, Z)),
                    _mm_shuffle_epi8(cb, _mm_setr_epi8(S(5), Z, Z, S(6), Z, Z, S(7), Z))),
                _mm_shuffle_epi8(cr, _mm_setr_epi8(Z, S(5), Z, Z, S(6), Z, Z, S(7)))));
    }
}

#endif

/* The tail, and the whole thing on a processor without AVX2.
 *
 * A transcription of the portable Swift, kept here rather than called back into
 * it because the tail is at most seven pixels and a cross-language call to
 * convert them would cost more than converting them. */
static inline int32_t narrow(uint16_t sample, int32_t left, int32_t right) {
    /* The intermediate is truncated to sixteen bits before the right shift, and
     * to eight after, because that is what the engine's narrowing does — a
     * sample wider than the format claims is a malformed image, not a value to
     * clamp. */
    return (int32_t)((uint16_t)((uint16_t)(sample << left) >> right) & 0xFFu);
}

static inline uint8_t clamp(int32_t value) {
    if (value < 0) {
        return 0;
    }
    if (value > 255) {
        return 255;
    }
    return (uint8_t)value;
}

static void ycc_to_rgb_scalar(const uint16_t *interleaved, ptrdiff_t count,
                              int32_t left, int32_t right, uint8_t *rgb) {
    for (ptrdiff_t i = 0; i < count; ++i) {
        const uint16_t *p = interleaved + 3 * i;
        const int32_t y = (narrow(p[0], left, right) << 16) | 32768;
        const int32_t cb = narrow(p[1], left, right) - 128;
        const int32_t cr = narrow(p[2], left, right) - 128;

        uint8_t *out = rgb + 3 * i;
        out[0] = clamp((y + 91881 * cr) >> 16);
        out[1] = clamp((y - 22554 * cb - 46802 * cr) >> 16);
        out[2] = clamp((y + 116130 * cb) >> 16);
    }
}

static void rgb_to_ycc_scalar(const uint8_t *pixels, int32_t size, int32_t red,
                              int32_t green, int32_t blue, ptrdiff_t count,
                              uint16_t *interleaved) {
    for (ptrdiff_t i = 0; i < count; ++i) {
        const uint8_t *p = pixels + i * size;
        const int32_t r = p[red], g = p[green], b = p[blue];

        const int32_t y = 19595 * r + 38470 * g + 7471 * b + 32768;
        const int32_t cb = -11059 * r - 21709 * g + 32768 * b;
        const int32_t cr = 32768 * r - 27439 * g - 5329 * b;

        uint16_t *out = interleaved + 3 * i;
        out[0] = clamp(y >> 16);
        out[1] = clamp(((cb + 32768) >> 16) + 128);
        out[2] = clamp(((cr + 32768) >> 16) + 128);
    }
}

void jpeg_accel_rgb_to_ycc_avx2(const uint8_t *pixels, int32_t size, int32_t red,
                                int32_t green, int32_t blue, ptrdiff_t count,
                                uint16_t *interleaved) {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
    /* Only the two pixel sizes TurboJPEG defines. Anything else falls to the
     * scalar loop rather than being computed wrongly, which is what a kernel
     * that assumed a size would do. */
    if (size == 3 || size == 4) {
        const ptrdiff_t vectored = count & ~(ptrdiff_t)7;
        if (vectored > 0) {
            rgb_to_ycc_avx2(pixels, size, red, green, blue, vectored, interleaved);
        }
        rgb_to_ycc_scalar(pixels + (ptrdiff_t)size * vectored, size, red, green,
                          blue, count - vectored, interleaved + 3 * vectored);
        return;
    }
#endif
    rgb_to_ycc_scalar(pixels, size, red, green, blue, count, interleaved);
}

void jpeg_accel_ycc_to_rgb_avx2(const uint16_t *interleaved, ptrdiff_t count,
                                int32_t shift, uint8_t *rgb) {
    const int32_t left = shift < 0 ? -shift : 0;
    const int32_t right = shift > 0 ? shift : 0;

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
    const ptrdiff_t vectored = count & ~(ptrdiff_t)7;
    if (vectored > 0) {
        ycc_to_rgb_avx2(interleaved, vectored, left, right, rgb);
    }
    ycc_to_rgb_scalar(interleaved + 3 * vectored, count - vectored, left, right,
                      rgb + 3 * vectored);
#else
    ycc_to_rgb_scalar(interleaved, count, left, right, rgb);
#endif
}
