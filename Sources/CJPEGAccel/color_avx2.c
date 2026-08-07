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
