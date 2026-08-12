import Testing

@testable import JPEG

/// The forward factorization has to agree with the direct forward transform,
/// and — more importantly — has to be the actual inverse of the inverse
/// transform. Two transforms that agree with each other but not with each
/// other's inverse would still round trip an image into mush.
@Suite("FDCT")
struct FDCTTests {
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            self.state ^= self.state >> 12
            self.state ^= self.state << 25
            self.state ^= self.state >> 27
            return self.state &* 2685821657736338717
        }
    }

    private static func fast(_ samples: [UInt16], precision: Int) -> [Int32] {
        var coefficients: [Int32] = .init(repeating: 0, count: 64)
        coefficients.withUnsafeMutableBufferPointer { coefficients in
            samples.withUnsafeBufferPointer { samples in
                JPEG.FDCT.transform8(
                    samples, precision: precision, into: coefficients
                )
            }
        }
        return coefficients
    }

    /// A flat block has no AC content, whatever the transform does with it.
    @Test("flat blocks")
    func flat() {
        for level: UInt16 in stride(from: 0, through: 255, by: 15) {
            let samples: [UInt16] = .init(repeating: level, count: 64)
            let fast: [Int32] = Self.fast(samples, precision: 8)
            let direct: [Int32] = JPEG.FDCT.transform(samples, precision: 8)

            #expect(fast[0] == direct[0], "level \(level)")
            #expect(fast[1...].allSatisfy { $0 == 0 }, "level \(level)")
        }
    }

    /// The two forward transforms must agree to within a count.
    @Test("agrees with the direct transform")
    func agreement() {
        var generator: Generator = .init(seed: 0xF00D)
        var worst: Int = 0

        for _: Int in 0 ..< 4096 {
            let samples: [UInt16] = (0 ..< 64).map { _ in
                .init(truncatingIfNeeded: generator.next() % 256)
            }

            let fast: [Int32] = Self.fast(samples, precision: 8)
            let direct: [Int32] = JPEG.FDCT.transform(samples, precision: 8)

            for (a, b): (Int32, Int32) in zip(fast, direct) {
                worst = max(worst, abs(Int(a) - Int(b)))
            }
        }

        #expect(worst <= 1, "worst deviation \(worst)")
    }

    /// Forward then inverse must return the samples it started from.
    ///
    /// This is the property that matters. Agreement with the direct transform
    /// says the arithmetic was transcribed correctly; this says the two halves
    /// of the codec are transposes of each other, which is what stops an
    /// encode-decode round trip from drifting.
    @Test("round trips through the inverse")
    func roundTrip() {
        var generator: Generator = .init(seed: 0xBEEF)
        var worst: Int = 0

        for _: Int in 0 ..< 2048 {
            // Smooth blocks rather than uniform noise: the transform is exact
            // in the limit only for content the 8x8 basis can represent, and
            // full-band noise reconstructs a count or two off no matter which
            // implementation runs.
            let dc: Int = .init(generator.next() % 200) + 28
            let slope: Int = .init(generator.next() % 16) - 8
            let samples: [UInt16] = (0 ..< 64).map { i in
                let value: Int = dc + slope * (i & 7) + slope * (i >> 3) / 2
                return .init(Swift.min(Swift.max(value, 0), 255))
            }

            let coefficients: [Int32] = Self.fast(samples, precision: 8)
            let back: [UInt16] = JPEG.IDCT.transform(coefficients, precision: 8)

            for (a, b): (UInt16, UInt16) in zip(samples, back) {
                worst = max(worst, abs(Int(a) - Int(b)))
            }
        }

        // Two counts: one from each transform's rounding.
        #expect(worst <= 2, "worst round trip deviation \(worst)")
    }

    /// The reciprocal quantizer has to agree with the dividing one exactly, not
    /// nearly. A multiply-high is a substitute for a division only inside a
    /// bound, and one count of disagreement in a coefficient is a visible
    /// artifact that no round-trip tolerance would catch.
    @Test("reciprocal quantization matches division", arguments: [8, 12])
    func reciprocal(precision: Int) throws {
        var generator: Generator = .init(seed: 0x9E3779B97F4A7C15)

        // Every quality, so the sweep covers factors from 1 — which makes the
        // multiplier overflow 32 bits — up to the 255 a baseline table clamps to,
        // and the four-figure factors an extended one carries at quality 1.
        for quality: Int in 1 ... 100 {
            for standard: JPEG.Table.Quantization.Standard in [.luminance, .chrominance] {
                for baseline: Bool in [true, false] {
                    let table: JPEG.Table.Quantization = .standard(
                        standard, quality: quality, target: 0, baseline: baseline
                    )
                    let reciprocal: JPEG.Table.Quantization.Reciprocal =
                        try #require(table.reciprocal(precision: precision))

                    // The extremes of the range T.81 gives the forward transform,
                    // where a reciprocal fails first if it fails, plus noise
                    // across the interior.
                    let bound: Int32 = 1 << (precision + 2)
                    var blocks: [[Int32]] = [
                        .init(repeating: bound, count: 64),
                        .init(repeating: -bound, count: 64),
                        .init(repeating: 0, count: 64),
                    ]
                    let span: UInt64 = .init(2 * bound + 1)
                    for _: Int in 0 ..< 4 {
                        blocks.append((0 ..< 64).map { _ in
                            .init(truncatingIfNeeded: generator.next() % span) - bound
                        })
                    }

                    for block: [Int32] in blocks {
                        var divided: [Int16] = .init(repeating: 0, count: 64)
                        var multiplied: [Int16] = .init(repeating: 0, count: 64)
                        block.withUnsafeBufferPointer { coefficients in
                            divided.withUnsafeMutableBufferPointer {
                                JPEG.FDCT.quantize(coefficients, by: table, into: $0)
                            }
                            multiplied.withUnsafeMutableBufferPointer {
                                JPEG.FDCT.quantize(coefficients, by: reciprocal, into: $0)
                            }
                        }
                        #expect(
                            divided == multiplied,
                            """
                            quality \(quality) baseline \(baseline) \
                            precision \(precision)
                            """
                        )
                    }
                }
            }
        }
    }
}
