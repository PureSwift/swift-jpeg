import CCPUFeatures
import CJPEGAccel
import JPEG

extension JPEG {
    /// Accelerated kernels for the processor this is running on.
    ///
    /// The engine ships portable implementations of everything and works
    /// without this target. Installing replaces the ones the running processor
    /// has a faster path for, and leaves the rest alone.
    ///
    /// This is separate from the engine because it imports things — the engine
    /// imports nothing, which is what keeps it buildable for Embedded Swift and
    /// reusable behind a C ABI. A caller who wants the speed pays for the
    /// import; a caller who wants the discipline does not have to.
    public enum Accelerate {
        /// The instruction set extensions the running processor supports.
        public static var features: [String] {
            let mask: UInt32 = jpeg_cpu_features()
            var found: [String] = []
            if mask & JPEG_CPU_SSE2.rawValue != 0 { found.append("sse2") }
            if mask & JPEG_CPU_SSSE3.rawValue != 0 { found.append("ssse3") }
            if mask & JPEG_CPU_SSE41.rawValue != 0 { found.append("sse4.1") }
            if mask & JPEG_CPU_AVX2.rawValue != 0 { found.append("avx2") }
            if mask & JPEG_CPU_NEON.rawValue != 0 { found.append("neon") }
            return found
        }

        /// Installs the fastest kernels this processor can execute.
        ///
        /// Idempotent, and safe to call when nothing is available — it simply
        /// leaves the portable kernels in place. Call it once at startup:
        /// replacing a kernel while a decode is in flight is a data race like
        /// any other, which is why this is explicit rather than something that
        /// happens lazily on first use.
        ///
        /// -   Returns:
        ///     What was installed, for a caller that wants to report it.
        @discardableResult
        public static func install() -> String {
            if jpeg_accel_avx2_available() != 0 {
                JPEG.Kernel.inverseTransform = jpeg_accel_idct8_avx2
                JPEG.Kernel.forwardTransform = jpeg_accel_fdct8_avx2
                JPEG.Kernel.colorTransform = jpeg_accel_ycc_to_rgb_avx2
                JPEG.Kernel.forwardColorTransform = jpeg_accel_rgb_to_ycc_avx2
                JPEG.Kernel.description = "avx2"
            } else if jpeg_accel_neon_available() != 0 {
                JPEG.Kernel.inverseTransform = jpeg_accel_idct8_neon
                JPEG.Kernel.forwardTransform = jpeg_accel_fdct8_neon
                JPEG.Kernel.colorTransform = jpeg_accel_ycc_to_rgb_neon
                JPEG.Kernel.forwardColorTransform = jpeg_accel_rgb_to_ycc_neon
                JPEG.Kernel.description = "neon"
            } else {
                JPEG.Kernel.reset()
            }
            return JPEG.Kernel.description
        }
    }
}
