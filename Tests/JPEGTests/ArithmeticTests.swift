import Foundation
import Testing

@testable import JPEG

/// Covers the arithmetic entropy coder of T.81 Annex D.
///
/// The important test here is not the round trip. Encoder and decoder that
/// share a misreading of the standard round-trip perfectly and interoperate
/// with nothing — which is exactly what happened during development, and was
/// only caught by decoding a file this library did not produce.
///
/// So `ref-arith.jpg` is a fixture written by libjpeg, and decoding it
/// correctly is the claim that actually matters.
struct ArithmeticTests {
    private static func resource(_ name: String, _ ext: String) throws -> [UInt8] {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: ext)
        )
        return .init(try Data(contentsOf: url))
    }

    /// The coder must be its own inverse over an arbitrary decision sequence.
    @Test(arguments: [0, 1, 8, 15, 16])
    func coderRoundTripsAtEveryBias(_ bias: Int) {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random() -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return .init(seed >> 60)
        }

        var decisions: [(context: Int, bit: Int)] = []
        for _ in 0 ..< 20000 {
            decisions.append((context: random() & 7, bit: random() < bias ? 0 : 1))
        }

        var encoder: JPEG.Arithmetic.Encoder = .init()
        var writing: [JPEG.Arithmetic.Context] = .init(repeating: 0, count: 8)
        for decision: (context: Int, bit: Int) in decisions {
            encoder.encode(&writing[decision.context], decision.bit)
        }
        let bytes: [UInt8] = encoder.finish()

        var decoder: JPEG.Arithmetic.Decoder = .init(bytes)
        var reading: [JPEG.Arithmetic.Context] = .init(repeating: 0, count: 8)
        for decision: (context: Int, bit: Int) in decisions {
            #expect(decoder.decode(&reading[decision.context]) == decision.bit)
        }
    }

    /// The decisive test: a file this library did not write.
    @Test
    func decodesAReferenceImage() throws {
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(
            Self.resource("ref-arith", "jpg")
        )
        #expect(image.layout.process == .extended(coding: .arithmetic, differential: false))

        let reference: [UInt8] = try Self.resource("ref-arith", "rgb")
        var deviation: Int = 0
        for y: Int in 0 ..< image.height {
            for x: Int in 0 ..< image.width {
                let color: JPEG.RGB = JPEG.YCbCr(
                    y: .init(image[x: x, y: y, 0]),
                    cb: .init(image[x: x, y: y, 1]),
                    cr: .init(image[x: x, y: y, 2])
                ).rgb
                let base: Int = (y * image.width + x) * 3
                for (k, sample): (Int, UInt8) in [color.r, color.g, color.b].enumerated() {
                    deviation = max(deviation, abs(.init(sample) - .init(reference[base + k])))
                }
            }
        }
        // The same bound the Huffman fixtures meet: this is ordinary inverse
        // transform rounding, not coder disagreement.
        #expect(deviation <= 4, "worst-case deviation from libjpeg's decode was \(deviation)")
    }

    @Test(arguments: ["full", "gray", "subsampled", "wide"])
    func codesTheSameCoefficientsAsHuffman(_ name: String) throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(
            Self.resource(name, "jpg")
        )

        var huffman: [UInt8] = []
        try source.compress(stream: &huffman, quality: 90)
        var arithmetic: [UInt8] = []
        try source.compress(stream: &arithmetic, quality: 90, arithmetic: true)

        // SOF9 is extended sequential, arithmetic coded.
        var frame: Int?
        for i: Int in 0 ..< arithmetic.count - 1
        where arithmetic[i] == 0xFF && 0xC0 ... 0xCF ~= arithmetic[i + 1]
            && ![0xC4, 0xC8, 0xCC].contains(arithmetic[i + 1])
        {
            frame = i
            break
        }
        #expect(arithmetic[try #require(frame) + 1] == 0xC9)

        // Entropy coding does not touch the coefficients, so the two files must
        // decode to exactly the same samples.
        let a: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(huffman)
        let b: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(arithmetic)
        #expect(a.values == b.values, "\(name): arithmetic and Huffman decodes differ")

        // And it should be smaller, which is the only reason to use it.
        #expect(
            arithmetic.count < huffman.count,
            "\(name): arithmetic \(arithmetic.count) vs Huffman \(huffman.count)"
        )
    }
}
