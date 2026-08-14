#include "include/jpeg_accel.h"

/* AVX2 4:2:0 chroma upsampling, eight output pairs per iteration.
 *
 * The engine's collapsed blend is four multiplies by small constants and a
 * shift per output sample, with no dependency between pairs — ideal vector
 * material. The only cleverness here is in the store: `even` and `odd` are
 * computed in 32-bit lanes, and both are at most 65535, so
 *
 *     even | odd << 16
 *
 * makes each 32-bit lane exactly the two little-endian uint16_t of one output
 * pair, in order. One OR replaces the whole pack-and-interleave dance the
 * color kernels have to do.
 *
 * `3 * above[i]` is shared between a pair's even sample and its odd one, and
 * between this pair's odd sample and the next pair's even one is a different
 * value — so it is computed once per column, not hoisted across iterations.
 * The rotation the scalar loop does to save loads buys nothing here: the
 * vector loads overlap by construction.
 */

static void upsample_pairs_scalar(const uint16_t *above, const uint16_t *below,
                                  ptrdiff_t pairs, int32_t v0, int32_t v1,
                                  uint16_t *out) {
    for (ptrdiff_t i = 0; i < pairs; i++) {
        const int32_t a3 = 3 * above[i];
        const int32_t b3 = 3 * below[i];
        out[2 * i] = (uint16_t)((v0 * (above[i - 1] + a3)
                               + v1 * (below[i - 1] + b3) + 8) >> 4);
        out[2 * i + 1] = (uint16_t)((v0 * (a3 + above[i + 1])
                                   + v1 * (b3 + below[i + 1]) + 8) >> 4);
    }
}

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)

#include <immintrin.h>

#define TARGET_AVX2 __attribute__((target("avx2")))

TARGET_AVX2 static void upsample_pairs_vector(const uint16_t *above,
                                              const uint16_t *below,
                                              ptrdiff_t pairs, int32_t v0,
                                              int32_t v1, uint16_t *out) {
    const __m256i w0 = _mm256_set1_epi32(v0);
    const __m256i w1 = _mm256_set1_epi32(v1);
    const __m256i eight = _mm256_set1_epi32(8);

    for (ptrdiff_t i = 0; i < pairs; i += 8) {
        /* Three overlapping loads per row: columns i-1, i and i+1 for eight
         * pairs at once, widened to 32-bit lanes. The overread past `pairs`
         * stays within the row, because the caller guarantees one readable
         * column beyond the last pair and the loop guarantees i + 8 <= pairs. */
        const __m256i am1 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(above + i - 1)));
        const __m256i a0 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(above + i)));
        const __m256i ap1 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(above + i + 1)));
        const __m256i bm1 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(below + i - 1)));
        const __m256i b0 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(below + i)));
        const __m256i bp1 = _mm256_cvtepu16_epi32(
            _mm_loadu_si128((const __m128i *)(below + i + 1)));

        /* 3x as shift-and-add; vpmulld is three cycles where these are one. */
        const __m256i a3 = _mm256_add_epi32(a0, _mm256_slli_epi32(a0, 1));
        const __m256i b3 = _mm256_add_epi32(b0, _mm256_slli_epi32(b0, 1));

        const __m256i te = _mm256_add_epi32(am1, a3);
        const __m256i to = _mm256_add_epi32(ap1, a3);
        const __m256i ue = _mm256_add_epi32(bm1, b3);
        const __m256i uo = _mm256_add_epi32(bp1, b3);

        const __m256i even = _mm256_srli_epi32(
            _mm256_add_epi32(_mm256_add_epi32(_mm256_mullo_epi32(te, w0),
                                              _mm256_mullo_epi32(ue, w1)),
                             eight),
            4);
        const __m256i odd = _mm256_srli_epi32(
            _mm256_add_epi32(_mm256_add_epi32(_mm256_mullo_epi32(to, w0),
                                              _mm256_mullo_epi32(uo, w1)),
                             eight),
            4);

        _mm256_storeu_si256((__m256i *)(out + 2 * i),
                            _mm256_or_si256(even, _mm256_slli_epi32(odd, 16)));
    }
}

void jpeg_accel_upsample_pairs_avx2(const uint16_t *above,
                                    const uint16_t *below, ptrdiff_t pairs,
                                    int32_t v0, int32_t v1, uint16_t *out) {
    const ptrdiff_t vectored = pairs & ~(ptrdiff_t)7;
    if (vectored > 0) {
        upsample_pairs_vector(above, below, vectored, v0, v1, out);
    }
    upsample_pairs_scalar(above + vectored, below + vectored, pairs - vectored,
                          v0, v1, out + 2 * vectored);
}

#else

/* The symbol has to exist to link; availability keeps it from installing. */
void jpeg_accel_upsample_pairs_avx2(const uint16_t *above,
                                    const uint16_t *below, ptrdiff_t pairs,
                                    int32_t v0, int32_t v1, uint16_t *out) {
    upsample_pairs_scalar(above, below, pairs, v0, v1, out);
}

#endif
