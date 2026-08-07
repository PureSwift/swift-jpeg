#include "include/jpeg_accel.h"

/* NEON YCbCr to RGB conversion.
 *
 * Much shorter than the AVX2 version, and for one reason: NEON has a
 * three-channel deinterleaving load and a three-channel interleaving store.
 * `vld3q_u16` and `vst3_u8` are the whole of what took nine shuffles and six
 * ors at each end there. The arithmetic in between is the same nine multiplies
 * and the same fixed-point constants.
 *
 * The register is half as wide, so a block of eight pixels is two vectors of
 * four 32-bit lanes rather than one of eight. That costs a little of the
 * advantage back, but not the deinterleave — the load produces eight pixels
 * whatever the arithmetic width is.
 *
 * As on AVX2, the clamp is free: the two narrowing moves that pack the result
 * saturate, and int32 to int16 to uint8 saturates to exactly 0 ... 255.
 */

#if defined(__aarch64__) || defined(_M_ARM64)

#include <arm_neon.h>

/* JFIF §7 in 16-bit fixed point. The same constants as Format.swift, which is
 * what makes the two agree exactly rather than approximately. */
#define HALF 32768
#define CR_TO_R 91881
#define CB_TO_G (-22554)
#define CR_TO_G (-46802)
#define CB_TO_B 116130

/* Converts four pixels held as three 32-bit vectors. */
static inline void convert4(int32x4_t y32, int32x4_t cb32, int32x4_t cr32,
                            int32x4_t *r, int32x4_t *g, int32x4_t *b) {
    const int32x4_t y = vaddq_s32(vshlq_n_s32(y32, 16), vdupq_n_s32(HALF));
    const int32x4_t cb = vsubq_s32(cb32, vdupq_n_s32(128));
    const int32x4_t cr = vsubq_s32(cr32, vdupq_n_s32(128));

    *r = vmlaq_n_s32(y, cr, CR_TO_R);
    *g = vmlaq_n_s32(vmlaq_n_s32(y, cb, CB_TO_G), cr, CR_TO_G);
    *b = vmlaq_n_s32(y, cb, CB_TO_B);
}

/* Descales both halves by sixteen places and packs them into eight clamped
 * bytes. Both narrowing moves saturate, which is where the clamp comes from. */
static inline uint8x8_t pack(int32x4_t lo, int32x4_t hi) {
    return vqmovun_s16(vcombine_s16(vqmovn_s32(vshrq_n_s32(lo, 16)),
                                    vqmovn_s32(vshrq_n_s32(hi, 16))));
}

static void ycc_to_rgb_neon(const uint16_t *interleaved, ptrdiff_t count,
                            int32_t shift, uint8_t *rgb) {
    /* One shift instruction covers both directions: a negative count on
     * `vshlq_u16` is a logical right shift, so the loop body does not branch on
     * the sign of the precision correction. */
    const int16x8_t by = vdupq_n_s16((int16_t)-shift);
    const uint16x8_t byte = vdupq_n_u16(0x00FF);

    for (ptrdiff_t i = 0; i < count; i += 8) {
        const uint16x8x3_t in = vld3q_u16(interleaved + 3 * i);

        const uint16x8_t y = vandq_u16(vshlq_u16(in.val[0], by), byte);
        const uint16x8_t cb = vandq_u16(vshlq_u16(in.val[1], by), byte);
        const uint16x8_t cr = vandq_u16(vshlq_u16(in.val[2], by), byte);

        int32x4_t rlo, glo, blo, rhi, ghi, bhi;
        convert4(vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(y))),
                 vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(cb))),
                 vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(cr))),
                 &rlo, &glo, &blo);
        convert4(vreinterpretq_s32_u32(vmovl_high_u16(y)),
                 vreinterpretq_s32_u32(vmovl_high_u16(cb)),
                 vreinterpretq_s32_u32(vmovl_high_u16(cr)),
                 &rhi, &ghi, &bhi);

        uint8x8x3_t out;
        out.val[0] = pack(rlo, rhi);
        out.val[1] = pack(glo, ghi);
        out.val[2] = pack(blo, bhi);
        vst3_u8(rgb + 3 * i, out);
    }
}

#endif

/* The tail, and the whole thing on a processor without NEON.
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

void jpeg_accel_ycc_to_rgb_neon(const uint16_t *interleaved, ptrdiff_t count,
                                int32_t shift, uint8_t *rgb) {
#if defined(__aarch64__) || defined(_M_ARM64)
    const ptrdiff_t vectored = count & ~(ptrdiff_t)7;
    if (vectored > 0) {
        ycc_to_rgb_neon(interleaved, vectored, shift, rgb);
    }
    interleaved += 3 * vectored;
    rgb += 3 * vectored;
    count -= vectored;
#endif
    ycc_to_rgb_scalar(interleaved, count, shift < 0 ? -shift : 0,
                      shift > 0 ? shift : 0, rgb);
}
