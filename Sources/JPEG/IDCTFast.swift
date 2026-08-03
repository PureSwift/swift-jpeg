extension JPEG.IDCT {
    /// Multipliers for the factored 8-point transform, in Q13 fixed point.
    ///
    /// Each is the named constant times `2^13`, rounded. The names are the
    /// values themselves because that is how the factorization is published and
    /// how it is checked: `c1_847759065` is `2·cos(π/8)`, and reading the digits
    /// is the only way to confirm a transcription.
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
    ///
    /// The direct transform sheds eight bits between passes; this one keeps two
    /// extra instead, because the factored form's intermediate sums are much
    /// smaller and the accuracy is free.
    private static let passBits: Int64 = 2

    /// Rounds a fixed-point value down by `bits` places, to nearest.
    private static func descale(_ x: Int64, _ bits: Int64) -> Int64 {
        (x + (1 << (bits - 1))) >> bits
    }

    /// Transforms one full-size block using the factored transform.
    ///
    /// The direct form evaluates the transform as written: every output is a
    /// sum over eight basis values, so a block costs 1024 multiplies. This is
    /// the Loeffler-Ligtenberg-Moschytz factorization, which shares
    /// subexpressions between outputs and computes an 8-point transform in 11
    /// multiplies instead of 64 — 176 for the block, a bit over a fifth of the
    /// work, for a result that differs from the direct form by less than a
    /// count.
    ///
    /// This handles `n == 8` only. The scaled sizes keep the direct form: they
    /// have their own factorizations, but they are the rare path and each one
    /// would be a separate algorithm to get wrong.
    ///
    /// -   Parameters:
    ///     -   coefficients: 64 dequantized coefficients, row-major.
    ///     -   precision: The sample precision, in bits.
    ///     -   samples: Where to write 64 samples, row-major.
    static func transform8(
        _ coefficients: UnsafeBufferPointer<Int32>,
        precision: Int,
        into samples: UnsafeMutableBufferPointer<UInt16>
    ) {
        let shift: Int32 = 1 << Int32(precision - 1)
        let ceiling: Int32 = (1 << Int32(precision)) - 1

        withUnsafeTemporaryAllocation(of: Int64.self, capacity: 64) { work in
            // Pass one, down the columns.
            for i: Int in 0 ..< 8 {
                let c0: Int64 = .init(coefficients[i])
                let c1: Int64 = .init(coefficients[8 + i])
                let c2: Int64 = .init(coefficients[16 + i])
                let c3: Int64 = .init(coefficients[24 + i])
                let c4: Int64 = .init(coefficients[32 + i])
                let c5: Int64 = .init(coefficients[40 + i])
                let c6: Int64 = .init(coefficients[48 + i])
                let c7: Int64 = .init(coefficients[56 + i])

                // A column with no AC content reconstructs to its DC value
                // repeated, and most columns of most blocks are exactly that
                // after quantization. Skipping them is worth more on a real
                // image than the factorization itself.
                if c1 | c2 | c3 | c4 | c5 | c6 | c7 == 0 {
                    let dc: Int64 = c0 << Self.passBits
                    for v: Int in 0 ..< 8 {
                        work[v << 3 | i] = dc
                    }
                    continue
                }

                // Even part: the four even-indexed frequencies, which form a
                // 4-point transform with two multiplies.
                let e1: Int64 = (c2 + c6) * Constant.c0_541196100
                let e2: Int64 = e1 - c6 * Constant.c1_847759065
                let e3: Int64 = e1 + c2 * Constant.c0_765366865
                let e0: Int64 = (c0 + c4) << Self.constantBits
                let ex: Int64 = (c0 - c4) << Self.constantBits

                let t10: Int64 = e0 + e3
                let t13: Int64 = e0 - e3
                let t11: Int64 = ex + e2
                let t12: Int64 = ex - e2

                // Odd part. The four inputs are combined pairwise first, and
                // the two rotations they share are evaluated once.
                var o0: Int64 = c7
                var o1: Int64 = c5
                var o2: Int64 = c3
                var o3: Int64 = c1

                var z1: Int64 = o0 + o3
                var z2: Int64 = o1 + o2
                var z3: Int64 = o0 + o2
                var z4: Int64 = o1 + o3
                let z5: Int64 = (z3 + z4) * Constant.c1_175875602

                o0 *= Constant.c0_298631336
                o1 *= Constant.c2_053119869
                o2 *= Constant.c3_072711026
                o3 *= Constant.c1_501321110
                z1 *= -Constant.c0_899976223
                z2 *= -Constant.c2_562915447
                z3 *= -Constant.c1_961570560
                z4 *= -Constant.c0_390180644

                z3 += z5
                z4 += z5

                o0 += z1 + z3
                o1 += z2 + z4
                o2 += z2 + z3
                o3 += z1 + z4

                let drop: Int64 = Self.constantBits - Self.passBits
                work[i] = Self.descale(t10 + o3, drop)
                work[56 + i] = Self.descale(t10 - o3, drop)
                work[8 + i] = Self.descale(t11 + o2, drop)
                work[48 + i] = Self.descale(t11 - o2, drop)
                work[16 + i] = Self.descale(t12 + o1, drop)
                work[40 + i] = Self.descale(t12 - o1, drop)
                work[24 + i] = Self.descale(t13 + o0, drop)
                work[32 + i] = Self.descale(t13 - o0, drop)
            }

            // Pass two, along the rows. Same factorization; the only difference
            // is that the result is a sample rather than an intermediate, so it
            // takes the level shift and the clamp.
            //
            // The all-zero shortcut is not repeated here. After the column pass
            // a row is almost never flat, so the test would cost more than it
            // saves.
            let drop: Int64 = Self.constantBits + Self.passBits + 3

            for row: Int in 0 ..< 8 {
                let base: Int = row << 3
                let c0: Int64 = work[base]
                let c1: Int64 = work[base | 1]
                let c2: Int64 = work[base | 2]
                let c3: Int64 = work[base | 3]
                let c4: Int64 = work[base | 4]
                let c5: Int64 = work[base | 5]
                let c6: Int64 = work[base | 6]
                let c7: Int64 = work[base | 7]

                let e1: Int64 = (c2 + c6) * Constant.c0_541196100
                let e2: Int64 = e1 - c6 * Constant.c1_847759065
                let e3: Int64 = e1 + c2 * Constant.c0_765366865
                let e0: Int64 = (c0 + c4) << Self.constantBits
                let ex: Int64 = (c0 - c4) << Self.constantBits

                let t10: Int64 = e0 + e3
                let t13: Int64 = e0 - e3
                let t11: Int64 = ex + e2
                let t12: Int64 = ex - e2

                var o0: Int64 = c7
                var o1: Int64 = c5
                var o2: Int64 = c3
                var o3: Int64 = c1

                var z1: Int64 = o0 + o3
                var z2: Int64 = o1 + o2
                var z3: Int64 = o0 + o2
                var z4: Int64 = o1 + o3
                let z5: Int64 = (z3 + z4) * Constant.c1_175875602

                o0 *= Constant.c0_298631336
                o1 *= Constant.c2_053119869
                o2 *= Constant.c3_072711026
                o3 *= Constant.c1_501321110
                z1 *= -Constant.c0_899976223
                z2 *= -Constant.c2_562915447
                z3 *= -Constant.c1_961570560
                z4 *= -Constant.c0_390180644

                z3 += z5
                z4 += z5

                o0 += z1 + z3
                o1 += z2 + z4
                o2 += z2 + z3
                o3 += z1 + z4

                func emit(_ x: Int, _ sum: Int64) {
                    let value: Int32 =
                        .init(truncatingIfNeeded: Self.descale(sum, drop)) + shift
                    samples[base | x] = .init(Swift.min(Swift.max(value, 0), ceiling))
                }

                emit(0, t10 + o3)
                emit(7, t10 - o3)
                emit(1, t11 + o2)
                emit(6, t11 - o2)
                emit(2, t12 + o1)
                emit(5, t12 - o1)
                emit(3, t13 + o0)
                emit(4, t13 - o0)
            }
        }
    }
}
