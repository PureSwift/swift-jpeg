extension JPEG {
    /// The inverse discrete cosine transform.
    ///
    /// Separable: an 8×8 inverse DCT is eight one-dimensional transforms along
    /// the rows followed by eight along the columns, which is why one basis
    /// table serves both passes.
    public enum IDCT {
        /// The one-dimensional basis, in Q13 fixed point.
        ///
        /// Entry `[u][x]` is `k(u) · cos((2x + 1)·u·π / 16) · 2^13` rounded to
        /// the nearest integer, where `k(0)` is `1/√2` and `k(u)` is 1
        /// otherwise — the normalization T.81 §A.3.3 folds into the transform.
        ///
        /// Transcribed rather than computed, because computing it would require
        /// `cos` and this module imports nothing. It is reproducible from the
        /// one-line definition above; the generator is recorded in the commit
        /// that introduced this file.
        static let basis: [[Int32]] = [
            [  5793,   5793,   5793,   5793,   5793,   5793,   5793,   5793],
            [  8035,   6811,   4551,   1598,  -1598,  -4551,  -6811,  -8035],
            [  7568,   3135,  -3135,  -7568,  -7568,  -3135,   3135,   7568],
            [  6811,  -1598,  -8035,  -4551,   4551,   8035,   1598,  -6811],
            [  5793,  -5793,  -5793,   5793,   5793,  -5793,  -5793,   5793],
            [  4551,  -8035,   1598,   6811,  -6811,  -1598,   8035,  -4551],
            [  3135,  -7568,   7568,  -3135,  -3135,   7568,  -7568,   3135],
            [  1598,  -4551,   6811,  -8035,   8035,  -6811,   4551,  -1598],
        ]
    }
}

extension JPEG.IDCT {
    /// Transforms one block of dequantized coefficients into samples.
    ///
    /// Applies the two passes, then the level shift of T.81 §A.3.1: JPEG codes
    /// samples centered on zero, so the midpoint of the sample range is added
    /// back and the result is clamped into it. Clamping is not optional — a
    /// lossily quantized block routinely reconstructs a few counts outside the
    /// representable range.
    ///
    /// -   Parameters:
    ///     -   coefficients: 64 dequantized coefficients, row-major.
    ///     -   precision: The sample precision, in bits.
    ///
    /// -   Returns:
    ///     64 samples, row-major.
    public static func transform(_ coefficients: [Int32], precision: Int) -> [UInt16] {
        precondition(coefficients.count == 64)

        // Accumulate in 64 bits. A dequantized coefficient is a 16-bit level
        // times a 16-bit quantization factor, so the products here overflow 32
        // bits well before the transform is finished.
        var rows: [Int32] = .init(repeating: 0, count: 64)
        for y: Int in 0 ..< 8 {
            for x: Int in 0 ..< 8 {
                var sum: Int64 = 0
                for u: Int in 0 ..< 8 {
                    sum += .init(Self.basis[u][x]) * .init(coefficients[y << 3 | u])
                }
                // Shed 8 of the 13 fractional bits between passes to keep the
                // second pass's products small; the remaining 5 are enough
                // guard bits to stay within a count of the exact result.
                rows[y << 3 | x] = .init(truncatingIfNeeded: (sum + 128) >> 8)
            }
        }

        let shift: Int32 = 1 << Int32(precision - 1)
        let ceiling: Int32 = (1 << Int32(precision)) - 1

        var samples: [UInt16] = .init(repeating: 0, count: 64)
        for x: Int in 0 ..< 8 {
            for y: Int in 0 ..< 8 {
                var sum: Int64 = 0
                for v: Int in 0 ..< 8 {
                    sum += .init(Self.basis[v][y]) * .init(rows[v << 3 | x])
                }
                // 13 fractional bits from this pass, the 5 carried over from
                // the first, and 2 more for the factor of 1/4 the separable
                // form leaves behind.
                let value: Int32 = .init(truncatingIfNeeded: (sum + (1 << 19)) >> 20) + shift

                samples[y << 3 | x] = .init(Swift.min(Swift.max(value, 0), ceiling))
            }
        }

        return samples
    }

    /// Dequantizes a block of coefficient levels.
    ///
    /// -   Parameters:
    ///     -   levels: 64 quantized levels, row-major.
    ///     -   table: The quantization table, also row-major.
    public static func dequantize(
        _ levels: [Int16],
        by table: JPEG.Table.Quantization
    ) -> [Int32] {
        (0 ..< 64).map {
            .init(levels[$0]) * .init(table[z: $0])
        }
    }
}
