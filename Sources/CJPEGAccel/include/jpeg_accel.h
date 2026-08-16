#ifndef SWIFT_JPEG_ACCEL_H
#define SWIFT_JPEG_ACCEL_H

#include <stddef.h>
#include <stdint.h>

/* Accelerated transform kernels.
 *
 * These match the signatures of JPEG.Kernel.InverseTransform and
 * JPEG.Kernel.ForwardTransform on the Swift side, so they can be installed
 * into the engine's dispatch seam directly.
 *
 * They compute the same transforms as the portable Swift ones and agree with
 * them to within a count — the same bar the portable factored transforms are
 * held to against the direct form, and for the same reason: these are
 * different roundings of one real-valued transform, not different transforms.
 *
 * Arithmetic is 32-bit where the portable path uses 64-bit. That is the width
 * libjpeg has used for this transform for thirty years and it is sound for the
 * coefficient ranges a conforming 8- or 12-bit image produces. It is also the
 * only reason the vectorization is worth anything: eight lanes of 32-bit fit a
 * register where four lanes of 64-bit would, and AVX2 has no 64-bit multiply.
 */

/* Whether the running processor can execute the AVX2 kernels. */
int jpeg_accel_avx2_available(void);

/* Whether the running processor can execute the NEON kernels.
 *
 * NEON is mandatory on AArch64, so this is really asking whether the library
 * was built for AArch64 at all. It is a function rather than a compile-time
 * check so that the Swift side selects kernels the same way on every
 * architecture. */
int jpeg_accel_neon_available(void);

/* Nullability is annotated so these import into Swift as non-optional
 * pointers, which is what lets them be assigned to the engine's dispatch seam
 * directly rather than through a wrapper that exists only to unwrap.
 *
 * The annotation is a Clang extension. SwiftPM always compiles this with
 * Clang, but the CMake build may be using GCC, so it has to degrade to nothing
 * rather than fail to parse. */
#if defined(__clang__)
#define JPEG_NONNULL _Nonnull
#else
#define JPEG_NONNULL
/* One row of 2x horizontal upsampling for a plane that is halved vertically
 * too, which is 4:2:0 chroma. `pairs` pairs of output samples, contiguous.
 *
 * Pair `i` interpolates source columns i-1, i and i+1 of the two source rows:
 *
 *     out[2i]     = (v0 * (above[i-1] + 3 * above[i])
 *                  + v1 * (below[i-1] + 3 * below[i]) + 8) >> 4
 *     out[2i + 1] = (v0 * (3 * above[i] + above[i+1])
 *                  + v1 * (3 * below[i] + below[i+1]) + 8) >> 4
 *
 * with (v0, v1) either (1, 3) or (3, 1) by which side of the source row pair
 * the output row falls on. This is the engine's collapsed bilinear blend,
 * integer for integer; the caller holds it to bit equality with the scalar
 * loop, not to within a count.
 *
 * Reads above[-1 .. pairs] and below[-1 .. pairs] inclusive — one column each
 * side of the pairs — so the caller must point into the interior of the row,
 * which is where the engine uses it: the clamped edge columns take its
 * tabulated path instead.
 *
 * Unlike the other kernels this one has no portable twin behind the dispatch
 * seam. The engine writes its output interleaved, so calling any row kernel
 * costs a scatter from this contiguous row afterward; that trade only pays
 * when the arithmetic gets vector-cheap, and the engine's inline loop is the
 * portable implementation.
 */
void jpeg_accel_upsample_pairs_avx2(const uint16_t *JPEG_NONNULL above,
                                    const uint16_t *JPEG_NONNULL below,
                                    ptrdiff_t pairs,
                                    int32_t v0,
                                    int32_t v1,
                                    uint16_t *JPEG_NONNULL out);

#endif

/* 64 dequantized coefficients, row-major, to 64 samples, row-major. */
void jpeg_accel_idct8_avx2(const int32_t *JPEG_NONNULL coefficients,
                           int32_t precision,
                           uint16_t *JPEG_NONNULL samples);

/* 64 quantized levels and their 64 quantization factors, row-major, to 64
 * samples, row-major — dequantization and the inverse transform in one call.
 *
 * `samples[i]` is what `jpeg_accel_idct8_avx2` produces from
 * `levels[i] * factors[i]`, and the caller holds this to bit equality with
 * that pair rather than to a tolerance: it is the same transform, reached
 * without the intermediate block touching memory.
 *
 * A level fits int16 and a factor uint16, so the product is at most 2147385345
 * and fits a signed 32-bit lane.
 *
 * Full size only. The reduced scales have no factorization and dequantize
 * through the engine's own path. */
void jpeg_accel_dequantize_idct8_avx2(const int16_t *JPEG_NONNULL levels,
                                      const uint16_t *JPEG_NONNULL factors,
                                      int32_t precision,
                                      uint16_t *JPEG_NONNULL samples);

/* 64 samples, row-major, to 64 coefficients, row-major. */
void jpeg_accel_fdct8_avx2(const uint16_t *JPEG_NONNULL samples,
                           int32_t precision,
                           int32_t *JPEG_NONNULL coefficients);

/* The same two, for AArch64. */
void jpeg_accel_idct8_neon(const int32_t *JPEG_NONNULL coefficients,
                           int32_t precision,
                           uint16_t *JPEG_NONNULL samples);

void jpeg_accel_fdct8_neon(const uint16_t *JPEG_NONNULL samples,
                           int32_t precision,
                           int32_t *JPEG_NONNULL coefficients);

/* `count` interleaved YCbCr samples to `count` packed RGB pixels.
 *
 * Reads 3 * count uint16_t and writes 3 * count uint8_t. `shift` narrows a
 * sample to eight bits: positive shifts right, negative shifts left, and the
 * result is truncated rather than clamped, which is what the engine's own
 * narrowing does.
 *
 * Unlike the transforms, these are exact rather than agreeing to within a
 * count. The conversion is a fixed-point matrix, not a factorization with
 * intermediate roundings, so there is nothing for two implementations to
 * disagree about — and a colour kernel that was off by one would tint every
 * pixel of every image this library decodes.
 */
void jpeg_accel_ycc_to_rgb_avx2(const uint16_t *JPEG_NONNULL interleaved,
                                ptrdiff_t count,
                                int32_t shift,
                                uint8_t *JPEG_NONNULL rgb);

void jpeg_accel_ycc_to_rgb_neon(const uint16_t *JPEG_NONNULL interleaved,
                                ptrdiff_t count,
                                int32_t shift,
                                uint8_t *JPEG_NONNULL rgb);

/* `count` packed pixels to `count` interleaved YCbCr samples.
 *
 * Reads count * size uint8_t and writes 3 * count uint16_t. The pixels are
 * `size` bytes apart and the three channels sit at `red`, `green` and `blue`
 * within one, which is what lets a caller's own pixel order be converted in
 * place rather than copied into RGB order first.
 *
 * Exact against the portable arithmetic, for the same reason as the decoding
 * direction: one fixed-point matrix with one rounding.
 */
void jpeg_accel_rgb_to_ycc_avx2(const uint8_t *JPEG_NONNULL pixels,
                                int32_t size,
                                int32_t red,
                                int32_t green,
                                int32_t blue,
                                ptrdiff_t count,
                                uint16_t *JPEG_NONNULL interleaved);

void jpeg_accel_rgb_to_ycc_neon(const uint8_t *JPEG_NONNULL pixels,
                                int32_t size,
                                int32_t red,
                                int32_t green,
                                int32_t blue,
                                ptrdiff_t count,
                                uint16_t *JPEG_NONNULL interleaved);

/* One row of 2x horizontal upsampling for a plane that is halved vertically
 * too, which is 4:2:0 chroma. `pairs` pairs of output samples, contiguous.
 *
 * Pair `i` interpolates source columns i-1, i and i+1 of the two source rows:
 *
 *     out[2i]     = (v0 * (above[i-1] + 3 * above[i])
 *                  + v1 * (below[i-1] + 3 * below[i]) + 8) >> 4
 *     out[2i + 1] = (v0 * (3 * above[i] + above[i+1])
 *                  + v1 * (3 * below[i] + below[i+1]) + 8) >> 4
 *
 * with (v0, v1) either (1, 3) or (3, 1) by which side of the source row pair
 * the output row falls on. This is the engine's collapsed bilinear blend,
 * integer for integer; the caller holds it to bit equality with the scalar
 * loop, not to within a count.
 *
 * Reads above[-1 .. pairs] and below[-1 .. pairs] inclusive — one column each
 * side of the pairs — so the caller must point into the interior of the row,
 * which is where the engine uses it: the clamped edge columns take its
 * tabulated path instead.
 *
 * Unlike the other kernels this one has no portable twin behind the dispatch
 * seam. The engine writes its output interleaved, so calling any row kernel
 * costs a scatter from this contiguous row afterward; that trade only pays
 * when the arithmetic gets vector-cheap, and the engine's inline loop is the
 * portable implementation.
 */
void jpeg_accel_upsample_pairs_avx2(const uint16_t *JPEG_NONNULL above,
                                    const uint16_t *JPEG_NONNULL below,
                                    ptrdiff_t pairs,
                                    int32_t v0,
                                    int32_t v1,
                                    uint16_t *JPEG_NONNULL out);

#endif
