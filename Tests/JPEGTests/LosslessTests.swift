import Foundation
import Testing

@testable import JPEG

/// Covers the lossless process.
///
/// One claim to test, and it admits no tolerance: the samples that come out
/// must be the samples that went in. Every check here is exact equality, and
/// anything less would mean the process is misnamed.
struct LosslessTests {
    private static func image(
        precision: Int,
        width: Int = 61,
        height: Int = 43
    ) throws -> (JPEG.Data.Lossless<JPEG.Common>, [UInt16]) {
        let ceiling: Int = (1 << precision) - 1
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: .rgb(82, 71, 66, precision: precision),
            process: .lossless(coding: .huffman, differential: false),
            width: width,
            height: height,
            sampling: .init(repeating: .init(x: 1, y: 1), count: 3),
            selectors: .init(repeating: 0, count: 3)
        )

        var values: [UInt16] = .init(repeating: 0, count: width * height * 3)
        for y: Int in 0 ..< height {
            for x: Int in 0 ..< width {
                let base: Int = (y * width + x) * 3
                // A smooth ramp, a hard checkerboard and a second ramp: the
                // first suits a plane predictor, the second suits none of them,
                // and between them they keep any single predictor from looking
                // accidentally good.
                values[base] = .init(x * ceiling / width)
                values[base + 1] = .init((x ^ y) & 1 == 0 ? 0 : ceiling)
                values[base + 2] = .init(y * ceiling / height)
            }
        }
        return (.init(layout: layout, values: values), values)
    }

    private static func identical(
        _ image: JPEG.Data.Lossless<JPEG.Common>,
        _ other: JPEG.Data.Lossless<JPEG.Common>
    ) -> Bool {
        guard
        image.layout.width == other.layout.width,
        image.layout.height == other.layout.height,
        image.planes.count == other.planes.count
        else {
            return false
        }
        for plane: Int in image.planes.indices {
            for y: Int in 0 ..< image.layout.height {
                for x: Int in 0 ..< image.layout.width {
                    if image.planes[plane][x: x, y: y] != other.planes[plane][x: x, y: y] {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Every predictor at every precision the process allows at the extremes.
    @Test(arguments: JPEG.Predictor.allCases, [8, 12, 16])
    func roundTripsExactly(_ predictor: JPEG.Predictor, _ precision: Int) throws {
        let (source, _): (JPEG.Data.Lossless<JPEG.Common>, [UInt16]) =
            try Self.image(precision: precision)

        var encoded: [UInt8] = []
        try source.compress(stream: &encoded, predictor: predictor)
        let decoded: JPEG.Data.Lossless<JPEG.Common> = try .decompress(encoded)

        #expect(
            Self.identical(source, decoded),
            "predictor \(predictor.rawValue) at \(precision)-bit is not exact"
        )
    }

    @Test
    func writesALosslessFrameHeader() throws {
        let (source, _): (JPEG.Data.Lossless<JPEG.Common>, [UInt16]) =
            try Self.image(precision: 8)
        var encoded: [UInt8] = []
        try source.compress(stream: &encoded, predictor: .plane)

        // SOF3 is lossless sequential Huffman.
        var frame: Int?
        for i: Int in 0 ..< encoded.count - 1
        where encoded[i] == 0xFF && 0xC0 ... 0xCF ~= encoded[i + 1]
            && ![0xC4, 0xC8, 0xCC].contains(encoded[i + 1])
        {
            frame = i
            break
        }
        #expect(encoded[try #require(frame) + 1] == 0xC3)

        // The scan header reuses the spectral selection fields: Ss carries the
        // predictor and Se must be zero. Writing the band's upper bound there,
        // as the DCT processes do, produces a header no decoder accepts.
        var scan: Int?
        for i: Int in 0 ..< encoded.count - 1 where encoded[i] == 0xFF && encoded[i + 1] == 0xDA {
            scan = i
            break
        }
        let body: Int = try #require(scan) + 4
        let components: Int = .init(encoded[body])
        #expect(encoded[body + 1 + 2 * components] == 4, "Ss carries the predictor")
        #expect(encoded[body + 2 + 2 * components] == 0, "Se must be zero")
        #expect(encoded[body + 3 + 2 * components] == 0, "Ah and Al must be zero")

        // No quantization tables: there is nothing to quantize.
        let quantization: Bool = (0 ..< encoded.count - 1).contains {
            encoded[$0] == 0xFF && encoded[$0 + 1] == 0xDB
        }
        #expect(!quantization, "a lossless image defines no quantization table")
    }

    @Test
    func pointTransformTradesExactnessForSize() throws {
        let (source, _): (JPEG.Data.Lossless<JPEG.Common>, [UInt16]) =
            try Self.image(precision: 8)

        var exact: [UInt8] = []
        try source.compress(stream: &exact, predictor: .plane, transform: 0)
        var reduced: [UInt8] = []
        try source.compress(stream: &reduced, predictor: .plane, transform: 2)

        #expect(reduced.count < exact.count, "a point transform must shrink the output")

        // And it is the one way this process loses anything, so the result is
        // deliberately *not* identical.
        let decoded: JPEG.Data.Lossless<JPEG.Common> = try .decompress(reduced)
        #expect(!Self.identical(source, decoded))
    }

    @Test
    func rejectsAnInvalidPredictor() throws {
        // Ss of zero means "no prediction", which T.81 reserves for the
        // differential frames of a hierarchical sequence.
        var encoded: [UInt8] = []
        let (source, _): (JPEG.Data.Lossless<JPEG.Common>, [UInt16]) =
            try Self.image(precision: 8)
        try source.compress(stream: &encoded, predictor: .plane)

        var scan: Int?
        for i: Int in 0 ..< encoded.count - 1 where encoded[i] == 0xFF && encoded[i + 1] == 0xDA {
            scan = i
            break
        }
        let body: Int = try #require(scan) + 4
        let components: Int = .init(encoded[body])
        encoded[body + 1 + 2 * components] = 0

        let failure: JPEG.Failure? = #expect(throws: JPEG.Failure.self) {
            _ = try JPEG.Data.Lossless<JPEG.Common>.decompress(encoded)
        }
        // The stage is the useful part of the assertion: it says the failure
        // was found where it should have been.
        #expect(failure?.stage == JPEG.ParsingError.namespace)
    }
}
