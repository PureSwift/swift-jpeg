extension JPEG.FDCT {
    /// Multipliers for the factored 8-point transform, in Q13 fixed point.
    ///
    /// The same constants the inverse uses, for the same reason: the forward
    /// and inverse factorizations are transposes of each other and share their
    /// rotations.
    private enum Constant {
        static let c0_298631336: Int64 = 2446
        static let c0_390180644: Int64 = 3196
        static let c0_541196100: Int64 = 4433
        static let c0_765366865: Int64 = 6270
        static let c0_899976223: Int64 = 7373
        static let c1_175875602: Int64 = 9633
        static let c1_501321110: Int64 = 12299
        static let c1_847759065: Int64 = 15137
        static let c1_961570560: Int64 = 16069
        static let c2_053119869: Int64 = 16819
        static let c2_562915447: Int64 = 20995
        static let c3_072711026: Int64 = 25172
    }

    /// Fractional bits carried by ``Constant``.
    private static let constantBits: Int64 = 13
    /// Fractional bits the first pass leaves in the intermediate.
    private static let passBits: Int64 = 2
    /// The factored form computes the transform eight times larger than T.81
    /// defines it.
    ///
    /// libjpeg leaves it that way and folds the factor into its quantization
    /// divisors. This library quantizes with the table as written, so the eight
    /// is shed here instead and ``transform8(_:precision:into:)`` produces the
    /// coefficients the standard describes.
    private static let scaleBits: Int64 = 3

    /// Rounds a fixed-point value down by `bits` places, to nearest.
    private static func descale(_ x: Int64, _ bits: Int64) -> Int64 {
        (x + (1 << (bits - 1))) >> bits
    }

    /// Transforms one block of samples into coefficients, factored.
    ///
    /// The counterpart of ``JPEG/IDCT/transform8(_:precision:into:)``, and the
    /// same trade: 11 multiplies per 8-point transform where writing the
    /// definition out costs 64.
    ///
    /// -   Parameters:
    ///     -   samples: 64 samples, row-major.
    ///     -   precision: The sample precision, in bits.
    ///     -   coefficients: Where to write 64 coefficients, row-major.
    static func transform8(
        _ samples: UnsafeBufferPointer<UInt16>,
        precision: Int,
        into coefficients: UnsafeMutableBufferPointer<Int32>
    ) {
        // T.81 §A.3.1: recenter the samples on zero before transforming, so the
        // DC coefficient is a signed deviation rather than a large bias.
        let level: Int64 = .init(1 << (precision - 1))

        withUnsafeTemporaryAllocation(of: Int64.self, capacity: 64) { work in
            // Pass one, along the rows.
            let drop1: Int64 = Self.constantBits - Self.passBits
            for row: Int in 0 ..< 8 {
                let base: Int = row << 3
                let d0: Int64 = .init(samples[base]) - level
                let d1: Int64 = .init(samples[base | 1]) - level
                let d2: Int64 = .init(samples[base | 2]) - level
                let d3: Int64 = .init(samples[base | 3]) - level
                let d4: Int64 = .init(samples[base | 4]) - level
                let d5: Int64 = .init(samples[base | 5]) - level
                let d6: Int64 = .init(samples[base | 6]) - level
                let d7: Int64 = .init(samples[base | 7]) - level

                // The butterfly: the transform of a sequence splits into the
                // transform of its symmetric part, which gives the even
                // frequencies, and its antisymmetric part, which gives the odd.
                let s0: Int64 = d0 + d7
                let a7: Int64 = d0 - d7
                let s1: Int64 = d1 + d6
                let a6: Int64 = d1 - d6
                let s2: Int64 = d2 + d5
                let a5: Int64 = d2 - d5
                let s3: Int64 = d3 + d4
                let a4: Int64 = d3 - d4

                // Even part.
                let t10: Int64 = s0 + s3
                let t13: Int64 = s0 - s3
                let t11: Int64 = s1 + s2
                let t12: Int64 = s1 - s2

                work[base] = (t10 + t11) << Self.passBits
                work[base | 4] = (t10 - t11) << Self.passBits

                let z1: Int64 = (t12 + t13) * Constant.c0_541196100
                work[base | 2] = Self.descale(
                    z1 + t13 * Constant.c0_765366865, drop1
                )
                work[base | 6] = Self.descale(
                    z1 - t12 * Constant.c1_847759065, drop1
                )

                // Odd part.
                var o4: Int64 = a4
                var o5: Int64 = a5
                var o6: Int64 = a6
                var o7: Int64 = a7

                var y1: Int64 = o4 + o7
                var y2: Int64 = o5 + o6
                var y3: Int64 = o4 + o6
                var y4: Int64 = o5 + o7
                let y5: Int64 = (y3 + y4) * Constant.c1_175875602

                o4 *= Constant.c0_298631336
                o5 *= Constant.c2_053119869
                o6 *= Constant.c3_072711026
                o7 *= Constant.c1_501321110
                y1 *= -Constant.c0_899976223
                y2 *= -Constant.c2_562915447
                y3 *= -Constant.c1_961570560
                y4 *= -Constant.c0_390180644

                y3 += y5
                y4 += y5

                work[base | 7] = Self.descale(o4 + y1 + y3, drop1)
                work[base | 5] = Self.descale(o5 + y2 + y4, drop1)
                work[base | 3] = Self.descale(o6 + y2 + y3, drop1)
                work[base | 1] = Self.descale(o7 + y1 + y4, drop1)
            }

            // Pass two, down the columns. Identical but for the descaling,
            // which also sheds the eight the factorization introduced.
            let drop2: Int64 = Self.constantBits + Self.passBits + Self.scaleBits
            for i: Int in 0 ..< 8 {
                let d0: Int64 = work[i]
                let d1: Int64 = work[8 + i]
                let d2: Int64 = work[16 + i]
                let d3: Int64 = work[24 + i]
                let d4: Int64 = work[32 + i]
                let d5: Int64 = work[40 + i]
                let d6: Int64 = work[48 + i]
                let d7: Int64 = work[56 + i]

                let s0: Int64 = d0 + d7
                let a7: Int64 = d0 - d7
                let s1: Int64 = d1 + d6
                let a6: Int64 = d1 - d6
                let s2: Int64 = d2 + d5
                let a5: Int64 = d2 - d5
                let s3: Int64 = d3 + d4
                let a4: Int64 = d3 - d4

                let t10: Int64 = s0 + s3
                let t13: Int64 = s0 - s3
                let t11: Int64 = s1 + s2
                let t12: Int64 = s1 - s2

                coefficients[i] = .init(
                    truncatingIfNeeded: Self.descale(
                        t10 + t11, Self.passBits + Self.scaleBits
                    )
                )
                coefficients[32 + i] = .init(
                    truncatingIfNeeded: Self.descale(
                        t10 - t11, Self.passBits + Self.scaleBits
                    )
                )

                let z1: Int64 = (t12 + t13) * Constant.c0_541196100
                coefficients[16 + i] = .init(
                    truncatingIfNeeded: Self.descale(
                        z1 + t13 * Constant.c0_765366865, drop2
                    )
                )
                coefficients[48 + i] = .init(
                    truncatingIfNeeded: Self.descale(
                        z1 - t12 * Constant.c1_847759065, drop2
                    )
                )

                var o4: Int64 = a4
                var o5: Int64 = a5
                var o6: Int64 = a6
                var o7: Int64 = a7

                var y1: Int64 = o4 + o7
                var y2: Int64 = o5 + o6
                var y3: Int64 = o4 + o6
                var y4: Int64 = o5 + o7
                let y5: Int64 = (y3 + y4) * Constant.c1_175875602

                o4 *= Constant.c0_298631336
                o5 *= Constant.c2_053119869
                o6 *= Constant.c3_072711026
                o7 *= Constant.c1_501321110
                y1 *= -Constant.c0_899976223
                y2 *= -Constant.c2_562915447
                y3 *= -Constant.c1_961570560
                y4 *= -Constant.c0_390180644

                y3 += y5
                y4 += y5

                coefficients[56 + i] = .init(
                    truncatingIfNeeded: Self.descale(o4 + y1 + y3, drop2)
                )
                coefficients[40 + i] = .init(
                    truncatingIfNeeded: Self.descale(o5 + y2 + y4, drop2)
                )
                coefficients[24 + i] = .init(
                    truncatingIfNeeded: Self.descale(o6 + y2 + y3, drop2)
                )
                coefficients[8 + i] = .init(
                    truncatingIfNeeded: Self.descale(o7 + y1 + y4, drop2)
                )
            }
        }
    }

    /// Quantizes a block of coefficients without dividing.
    ///
    /// The same result as ``quantize(_:by:into:)`` — exactly the same, not nearly
    /// — for any table whose reciprocal ``JPEG/Table/Quantization/reciprocal(precision:)``
    /// was willing to build. That function explains the arithmetic and states the
    /// bound; this one just does it.
    ///
    /// This is the one place in the codec where instruction counts are the wrong
    /// measurement, and badly so. A division is a single instruction, so removing
    /// two of them per coefficient is worth only 3.3% of the forward path under
    /// callgrind — 168.7M against 163.1M. In wall clock the same change is worth
    /// 31% of that path, 0.0250 s against 0.0172 s, and 21% of the whole
    /// end-to-end encode, 0.0380 s against 0.0300 s on a megapixel image. The
    /// gap is the divider's latency: about 25 cycles for one instruction, where
    /// the multiply that replaces it takes three.
    static func quantize(
        _ coefficients: UnsafeBufferPointer<Int32>,
        by reciprocal: JPEG.Table.Quantization.Reciprocal,
        into levels: UnsafeMutableBufferPointer<Int16>
    ) {
        let shift: UInt64 = .init(JPEG.Table.Quantization.reciprocalBits)
        reciprocal.withUnsafeEntries { entries in
            for z: Int in 0 ..< 64 {
                let entry: JPEG.Table.Quantization.Reciprocal.Entry = entries[z]
                let coefficient: Int32 = coefficients[z]
                let numerator: UInt64 = .init(coefficient.magnitude + entry.addend)
                // Parenthesized deliberately: `>>` binds tighter than `*` in
                // Swift, so leaving them off shifts the multiplier rather than
                // the product and quantizes every coefficient to zero.
                let magnitude: UInt64 = (numerator * entry.multiplier) >> shift
                levels[z] = .init(
                    truncatingIfNeeded: coefficient < 0
                        ? -Int64(magnitude)
                        : .init(magnitude)
                )
            }
        }
    }

    /// Quantizes a block of coefficients into a buffer the caller owns.
    ///
    /// The array-returning form allocates, and encoding a megapixel image is
    /// twenty-odd thousand blocks.
    ///
    /// Kept as the fallback for a table the reciprocal form will not take, and as
    /// the definition the reciprocal form is checked against.
    static func quantize(
        _ coefficients: UnsafeBufferPointer<Int32>,
        by table: JPEG.Table.Quantization,
        into levels: UnsafeMutableBufferPointer<Int16>
    ) {
        for z: Int in 0 ..< 64 {
            let factor: Int32 = .init(table[z: z])
            let coefficient: Int32 = coefficients[z]
            let magnitude: Int32 = (abs(coefficient) + factor / 2) / factor
            levels[z] = .init(
                truncatingIfNeeded: coefficient < 0 ? -magnitude : magnitude
            )
        }
    }
}
