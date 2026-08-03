#ifndef SWIFT_JPEG_ACCEL_H
#define SWIFT_JPEG_ACCEL_H

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

/* Nullability is annotated so these import into Swift as non-optional
 * pointers, which is what lets them be assigned to the engine's dispatch seam
 * directly rather than through a wrapper that exists only to unwrap. */

/* 64 dequantized coefficients, row-major, to 64 samples, row-major. */
void jpeg_accel_idct8_avx2(const int32_t *_Nonnull coefficients,
                           int32_t precision,
                           uint16_t *_Nonnull samples);

/* 64 samples, row-major, to 64 coefficients, row-major. */
void jpeg_accel_fdct8_avx2(const uint16_t *_Nonnull samples,
                           int32_t precision,
                           int32_t *_Nonnull coefficients);

#endif
