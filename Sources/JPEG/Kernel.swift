extension JPEG {
    /// The replaceable implementations of the routines that dominate the
    /// profile.
    ///
    /// A shared library is built once and runs on whatever the user has. Built
    /// for the baseline instruction set it leaves most of a modern register
    /// file idle; built for AVX2 it crashes on anything older. The way out is
    /// to detect the processor at run time and call into whichever kernel it
    /// can execute — which is what libjpeg-turbo does, and what this seam
    /// exists for.
    ///
    /// The engine cannot do the detecting. It imports nothing, and there is no
    /// way to issue `cpuid` from Swift without either inline assembly, which
    /// Swift does not have, or a C shim, which would be an import. So the
    /// engine holds function pointers that default to its own portable code,
    /// and a separate target that *is* allowed to import things replaces them.
    /// Nothing here depends on that ever happening: with no accelerator
    /// installed the defaults are the implementations that were always used.
    ///
    /// These are `@convention(c)` so that an implementation can be written in
    /// something other than Swift.
    public enum Kernel {
        /// Transforms 64 dequantized coefficients into 64 samples.
        ///
        /// -   Parameters:
        ///     -   coefficients: 64 dequantized coefficients, row-major.
        ///     -   precision: The sample precision, in bits.
        ///     -   samples: Where to write 64 samples, row-major.
        public typealias InverseTransform = @convention(c) (
            _ coefficients: UnsafePointer<Int32>,
            _ precision: Int32,
            _ samples: UnsafeMutablePointer<UInt16>
        ) -> Void

        /// Transforms 64 samples into 64 coefficients.
        public typealias ForwardTransform = @convention(c) (
            _ samples: UnsafePointer<UInt16>,
            _ precision: Int32,
            _ coefficients: UnsafeMutablePointer<Int32>
        ) -> Void

        /// Converts interleaved YCbCr samples to packed 8-bit RGB.
        ///
        /// The whole image in one call rather than a pixel or a row at a time.
        /// A per-pixel seam would spend more on the indirect call than on the
        /// nine multiplies it dispatches to, and a vector kernel needs a run of
        /// pixels to be worth entering at all.
        ///
        /// -   Parameters:
        ///     -   interleaved: `3 * count` samples: y, cb, cr per pixel.
        ///     -   count: The number of pixels.
        ///     -   shift: How far to shift a sample right to narrow it to eight
        ///         bits. Negative shifts left. Samples are truncated to eight
        ///         bits after shifting, not clamped.
        ///     -   rgb: Where to write `3 * count` bytes: r, g, b per pixel.
        public typealias ColorTransform = @convention(c) (
            _ interleaved: UnsafePointer<UInt16>,
            _ count: Int,
            _ shift: Int32,
            _ rgb: UnsafeMutablePointer<UInt8>
        ) -> Void

        /// The inverse transform in use.
        ///
        /// Assign before decoding. Replacing it while a decode is in flight is
        /// a data race like any other; this is a process-wide setting to be
        /// configured once at startup, which is why installation is a separate,
        /// explicit step rather than something that happens lazily on first
        /// use.
        public nonisolated(unsafe)
        static var inverseTransform: InverseTransform = Self.portableInverse

        /// The forward transform in use.
        public nonisolated(unsafe)
        static var forwardTransform: ForwardTransform = Self.portableForward

        /// The color transform in use.
        public nonisolated(unsafe)
        static var colorTransform: ColorTransform = Self.portableColor

        /// A description of the installed kernels, for diagnostics.
        ///
        /// There is no way to tell from a decoded image which kernel produced
        /// it — that is the whole point, they agree — so a program that wants
        /// to report what it is running needs to be told.
        public nonisolated(unsafe)
        static var description: String = "portable"
    }
}

extension JPEG.Kernel {
    /// The portable inverse transform: the factored one written in Swift.
    private static let portableInverse: InverseTransform = { coefficients, precision, samples in
        JPEG.IDCT.transform8(
            .init(start: coefficients, count: 64),
            precision: .init(precision),
            into: .init(start: samples, count: 64)
        )
    }

    /// The portable forward transform.
    private static let portableForward: ForwardTransform = { samples, precision, coefficients in
        JPEG.FDCT.transform8(
            .init(start: samples, count: 64),
            precision: .init(precision),
            into: .init(start: coefficients, count: 64)
        )
    }

    /// The portable color transform.
    ///
    /// Kept here rather than in `Format.swift` so that this file holds the
    /// definition every accelerated kernel has to agree with, and so that the
    /// arithmetic a vector kernel reimplements can be read against it in one
    /// place.
    private static let portableColor: ColorTransform = { interleaved, count, shift, rgb in
        let scale: Int = .init(shift)
        for i: Int in 0 ..< count {
            let base: Int = 3 * i
            let color: JPEG.YCbCr = .init(
                y: JPEG.YCbCr.narrow(interleaved[base], by: scale),
                cb: JPEG.YCbCr.narrow(interleaved[base + 1], by: scale),
                cr: JPEG.YCbCr.narrow(interleaved[base + 2], by: scale)
            )
            let pixel: JPEG.RGB = color.rgb
            rgb[base] = pixel.r
            rgb[base + 1] = pixel.g
            rgb[base + 2] = pixel.b
        }
    }

    /// Restores the portable kernels.
    ///
    /// Mainly for tests, which need to check an accelerated kernel against the
    /// one it replaced and so must be able to get back to it.
    public static func reset() {
        Self.inverseTransform = Self.portableInverse
        Self.forwardTransform = Self.portableForward
        Self.colorTransform = Self.portableColor
        Self.description = "portable"
    }
}
