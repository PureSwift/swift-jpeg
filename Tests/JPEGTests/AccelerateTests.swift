import Foundation
import Testing

@testable import JPEG
import JPEGAccelerate

/// An accelerated kernel is only useful if it computes what it replaced.
///
/// These install the accelerated transforms and check them against the portable
/// ones block by block. A decoded image would not do: it averages the transform
/// together with upsampling and colour conversion, and a kernel that was wrong
/// in one lane out of eight — the classic vector bug, an index or a shuffle
/// mask off by one — would still produce a picture that looked fine.
///
/// Serialized because the kernel seam is process-wide state. Tests that run in
/// parallel would install over each other.
@Suite("Accelerate", .serialized)
struct AccelerateTests {
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

    /// Runs `body` with the accelerated kernels installed, then restores the
    /// portable ones however it exits.
    private static func accelerated<T>(_ body: (String) throws -> T) rethrows -> T {
        let installed: String = JPEG.Accelerate.install()
        defer { JPEG.Kernel.reset() }
        return try body(installed)
    }

    /// Detection must agree with the machine, and installation must be honest
    /// about what it did.
    @Test("detects and installs")
    func detection() {
        let features: [String] = JPEG.Accelerate.features
        Self.accelerated { installed in
            // The order has to match the order `install` prefers them in, not
            // just the set of things the processor can do.
            if features.contains("avx2") {
                #expect(installed == "avx2")
            } else if features.contains("neon") {
                #expect(installed == "neon")
            } else {
                // No accelerated kernel for this processor is a correct
                // outcome, not a skipped test: the portable path is the
                // product too.
                #expect(installed == "portable")
            }
        }
        #expect(JPEG.Kernel.description == "portable", "install must be undoable")
    }

    /// The accelerated inverse transform against the portable one.
    @Test("inverse transform matches")
    func inverse() {
        var generator: Generator = .init(seed: 0xACCE1)
        var worst: Int = 0
        var blocks: Int = 0

        Self.accelerated { installed in
            guard installed != "portable" else {
                return
            }
            for _: Int in 0 ..< 4096 {
                var coefficients: [Int32] = .init(repeating: 0, count: 64)
                coefficients[0] = .init(truncatingIfNeeded: generator.next() % 16384) - 8192
                for _: Int in 0 ..< 8 {
                    let z: Int = .init(generator.next() % 63) + 1
                    coefficients[JPEG.zigzag[z]] =
                        .init(truncatingIfNeeded: generator.next() % 4096) - 2048
                }

                var fast: [UInt16] = .init(repeating: 0, count: 64)
                fast.withUnsafeMutableBufferPointer { samples in
                    coefficients.withUnsafeBufferPointer { coefficients in
                        JPEG.Kernel.inverseTransform(
                            coefficients.baseAddress!, 8, samples.baseAddress!
                        )
                    }
                }

                var portable: [UInt16] = .init(repeating: 0, count: 64)
                portable.withUnsafeMutableBufferPointer { samples in
                    coefficients.withUnsafeBufferPointer { coefficients in
                        JPEG.IDCT.transform8(coefficients, precision: 8, into: samples)
                    }
                }

                for (a, b): (UInt16, UInt16) in zip(fast, portable) {
                    worst = max(worst, abs(Int(a) - Int(b)))
                }
                blocks += 1
            }
        }

        // Exact. Both run the same factorization with the same constants and
        // the same descaling; the only difference is 32-bit lanes against
        // 64-bit accumulators, and for coefficients in this range that cannot
        // change a result. A single count of disagreement would mean a lane
        // is being computed differently, not rounded differently.
        #expect(worst == 0, "worst deviation \(worst) over \(blocks) blocks")
    }

    /// The accelerated forward transform against the portable one.
    @Test("forward transform matches")
    func forward() {
        var generator: Generator = .init(seed: 0xDEC0DE)
        var worst: Int = 0
        var blocks: Int = 0

        Self.accelerated { installed in
            guard installed != "portable" else {
                return
            }
            for _: Int in 0 ..< 4096 {
                let samples: [UInt16] = (0 ..< 64).map { _ in
                    .init(truncatingIfNeeded: generator.next() % 256)
                }

                var fast: [Int32] = .init(repeating: 0, count: 64)
                fast.withUnsafeMutableBufferPointer { coefficients in
                    samples.withUnsafeBufferPointer { samples in
                        JPEG.Kernel.forwardTransform(
                            samples.baseAddress!, 8, coefficients.baseAddress!
                        )
                    }
                }

                var portable: [Int32] = .init(repeating: 0, count: 64)
                portable.withUnsafeMutableBufferPointer { coefficients in
                    samples.withUnsafeBufferPointer { samples in
                        JPEG.FDCT.transform8(samples, precision: 8, into: coefficients)
                    }
                }

                for (a, b): (Int32, Int32) in zip(fast, portable) {
                    worst = max(worst, abs(Int(a) - Int(b)))
                }
                blocks += 1
            }
        }

        #expect(worst == 0, "worst deviation \(worst) over \(blocks) blocks")
    }

    /// Runs whichever color transform is installed, over a buffer with a
    /// sentinel past the end.
    private static func converted(
        _ interleaved: [UInt16], shift: Int32, padding: Int
    ) -> [UInt8] {
        // Three samples in per pixel and three bytes out, so the output is the
        // same count as the input.
        var output: [UInt8] = .init(
            repeating: 0xAA, count: interleaved.count + padding
        )
        output.withUnsafeMutableBufferPointer { output in
            interleaved.withUnsafeBufferPointer { input in
                JPEG.Kernel.colorTransform(
                    input.baseAddress!,
                    interleaved.count / 3,
                    shift,
                    output.baseAddress!
                )
            }
        }
        return output
    }

    /// The accelerated color transform against the portable one.
    ///
    /// Held to exactness, unlike the transforms. Those are two roundings of one
    /// real-valued factorization and may legitimately differ in the last bit;
    /// this is one fixed-point matrix with one rounding, so a disagreement of a
    /// single count would not be rounding, it would be a tint on every pixel of
    /// every image — visible only to users of whichever processor selected the
    /// wrong kernel.
    ///
    /// Every pixel count from one to forty, because the kernel converts eight
    /// at a time and an image whose pixel count is not a multiple of eight is
    /// the ordinary case rather than the edge one. The padding past the end
    /// catches the other half of that mistake: a kernel that writes a whole
    /// vector where only a tail was asked for.
    @Test("color transform matches")
    func color() {
        var generator: Generator = .init(seed: 0xC0FFEE)

        // Zero is 8-bit, four is the 12-bit path. The negative ones are formats
        // narrower than a byte, which are rare but reachable, and shift the
        // other way — the direction a kernel written for the common case gets
        // wrong.
        for shift: Int32 in [0, 4, 8, -1, -2] {
            for count: Int in 1 ... 40 {
                let interleaved: [UInt16] = (0 ..< 3 * count).map { _ in
                    .init(truncatingIfNeeded: generator.next())
                }

                var fast: [UInt8] = []
                Self.accelerated { installed in
                    guard installed != "portable" else {
                        return
                    }
                    fast = Self.converted(interleaved, shift: shift, padding: 16)
                }
                guard !fast.isEmpty else {
                    return
                }

                let portable: [UInt8] = Self.converted(
                    interleaved, shift: shift, padding: 16
                )
                #expect(fast == portable, "shift \(shift), \(count) pixels")
            }
        }
    }

    /// A whole image must decode identically either way.
    ///
    /// The block tests above cover the arithmetic; this covers the wiring —
    /// that the kernel actually gets called, with the right buffers, for every
    /// block of every plane including the padded ones at the edges.
    @Test("whole image decodes identically")
    func image() throws {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/subsampled", withExtension: "jpg")
        )
        let bytes: [UInt8] = .init(try Data(contentsOf: url))

        let portable: [JPEG.RGB] = try JPEG.Data.Rectangular<JPEG.Common>
            .decompress(bytes).unpack(as: JPEG.RGB.self)

        let accelerated: [JPEG.RGB] = try Self.accelerated { _ in
            try JPEG.Data.Rectangular<JPEG.Common>
                .decompress(bytes).unpack(as: JPEG.RGB.self)
        }

        #expect(portable.count == accelerated.count)
        #expect(portable == accelerated)
    }
}
