#include "include/jpeg_accel.h"
#include <cpufeatures.h>

/* AVX2 transform kernels.
 *
 * Written with intrinsics and a function-level target attribute rather than as
 * a separate assembly file or a separately-flagged compilation unit. The
 * attribute is what makes runtime dispatch possible without either: the file
 * compiles for the baseline, these two functions compile for AVX2, and nothing
 * calls them unless cpuid says it may. Building the whole library for AVX2
 * instead would need per-target compiler flags, which in SwiftPM means
 * unsafeFlags, which would stop the package being usable as a dependency at
 * all.
 *
 * The algorithm is the same Loeffler-Ligtenberg-Moschytz factorization the
 * portable Swift kernels use, so the two can be read against each other. What
 * differs is the shape of the data: a vector holds one row of eight 32-bit
 * values, and the eight rows are eight vectors, so a pass that combines rows
 * is free and a pass that combines columns needs a transpose first.
 */

int jpeg_accel_avx2_available(void) {
    return (jpeg_cpu_features() & JPEG_CPU_AVX2) != 0;
}

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)

#include <immintrin.h>

#define CONST_BITS 13
#define PASS_BITS 2
/* The factored form computes the transform eight times larger than T.81
 * defines it; the forward kernel sheds that at the end. See FDCTFast.swift. */
#define SCALE_BITS 3

#define FIX_0_298631336 2446
#define FIX_0_390180644 3196
#define FIX_0_541196100 4433
#define FIX_0_765366865 6270
#define FIX_0_899976223 7373
#define FIX_1_175875602 9633
#define FIX_1_501321110 12299
#define FIX_1_847759065 15137
#define FIX_1_961570560 16069
#define FIX_2_053119869 16819
#define FIX_2_562915447 20995
#define FIX_3_072711026 25172

#define TARGET_AVX2 __attribute__((target("avx2")))

/* Round to nearest, `bits` places down. */
TARGET_AVX2 static inline __m256i descale(__m256i x, int bits) {
    const __m256i rounding = _mm256_set1_epi32(1 << (bits - 1));
    return _mm256_srai_epi32(_mm256_add_epi32(x, rounding), bits);
}

TARGET_AVX2 static inline __m256i mul(__m256i x, int32_t k) {
    return _mm256_mullo_epi32(x, _mm256_set1_epi32(k));
}

/* Transpose eight vectors of eight 32-bit values.
 *
 * The separable transform needs one pass along each axis, and a vector holds
 * one axis. This is the cost of turning the other one into the cheap case.
 */
TARGET_AVX2 static inline void transpose8(__m256i *r) {
    __m256i t0 = _mm256_unpacklo_epi32(r[0], r[1]);
    __m256i t1 = _mm256_unpackhi_epi32(r[0], r[1]);
    __m256i t2 = _mm256_unpacklo_epi32(r[2], r[3]);
    __m256i t3 = _mm256_unpackhi_epi32(r[2], r[3]);
    __m256i t4 = _mm256_unpacklo_epi32(r[4], r[5]);
    __m256i t5 = _mm256_unpackhi_epi32(r[4], r[5]);
    __m256i t6 = _mm256_unpacklo_epi32(r[6], r[7]);
    __m256i t7 = _mm256_unpackhi_epi32(r[6], r[7]);

    __m256i s0 = _mm256_unpacklo_epi64(t0, t2);
    __m256i s1 = _mm256_unpackhi_epi64(t0, t2);
    __m256i s2 = _mm256_unpacklo_epi64(t1, t3);
    __m256i s3 = _mm256_unpackhi_epi64(t1, t3);
    __m256i s4 = _mm256_unpacklo_epi64(t4, t6);
    __m256i s5 = _mm256_unpackhi_epi64(t4, t6);
    __m256i s6 = _mm256_unpacklo_epi64(t5, t7);
    __m256i s7 = _mm256_unpackhi_epi64(t5, t7);

    r[0] = _mm256_permute2x128_si256(s0, s4, 0x20);
    r[1] = _mm256_permute2x128_si256(s1, s5, 0x20);
    r[2] = _mm256_permute2x128_si256(s2, s6, 0x20);
    r[3] = _mm256_permute2x128_si256(s3, s7, 0x20);
    r[4] = _mm256_permute2x128_si256(s0, s4, 0x31);
    r[5] = _mm256_permute2x128_si256(s1, s5, 0x31);
    r[6] = _mm256_permute2x128_si256(s2, s6, 0x31);
    r[7] = _mm256_permute2x128_si256(s3, s7, 0x31);
}

/* One 8-point inverse transform across eight vectors.
 *
 * `d` is read as the eight frequencies and overwritten with the eight spatial
 * values, descaled by `drop`.
 */
TARGET_AVX2 static inline void idct_pass(__m256i *d, int drop) {
    /* Even part: the four even frequencies form a 4-point transform that
     * needs two multiplies. */
    __m256i e1 = mul(_mm256_add_epi32(d[2], d[6]), FIX_0_541196100);
    __m256i e2 = _mm256_sub_epi32(e1, mul(d[6], FIX_1_847759065));
    __m256i e3 = _mm256_add_epi32(e1, mul(d[2], FIX_0_765366865));
    __m256i e0 = _mm256_slli_epi32(_mm256_add_epi32(d[0], d[4]), CONST_BITS);
    __m256i ex = _mm256_slli_epi32(_mm256_sub_epi32(d[0], d[4]), CONST_BITS);

    __m256i t10 = _mm256_add_epi32(e0, e3);
    __m256i t13 = _mm256_sub_epi32(e0, e3);
    __m256i t11 = _mm256_add_epi32(ex, e2);
    __m256i t12 = _mm256_sub_epi32(ex, e2);

    /* Odd part: the inputs are combined pairwise first and the two rotations
     * they share are evaluated once. */
    __m256i z1 = _mm256_add_epi32(d[7], d[1]);
    __m256i z2 = _mm256_add_epi32(d[5], d[3]);
    __m256i z3 = _mm256_add_epi32(d[7], d[3]);
    __m256i z4 = _mm256_add_epi32(d[5], d[1]);
    __m256i z5 = mul(_mm256_add_epi32(z3, z4), FIX_1_175875602);

    __m256i o0 = mul(d[7], FIX_0_298631336);
    __m256i o1 = mul(d[5], FIX_2_053119869);
    __m256i o2 = mul(d[3], FIX_3_072711026);
    __m256i o3 = mul(d[1], FIX_1_501321110);

    z1 = mul(z1, -FIX_0_899976223);
    z2 = mul(z2, -FIX_2_562915447);
    z3 = _mm256_add_epi32(mul(z3, -FIX_1_961570560), z5);
    z4 = _mm256_add_epi32(mul(z4, -FIX_0_390180644), z5);

    o0 = _mm256_add_epi32(o0, _mm256_add_epi32(z1, z3));
    o1 = _mm256_add_epi32(o1, _mm256_add_epi32(z2, z4));
    o2 = _mm256_add_epi32(o2, _mm256_add_epi32(z2, z3));
    o3 = _mm256_add_epi32(o3, _mm256_add_epi32(z1, z4));

    __m256i r0 = descale(_mm256_add_epi32(t10, o3), drop);
    __m256i r7 = descale(_mm256_sub_epi32(t10, o3), drop);
    __m256i r1 = descale(_mm256_add_epi32(t11, o2), drop);
    __m256i r6 = descale(_mm256_sub_epi32(t11, o2), drop);
    __m256i r2 = descale(_mm256_add_epi32(t12, o1), drop);
    __m256i r5 = descale(_mm256_sub_epi32(t12, o1), drop);
    __m256i r3 = descale(_mm256_add_epi32(t13, o0), drop);
    __m256i r4 = descale(_mm256_sub_epi32(t13, o0), drop);

    d[0] = r0; d[1] = r1; d[2] = r2; d[3] = r3;
    d[4] = r4; d[5] = r5; d[6] = r6; d[7] = r7;
}

TARGET_AVX2
void jpeg_accel_idct8_avx2(const int32_t *_Nonnull coefficients,
                           int32_t precision, uint16_t *_Nonnull samples) {
    __m256i d[8];
    for (int i = 0; i < 8; i++) {
        d[i] = _mm256_loadu_si256((const __m256i *)(coefficients + i * 8));
    }

    /* A vector is one row of frequencies, so combining vectors is the column
     * pass. The row pass has to combine lanes, which is what the transpose is
     * for; the second transpose puts the result back in row order. */
    idct_pass(d, CONST_BITS - PASS_BITS);
    transpose8(d);
    idct_pass(d, CONST_BITS + PASS_BITS + 3);
    transpose8(d);

    /* T.81 A.3.1 level shift, then clamp into the sample range. Clamping is
     * not defensive: a lossily quantized block routinely reconstructs a few
     * counts outside it. */
    const __m256i shift = _mm256_set1_epi32(1 << (precision - 1));
    const __m256i floor = _mm256_setzero_si256();
    const __m256i ceiling = _mm256_set1_epi32((1 << precision) - 1);

    for (int i = 0; i < 8; i += 2) {
        __m256i a = _mm256_add_epi32(d[i], shift);
        __m256i b = _mm256_add_epi32(d[i + 1], shift);
        a = _mm256_min_epi32(_mm256_max_epi32(a, floor), ceiling);
        b = _mm256_min_epi32(_mm256_max_epi32(b, floor), ceiling);

        /* packus interleaves the two 128-bit halves; the permute undoes that
         * so the store lays down row i followed by row i + 1. */
        __m256i packed = _mm256_packus_epi32(a, b);
        packed = _mm256_permute4x64_epi64(packed, 0xD8);
        _mm256_storeu_si256((__m256i *)(samples + i * 8), packed);
    }
}

/* One 8-point forward transform across eight vectors. */
TARGET_AVX2 static inline void fdct_pass(__m256i *d, int evenDrop, int oddDrop,
                                         int evenShift) {
    /* The transform of a sequence splits into the transform of its symmetric
     * part, giving the even frequencies, and its antisymmetric part, giving
     * the odd. */
    __m256i s0 = _mm256_add_epi32(d[0], d[7]);
    __m256i a7 = _mm256_sub_epi32(d[0], d[7]);
    __m256i s1 = _mm256_add_epi32(d[1], d[6]);
    __m256i a6 = _mm256_sub_epi32(d[1], d[6]);
    __m256i s2 = _mm256_add_epi32(d[2], d[5]);
    __m256i a5 = _mm256_sub_epi32(d[2], d[5]);
    __m256i s3 = _mm256_add_epi32(d[3], d[4]);
    __m256i a4 = _mm256_sub_epi32(d[3], d[4]);

    __m256i t10 = _mm256_add_epi32(s0, s3);
    __m256i t13 = _mm256_sub_epi32(s0, s3);
    __m256i t11 = _mm256_add_epi32(s1, s2);
    __m256i t12 = _mm256_sub_epi32(s1, s2);

    __m256i r0, r4;
    if (evenShift > 0) {
        r0 = _mm256_slli_epi32(_mm256_add_epi32(t10, t11), evenShift);
        r4 = _mm256_slli_epi32(_mm256_sub_epi32(t10, t11), evenShift);
    } else {
        r0 = descale(_mm256_add_epi32(t10, t11), -evenShift);
        r4 = descale(_mm256_sub_epi32(t10, t11), -evenShift);
    }

    __m256i z1 = mul(_mm256_add_epi32(t12, t13), FIX_0_541196100);
    __m256i r2 = descale(_mm256_add_epi32(z1, mul(t13, FIX_0_765366865)), evenDrop);
    __m256i r6 = descale(_mm256_sub_epi32(z1, mul(t12, FIX_1_847759065)), evenDrop);

    __m256i y1 = _mm256_add_epi32(a4, a7);
    __m256i y2 = _mm256_add_epi32(a5, a6);
    __m256i y3 = _mm256_add_epi32(a4, a6);
    __m256i y4 = _mm256_add_epi32(a5, a7);
    __m256i y5 = mul(_mm256_add_epi32(y3, y4), FIX_1_175875602);

    __m256i o4 = mul(a4, FIX_0_298631336);
    __m256i o5 = mul(a5, FIX_2_053119869);
    __m256i o6 = mul(a6, FIX_3_072711026);
    __m256i o7 = mul(a7, FIX_1_501321110);

    y1 = mul(y1, -FIX_0_899976223);
    y2 = mul(y2, -FIX_2_562915447);
    y3 = _mm256_add_epi32(mul(y3, -FIX_1_961570560), y5);
    y4 = _mm256_add_epi32(mul(y4, -FIX_0_390180644), y5);

    __m256i r7 = descale(_mm256_add_epi32(o4, _mm256_add_epi32(y1, y3)), oddDrop);
    __m256i r5 = descale(_mm256_add_epi32(o5, _mm256_add_epi32(y2, y4)), oddDrop);
    __m256i r3 = descale(_mm256_add_epi32(o6, _mm256_add_epi32(y2, y3)), oddDrop);
    __m256i r1 = descale(_mm256_add_epi32(o7, _mm256_add_epi32(y1, y4)), oddDrop);

    d[0] = r0; d[1] = r1; d[2] = r2; d[3] = r3;
    d[4] = r4; d[5] = r5; d[6] = r6; d[7] = r7;
}

TARGET_AVX2
void jpeg_accel_fdct8_avx2(const uint16_t *_Nonnull samples,
                           int32_t precision, int32_t *_Nonnull coefficients) {
    const __m256i level = _mm256_set1_epi32(1 << (precision - 1));

    __m256i d[8];
    for (int i = 0; i < 8; i++) {
        /* Widen eight samples to 32 bits and recenter them on zero. */
        __m128i raw = _mm_loadu_si128((const __m128i *)(samples + i * 8));
        d[i] = _mm256_sub_epi32(_mm256_cvtepu16_epi32(raw), level);
    }

    /* The portable kernel runs the row pass first, and the order matters for
     * the rounding, so this transposes up front to make rows the cheap axis
     * rather than reordering the passes. */
    transpose8(d);
    fdct_pass(d, CONST_BITS - PASS_BITS, CONST_BITS - PASS_BITS, PASS_BITS);
    transpose8(d);
    fdct_pass(d, CONST_BITS + PASS_BITS + SCALE_BITS,
              CONST_BITS + PASS_BITS + SCALE_BITS, -(PASS_BITS + SCALE_BITS));

    for (int i = 0; i < 8; i++) {
        _mm256_storeu_si256((__m256i *)(coefficients + i * 8), d[i]);
    }
}

#else

void jpeg_accel_idct8_avx2(const int32_t *_Nonnull coefficients,
                           int32_t precision, uint16_t *_Nonnull samples) {
    (void)coefficients; (void)precision; (void)samples;
}

void jpeg_accel_fdct8_avx2(const uint16_t *_Nonnull samples,
                           int32_t precision, int32_t *_Nonnull coefficients) {
    (void)samples; (void)precision; (void)coefficients;
}

#endif
