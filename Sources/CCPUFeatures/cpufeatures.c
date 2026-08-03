#include "include/cpufeatures.h"

/* Runtime CPU feature detection.
 *
 * This exists because a shared library is built once and run on whatever the
 * user has. Compiling the whole library for AVX2 would make it crash on
 * anything older; compiling it for the baseline leaves most of the register
 * file unused on everything newer. libjpeg-turbo resolves this by detecting at
 * runtime and calling into one of several kernels, and so does this.
 *
 * C rather than Swift because Swift has no inline assembly and no cpuid
 * intrinsic. It is a dozen lines and it is the only reason the accelerated
 * path needs a C target at all.
 */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)

#if defined(_MSC_VER)
#include <intrin.h>
static void jpeg_cpuid(int leaf, int subleaf, unsigned int regs[4]) {
    __cpuidex((int *)regs, leaf, subleaf);
}
#else
#include <cpuid.h>
static void jpeg_cpuid(int leaf, int subleaf, unsigned int regs[4]) {
    __cpuid_count(leaf, subleaf, regs[0], regs[1], regs[2], regs[3]);
}
#endif

/* Whether the operating system has enabled the wide register state.
 *
 * A processor can support AVX2 while the OS does not preserve the YMM
 * registers across a context switch, and using them then corrupts other
 * processes' state. The XGETBV check is not optional pedantry — it is the
 * difference between "the silicon can" and "you may".
 */
static int jpeg_ymm_enabled(void) {
    unsigned int regs[4];
    jpeg_cpuid(1, 0, regs);

    const unsigned int OSXSAVE = 1u << 27;
    const unsigned int AVX = 1u << 28;
    if (!(regs[2] & OSXSAVE) || !(regs[2] & AVX)) {
        return 0;
    }

#if defined(_MSC_VER)
    unsigned long long xcr0 = _xgetbv(0);
#else
    unsigned int lo, hi;
    __asm__ __volatile__("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    unsigned long long xcr0 = ((unsigned long long)hi << 32) | lo;
#endif
    /* Bit 1 is XMM state, bit 2 is YMM state. Both must be saved. */
    return (xcr0 & 0x6) == 0x6;
}

static uint32_t jpeg_detect(void) {
    uint32_t features = 0;
    unsigned int regs[4];

    jpeg_cpuid(0, 0, regs);
    const unsigned int highest = regs[0];

    if (highest >= 1) {
        jpeg_cpuid(1, 0, regs);
        if (regs[3] & (1u << 26)) { features |= JPEG_CPU_SSE2; }
        if (regs[2] & (1u << 9))  { features |= JPEG_CPU_SSSE3; }
        if (regs[2] & (1u << 19)) { features |= JPEG_CPU_SSE41; }
    }

    if (highest >= 7 && jpeg_ymm_enabled()) {
        jpeg_cpuid(7, 0, regs);
        if (regs[1] & (1u << 5)) { features |= JPEG_CPU_AVX2; }
    }

    return features;
}

#elif defined(__aarch64__) || defined(_M_ARM64)

/* NEON is mandatory on AArch64, so there is nothing to detect. */
static uint32_t jpeg_detect(void) {
    return JPEG_CPU_NEON;
}

#else

static uint32_t jpeg_detect(void) {
    return 0;
}

#endif

uint32_t jpeg_cpu_features(void) {
    /* Benign race: two threads may both compute this, and they will compute
     * the same value, so the only cost is doing it twice. A lock here would be
     * more machinery than the thing it guards. The sentinel is a high bit no
     * real feature set uses, so that a genuine answer of zero still caches. */
    static uint32_t cached = 0xFFFFFFFFu;
    if (cached == 0xFFFFFFFFu) {
        cached = jpeg_detect();
    }
    return cached;
}
