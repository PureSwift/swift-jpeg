extension JPEG {
    /// The forward discrete cosine transform.
    ///
    /// The transpose of ``IDCT``, and it shares that type's basis table: the
    /// same coefficients appear in both directions, applied along the other
    /// index. Keeping one table means the two transforms cannot drift apart,
    /// which matters because a mismatch shows up only as a slow accumulation of
    /// error across an encode-decode round trip rather than as an obvious
    /// failure.
    public enum FDCT {
    }
}

extension JPEG.FDCT {
    /// Transforms one block of samples into coefficients.
    ///
    /// Applies the level shift of T.81 §A.3.1 first: samples are recentered on
    /// zero by subtracting the midpoint of their range, which is what makes the
    /// DC coefficient a signed deviation rather than a large positive bias.
    ///
    /// -   Parameters:
    ///     -   samples: 64 samples, row-major.
    ///     -   precision: The sample precision, in bits.
    ///
    /// -   Returns:
    ///     64 unquantized coefficients, row-major.
    public static func transform(_ samples: [UInt16], precision: Int) -> [Int32] {
        precondition(samples.count == 64)

        let shift: Int32 = 1 << Int32(precision - 1)

        var rows: [Int32] = .init(repeating: 0, count: 64)
        for y: Int in 0 ..< 8 {
            for u: Int in 0 ..< 8 {
                var sum: Int64 = 0
                for x: Int in 0 ..< 8 {
                    let sample: Int32 = .init(samples[y << 3 | x]) - shift
                    sum += .init(JPEG.IDCT.basis[u][x]) * .init(sample)
                }
                // The same descale split the inverse uses: 8 of the 13
                // fractional bits here, the rest after the second pass.
                rows[y << 3 | u] = .init(truncatingIfNeeded: (sum + 128) >> 8)
            }
        }

        var coefficients: [Int32] = .init(repeating: 0, count: 64)
        for u: Int in 0 ..< 8 {
            for v: Int in 0 ..< 8 {
                var sum: Int64 = 0
                for y: Int in 0 ..< 8 {
                    sum += .init(JPEG.IDCT.basis[v][y]) * .init(rows[y << 3 | u])
                }
                // 13 fractional bits from this pass, 5 carried over, and 2 more
                // for the factor of 1/4 the separable form leaves behind.
                coefficients[v << 3 | u] = .init(truncatingIfNeeded: (sum + (1 << 19)) >> 20)
            }
        }

        return coefficients
    }

    /// Quantizes a block of coefficients.
    ///
    /// Rounds to nearest, away from zero on a tie, which is what libjpeg does.
    /// Rounding toward zero instead would bias every coefficient slightly
    /// downward and visibly wash out the image at low quality.
    ///
    /// -   Parameters:
    ///     -   coefficients: 64 unquantized coefficients, row-major.
    ///     -   table: The quantization table, also row-major.
    public static func quantize(
        _ coefficients: [Int32],
        by table: JPEG.Table.Quantization
    ) -> [Int16] {
        (0 ..< 64).map {
            let factor: Int32 = .init(table[z: $0])
            let coefficient: Int32 = coefficients[$0]
            let magnitude: Int32 = (abs(coefficient) + factor / 2) / factor
            return .init(truncatingIfNeeded: coefficient < 0 ? -magnitude : magnitude)
        }
    }
}
