#ifndef SWIFT_JPEG_CPUFEATURES_H
#define SWIFT_JPEG_CPUFEATURES_H

#include <stdint.h>

/* Instruction set extensions this library has accelerated kernels for.
 *
 * A bit set here means the running processor supports the extension, not that
 * a kernel using it exists. Detection and use are deliberately separate: the
 * detection is cheap, stable and testable on its own, and a kernel that has
 * not been written yet should not require touching this file.
 */
enum jpeg_cpu_feature {
    JPEG_CPU_SSE2   = 1u << 0,
    JPEG_CPU_SSSE3  = 1u << 1,
    JPEG_CPU_SSE41  = 1u << 2,
    JPEG_CPU_AVX2   = 1u << 3,
    JPEG_CPU_NEON   = 1u << 4,
};

/* The extensions the running processor supports.
 *
 * Computed once on first call and cached; the answer cannot change while the
 * process is alive. Returns 0 on architectures this does not know about, which
 * is the correct answer for "use the portable path".
 */
uint32_t jpeg_cpu_features(void);

#endif
