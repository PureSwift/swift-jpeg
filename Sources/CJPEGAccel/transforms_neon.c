#include "include/jpeg_accel.h"
#include <cpufeatures.h>

/* NEON transform kernels.
 *
 * The same Loeffler-Ligtenberg-Moschytz factorization as the AVX2 and portable
 * kernels. Kept as a separate implementation rather than shared with the AVX2
 * one through macros: the two differ in register width, in how a transpose is
 * expressed, and in which operations exist at all, and a version abstracted
 * over those differences would be harder to check against the algorithm than
 * either of them is now.
 *
 * The width is the main difference. A NEON register holds four 32-bit lanes
 * where an AVX2 register holds eight, so a row of the block is a pair of
 * registers rather than one. That pair is what `v8` is, and the helpers below
 * exist so the transform itself reads the same as the AVX2 version.
 *
 * There is no runtime detection to do. NEON is mandatory on AArch64, so if
 * this compiles for the target it can run.
 */

int jpeg_accel_neon_available(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
    return (jpeg_cpu_features() & JPEG_CPU_NEON) != 0;
#else
    return 0;
#endif
}

#if defined(__aarch64__) || defined(_M_ARM64)

#include <arm_neon.h>

#define CONST_BITS 13
#define PASS_BITS 2
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

/* Eight 32-bit lanes across two registers. */
typedef struct {
    int32x4_t lo;
    int32x4_t hi;
} v8;

static inline v8 v_add(v8 a, v8 b) {
    v8 r = { vaddq_s32(a.lo, b.lo), vaddq_s32(a.hi, b.hi) };
    return r;
}

static inline v8 v_sub(v8 a, v8 b) {
    v8 r = { vsubq_s32(a.lo, b.lo), vsubq_s32(a.hi, b.hi) };
    return r;
}

static inline v8 v_mul(v8 a, int32_t k) {
    const int32x4_t v = vdupq_n_s32(k);
    v8 r = { vmulq_s32(a.lo, v), vmulq_s32(a.hi, v) };
    return r;
}

static inline v8 v_shl(v8 a, int n) {
    const int32x4_t v = vdupq_n_s32(n);
    v8 r = { vshlq_s32(a.lo, v), vshlq_s32(a.hi, v) };
    return r;
}

/* Round to nearest, `bits` places down.
 *
 * A negative shift count is how NEON spells a right shift when the amount is
 * not a compile-time constant, which it is not here — the two passes descale
 * by different amounts through the same code.
 */
static inline v8 v_descale(v8 a, int bits) {
    const int32x4_t rounding = vdupq_n_s32(1 << (bits - 1));
    const int32x4_t shift = vdupq_n_s32(-bits);
    v8 r = {
        vshlq_s32(vaddq_s32(a.lo, rounding), shift),
        vshlq_s32(vaddq_s32(a.hi, rounding), shift),
    };
    return r;
}

/* Transpose four rows of four 32-bit values. */
static inline void transpose4(int32x4_t *a, int32x4_t *b,
                              int32x4_t *c, int32x4_t *d) {
    int32x4x2_t t0 = vtrnq_s32(*a, *b);
    int32x4x2_t t1 = vtrnq_s32(*c, *d);
    *a = vcombine_s32(vget_low_s32(t0.val[0]), vget_low_s32(t1.val[0]));
    *b = vcombine_s32(vget_low_s32(t0.val[1]), vget_low_s32(t1.val[1]));
    *c = vcombine_s32(vget_high_s32(t0.val[0]), vget_high_s32(t1.val[0]));
    *d = vcombine_s32(vget_high_s32(t0.val[1]), vget_high_s32(t1.val[1]));
}

/* Transpose the 8x8 block.
 *
 * With four-wide registers the block is four 4x4 quadrants. Transposing the
 * whole thing is transposing each quadrant and then exchanging the two
 * off-diagonal ones, because the transpose of a block matrix swaps those.
 */
static inline void transpose8(v8 *r) {
    int32x4_t a0 = r[0].lo, a1 = r[1].lo, a2 = r[2].lo, a3 = r[3].lo;
    int32x4_t b0 = r[0].hi, b1 = r[1].hi, b2 = r[2].hi, b3 = r[3].hi;
    int32x4_t c0 = r[4].lo, c1 = r[5].lo, c2 = r[6].lo, c3 = r[7].lo;
    int32x4_t d0 = r[4].hi, d1 = r[5].hi, d2 = r[6].hi, d3 = r[7].hi;

    transpose4(&a0, &a1, &a2, &a3);
    transpose4(&b0, &b1, &b2, &b3);
    transpose4(&c0, &c1, &c2, &c3);
    transpose4(&d0, &d1, &d2, &d3);

    r[0].lo = a0; r[1].lo = a1; r[2].lo = a2; r[3].lo = a3;
    r[0].hi = c0; r[1].hi = c1; r[2].hi = c2; r[3].hi = c3;
    r[4].lo = b0; r[5].lo = b1; r[6].lo = b2; r[7].lo = b3;
    r[4].hi = d0; r[5].hi = d1; r[6].hi = d2; r[7].hi = d3;
}

/* One 8-point inverse transform across the eight rows. */
static inline void idct_pass(v8 *d, int drop) {
    v8 e1 = v_mul(v_add(d[2], d[6]), FIX_0_541196100);
    v8 e2 = v_sub(e1, v_mul(d[6], FIX_1_847759065));
    v8 e3 = v_add(e1, v_mul(d[2], FIX_0_765366865));
    v8 e0 = v_shl(v_add(d[0], d[4]), CONST_BITS);
    v8 ex = v_shl(v_sub(d[0], d[4]), CONST_BITS);

    v8 t10 = v_add(e0, e3);
    v8 t13 = v_sub(e0, e3);
    v8 t11 = v_add(ex, e2);
    v8 t12 = v_sub(ex, e2);

    v8 z1 = v_add(d[7], d[1]);
    v8 z2 = v_add(d[5], d[3]);
    v8 z3 = v_add(d[7], d[3]);
    v8 z4 = v_add(d[5], d[1]);
    v8 z5 = v_mul(v_add(z3, z4), FIX_1_175875602);

    v8 o0 = v_mul(d[7], FIX_0_298631336);
    v8 o1 = v_mul(d[5], FIX_2_053119869);
    v8 o2 = v_mul(d[3], FIX_3_072711026);
    v8 o3 = v_mul(d[1], FIX_1_501321110);

    z1 = v_mul(z1, -FIX_0_899976223);
    z2 = v_mul(z2, -FIX_2_562915447);
    z3 = v_add(v_mul(z3, -FIX_1_961570560), z5);
    z4 = v_add(v_mul(z4, -FIX_0_390180644), z5);

    o0 = v_add(o0, v_add(z1, z3));
    o1 = v_add(o1, v_add(z2, z4));
    o2 = v_add(o2, v_add(z2, z3));
    o3 = v_add(o3, v_add(z1, z4));

    v8 r0 = v_descale(v_add(t10, o3), drop);
    v8 r7 = v_descale(v_sub(t10, o3), drop);
    v8 r1 = v_descale(v_add(t11, o2), drop);
    v8 r6 = v_descale(v_sub(t11, o2), drop);
    v8 r2 = v_descale(v_add(t12, o1), drop);
    v8 r5 = v_descale(v_sub(t12, o1), drop);
    v8 r3 = v_descale(v_add(t13, o0), drop);
    v8 r4 = v_descale(v_sub(t13, o0), drop);

    d[0] = r0; d[1] = r1; d[2] = r2; d[3] = r3;
    d[4] = r4; d[5] = r5; d[6] = r6; d[7] = r7;
}

void jpeg_accel_idct8_neon(const int32_t *JPEG_NONNULL coefficients,
                           int32_t precision, uint16_t *JPEG_NONNULL samples) {
    v8 d[8];
    for (int i = 0; i < 8; i++) {
        d[i].lo = vld1q_s32(coefficients + i * 8);
        d[i].hi = vld1q_s32(coefficients + i * 8 + 4);
    }

    idct_pass(d, CONST_BITS - PASS_BITS);
    transpose8(d);
    idct_pass(d, CONST_BITS + PASS_BITS + 3);
    transpose8(d);

    const int32x4_t shift = vdupq_n_s32(1 << (precision - 1));
    const int32x4_t ceiling = vdupq_n_s32((1 << precision) - 1);

    for (int i = 0; i < 8; i++) {
        int32x4_t lo = vminq_s32(vaddq_s32(d[i].lo, shift), ceiling);
        int32x4_t hi = vminq_s32(vaddq_s32(d[i].hi, shift), ceiling);
        /* The narrowing saturates at zero on its own, so the lower clamp is
         * the store rather than an instruction of its own. */
        vst1q_u16(samples + i * 8,
                  vcombine_u16(vqmovun_s32(lo), vqmovun_s32(hi)));
    }
}

/* One 8-point forward transform across the eight rows. */
static inline void fdct_pass(v8 *d, int drop, int evenShift) {
    v8 s0 = v_add(d[0], d[7]);
    v8 a7 = v_sub(d[0], d[7]);
    v8 s1 = v_add(d[1], d[6]);
    v8 a6 = v_sub(d[1], d[6]);
    v8 s2 = v_add(d[2], d[5]);
    v8 a5 = v_sub(d[2], d[5]);
    v8 s3 = v_add(d[3], d[4]);
    v8 a4 = v_sub(d[3], d[4]);

    v8 t10 = v_add(s0, s3);
    v8 t13 = v_sub(s0, s3);
    v8 t11 = v_add(s1, s2);
    v8 t12 = v_sub(s1, s2);

    v8 r0, r4;
    if (evenShift > 0) {
        r0 = v_shl(v_add(t10, t11), evenShift);
        r4 = v_shl(v_sub(t10, t11), evenShift);
    } else {
        r0 = v_descale(v_add(t10, t11), -evenShift);
        r4 = v_descale(v_sub(t10, t11), -evenShift);
    }

    v8 z1 = v_mul(v_add(t12, t13), FIX_0_541196100);
    v8 r2 = v_descale(v_add(z1, v_mul(t13, FIX_0_765366865)), drop);
    v8 r6 = v_descale(v_sub(z1, v_mul(t12, FIX_1_847759065)), drop);

    v8 y1 = v_add(a4, a7);
    v8 y2 = v_add(a5, a6);
    v8 y3 = v_add(a4, a6);
    v8 y4 = v_add(a5, a7);
    v8 y5 = v_mul(v_add(y3, y4), FIX_1_175875602);

    v8 o4 = v_mul(a4, FIX_0_298631336);
    v8 o5 = v_mul(a5, FIX_2_053119869);
    v8 o6 = v_mul(a6, FIX_3_072711026);
    v8 o7 = v_mul(a7, FIX_1_501321110);

    y1 = v_mul(y1, -FIX_0_899976223);
    y2 = v_mul(y2, -FIX_2_562915447);
    y3 = v_add(v_mul(y3, -FIX_1_961570560), y5);
    y4 = v_add(v_mul(y4, -FIX_0_390180644), y5);

    v8 r7 = v_descale(v_add(o4, v_add(y1, y3)), drop);
    v8 r5 = v_descale(v_add(o5, v_add(y2, y4)), drop);
    v8 r3 = v_descale(v_add(o6, v_add(y2, y3)), drop);
    v8 r1 = v_descale(v_add(o7, v_add(y1, y4)), drop);

    d[0] = r0; d[1] = r1; d[2] = r2; d[3] = r3;
    d[4] = r4; d[5] = r5; d[6] = r6; d[7] = r7;
}

void jpeg_accel_fdct8_neon(const uint16_t *JPEG_NONNULL samples,
                           int32_t precision, int32_t *JPEG_NONNULL coefficients) {
    const int32x4_t level = vdupq_n_s32(1 << (precision - 1));

    v8 d[8];
    for (int i = 0; i < 8; i++) {
        uint16x8_t raw = vld1q_u16(samples + i * 8);
        d[i].lo = vsubq_s32(
            vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(raw))), level);
        d[i].hi = vsubq_s32(
            vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(raw))), level);
    }

    /* The portable kernel runs the row pass first and the order affects the
     * rounding, so this transposes up front rather than reordering the passes. */
    transpose8(d);
    fdct_pass(d, CONST_BITS - PASS_BITS, PASS_BITS);
    transpose8(d);
    fdct_pass(d, CONST_BITS + PASS_BITS + SCALE_BITS, -(PASS_BITS + SCALE_BITS));

    for (int i = 0; i < 8; i++) {
        vst1q_s32(coefficients + i * 8, d[i].lo);
        vst1q_s32(coefficients + i * 8 + 4, d[i].hi);
    }
}

#else

void jpeg_accel_idct8_neon(const int32_t *JPEG_NONNULL coefficients,
                           int32_t precision, uint16_t *JPEG_NONNULL samples) {
    (void)coefficients; (void)precision; (void)samples;
}

void jpeg_accel_fdct8_neon(const uint16_t *JPEG_NONNULL samples,
                           int32_t precision, int32_t *JPEG_NONNULL coefficients) {
    (void)samples; (void)precision; (void)coefficients;
}

#endif
