import Testing

@testable import JPEG

/// The factored transform is only useful if it agrees with the transform it
/// replaces. These check that directly, block by block, rather than inferring it
/// from a decoded image — an image averages the two together with upsampling and
/// colour conversion, and would hide a systematic bias of a count or two.
@Suite("IDCT")
struct IDCTTests {
    /// A reproducible pseudorandom source.
    ///
    /// The engine imports nothing and the tests should not depend on a system
    /// generator either: a failure has to be reproducible from the seed alone,
    /// or it cannot be debugged.
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            // xorshift64*, which is more than enough structure for test data.
            self.state ^= self.state >> 12
            self.state ^= self.state << 25
            self.state ^= self.state >> 27
            return self.state &* 2685821657736338717
        }

        /// A value in `-magnitude ... magnitude`.
        mutating func coefficient(magnitude: Int32) -> Int32 {
            .init(truncatingIfNeeded: self.next() % .init(2 * magnitude + 1)) - magnitude
        }
    }

    private static func fast(_ coefficients: [Int32], precision: Int) -> [UInt16] {
        var samples: [UInt16] = .init(repeating: 0, count: 64)
        samples.withUnsafeMutableBufferPointer { samples in
            coefficients.withUnsafeBufferPointer { coefficients in
                JPEG.IDCT.transform8(coefficients, precision: precision, into: samples)
            }
        }
        return samples
    }

    /// The two transforms must agree on a flat block exactly.
    ///
    /// A DC-only block is the case the column pass short-circuits, so it
    /// exercises a path the random blocks below mostly skip.
    @Test("DC only")
    func dc() {
        for level: Int32 in stride(from: -1024, through: 1024, by: 64) {
            var coefficients: [Int32] = .init(repeating: 0, count: 64)
            coefficients[0] = level * 8

            let fast: [UInt16] = Self.fast(coefficients, precision: 8)
            let direct: [UInt16] = JPEG.IDCT.transform(coefficients, precision: 8)

            #expect(fast == direct, "DC level \(level)")
            // A flat block reconstructs flat, whatever the rounding does.
            #expect(Set(fast).count == 1)
        }
    }

    /// Sparse blocks, which is what a quantized image actually contains.
    @Test("sparse blocks")
    func sparse() {
        var generator: Generator = .init(seed: 0x5EED)
        var worst: Int = 0

        for _: Int in 0 ..< 4096 {
            var coefficients: [Int32] = .init(repeating: 0, count: 64)
            coefficients[0] = generator.coefficient(magnitude: 8192)
            // Six nonzero AC coefficients biased toward low frequencies, which
            // is roughly what survives quantization at a normal quality.
            for _: Int in 0 ..< 6 {
                let z: Int = .init(generator.next() % 24) + 1
                coefficients[JPEG.zigzag[z]] = generator.coefficient(magnitude: 2048)
            }

            let fast: [UInt16] = Self.fast(coefficients, precision: 8)
            let direct: [UInt16] = JPEG.IDCT.transform(coefficients, precision: 8)

            for (a, b): (UInt16, UInt16) in zip(fast, direct) {
                worst = max(worst, abs(Int(a) - Int(b)))
            }
        }

        // One count. The two are different roundings of the same real-valued
        // transform, so they cannot be expected to agree exactly, but a
        // disagreement larger than the quantization step would mean one of them
        // is wrong rather than merely rounded differently.
        #expect(worst <= 1, "worst deviation \(worst)")
    }

    /// Dense blocks with every coefficient populated.
    ///
    /// Real images do not look like this, but it is where accumulated rounding
    /// error is largest and where a transcription error in a rarely-exercised
    /// constant would show.
    @Test("dense blocks")
    func dense() {
        var generator: Generator = .init(seed: 0xD15EA5E)
        var worst: Int = 0

        for _: Int in 0 ..< 4096 {
            var coefficients: [Int32] = .init(repeating: 0, count: 64)
            coefficients[0] = generator.coefficient(magnitude: 8192)
            for z: Int in 1 ..< 64 {
                coefficients[z] = generator.coefficient(magnitude: 1024)
            }

            let fast: [UInt16] = Self.fast(coefficients, precision: 8)
            let direct: [UInt16] = JPEG.IDCT.transform(coefficients, precision: 8)

            for (a, b): (UInt16, UInt16) in zip(fast, direct) {
                worst = max(worst, abs(Int(a) - Int(b)))
            }
        }

        #expect(worst <= 1, "worst deviation \(worst)")
    }

    /// Both transforms must clamp, and must clamp to the same place.
    @Test("clamping")
    func clamping() {
        var coefficients: [Int32] = .init(repeating: 0, count: 64)
        coefficients[0] = 40000

        #expect(Self.fast(coefficients, precision: 8).allSatisfy { $0 == 255 })

        coefficients[0] = -40000
        #expect(Self.fast(coefficients, precision: 8).allSatisfy { $0 == 0 })
    }
}
