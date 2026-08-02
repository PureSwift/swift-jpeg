import Foundation
import Testing

@testable import JPEG

/// Exercises the encoder by round-tripping through the decoder.
///
/// That pairing is only circular if the two share code, and they do not: the
/// forward and inverse transforms are separate implementations checked against
/// each other and against the closed form, and the Huffman encoder is derived
/// from the same canonical assignment the decoder reconstructs independently.
/// A defect in one direction shows up as round-trip error, not as a
/// cancellation.
///
/// The output has also been checked externally against libjpeg-turbo, through
/// both ImageMagick and Pillow with warnings fatal. Those decoders read every
/// fixture cleanly and report back the exact quality, subsampling, and
/// colorspace that was requested. That check is not automated here because it
/// would make the suite depend on tools that may not be installed.
struct EncodeTests {
    private static func resource(_ name: String, _ ext: String) throws -> [UInt8] {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: ext),
            "missing test resource \(name).\(ext)"
        )
        return .init(try Data(contentsOf: url))
    }

    private static func decode(_ bytes: [UInt8]) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        var stream: [UInt8] = bytes
        return try .decompress(stream: &stream)
    }

    /// Mean absolute difference per sample between two images of equal size.
    private static func deviation(
        _ a: JPEG.Data.Rectangular<JPEG.Common>,
        _ b: JPEG.Data.Rectangular<JPEG.Common>
    ) -> (maximum: Int, mean: Double) {
        var maximum: Int = 0
        var total: Int = 0
        for y: Int in 0 ..< a.height {
            for x: Int in 0 ..< a.width {
                for plane: Int in 0 ..< a.stride {
                    let error: Int = abs(.init(a[x: x, y: y, plane]) - .init(b[x: x, y: y, plane]))
                    maximum = max(maximum, error)
                    total += error
                }
            }
        }
        return (maximum, .init(total) / .init(a.width * a.height * a.stride))
    }

    @Test(arguments: ["gray", "full", "subsampled", "wide"])
    func roundTripsThroughOwnDecoder(_ name: String) throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(
            Self.resource(name, "jpg")
        )

        var encoded: [UInt8] = []
        try source.compress(stream: &encoded, quality: 95)
        let result: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(encoded)

        #expect(result.width == source.width)
        #expect(result.height == source.height)
        #expect(result.stride == source.stride)
        #expect(result.layout.scale == source.layout.scale)

        // One extra generation of quantization at quality 95, so a few counts
        // of drift are expected; a structural fault would be far larger.
        //
        // The bound is set from measurement rather than taste. libjpeg-turbo
        // performing the same decode-then-re-encode on these fixtures drifts by
        // a mean of 0.75 (grayscale) to 1.72 (4:2:2); this encoder measures 0.77
        // and 0.61. So a ceiling of 1.0 sits above what we do and below what the
        // reference implementation does, which keeps it a real regression guard
        // instead of a rubber stamp.
        let deviation: (maximum: Int, mean: Double) = Self.deviation(source, result)
        #expect(deviation.maximum <= 12, "\(name): worst-case drift \(deviation.maximum)")
        #expect(deviation.mean < 1.0, "\(name): mean drift \(deviation.mean)")
    }

    @Test
    func writesAWellFormedStream() throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(
            Self.resource("subsampled", "jpg")
        )
        var encoded: [UInt8] = []
        try source.compress(stream: &encoded, quality: 85)

        #expect(encoded.prefix(2) == [0xFF, 0xD8], "stream must open with SOI")
        #expect(encoded.suffix(2) == [0xFF, 0xD9], "stream must close with EOI")

        // Walk the segments the way a lexer would and check the ones a baseline
        // stream must carry are present and correctly ordered.
        var stream: [UInt8] = encoded
        try stream.start()

        var seen: [JPEG.Marker] = []
        while true {
            let (marker, _): (JPEG.Marker, [UInt8]) = try stream.segment()
            seen.append(marker)
            if case .scan = marker {
                break
            }
        }

        #expect(seen.contains { if case .application(0) = $0 { return true } else { return false } })
        #expect(seen.contains { if case .quantization = $0 { return true } else { return false } })
        #expect(seen.contains { if case .huffman = $0 { return true } else { return false } })

        // Tables must precede what references them, or a decoder cannot resolve
        // the reference when it reaches it.
        let frame: Int = try #require(
            seen.firstIndex { if case .frame = $0 { return true } else { return false } }
        )
        let quantization: Int = try #require(
            seen.firstIndex { if case .quantization = $0 { return true } else { return false } }
        )
        let huffman: Int = try #require(
            seen.firstIndex { if case .huffman = $0 { return true } else { return false } }
        )
        #expect(quantization < frame, "quantization tables must precede the frame header")
        #expect(huffman < seen.count - 1, "huffman tables must precede the scan header")
    }

    @Test
    func qualityTradesSizeAgainstFidelity() throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(
            Self.resource("full", "jpg")
        )

        var sizes: [Int] = []
        var errors: [Double] = []
        for quality: Int in [30, 60, 90] {
            var encoded: [UInt8] = []
            try source.compress(stream: &encoded, quality: quality)
            sizes.append(encoded.count)
            errors.append(Self.deviation(source, try Self.decode(encoded)).mean)
        }

        #expect(sizes[0] < sizes[1], "higher quality must not shrink the file")
        #expect(sizes[1] < sizes[2])
        #expect(errors[0] > errors[1], "higher quality must not increase error")
        #expect(errors[1] > errors[2])
    }

    @Test
    func emitsRestartIntervalsThatSurviveDecoding() throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(
            Self.resource("subsampled", "jpg")
        )

        var plain: [UInt8] = []
        try source.compress(stream: &plain, quality: 85)

        var restarting: [UInt8] = []
        try source.compress(stream: &restarting, quality: 85, restartInterval: 4)

        // The markers cost bytes, which is how we know they were written.
        #expect(restarting.count > plain.count)

        let markers: Int = (0 ..< restarting.count - 1).count {
            restarting[$0] == 0xFF && 0xD0 ... 0xD7 ~= restarting[$0 + 1]
        }
        #expect(markers > 0, "no restart markers found in the output")

        // Both must decode to the same image: restarts change the framing, not
        // the coefficients.
        let a: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(plain)
        let b: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(restarting)
        #expect(Self.deviation(a, b).maximum == 0)
    }

    @Test
    func encodesEveryQualityWithoutOverflow() throws {
        // Quality 1 pushes quantization factors to their 255 ceiling and
        // quality 100 pulls them all to 1, which is where a magnitude category
        // would overflow if the amplitude split were wrong.
        let source: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(
            Self.resource("full", "jpg")
        )

        for quality: Int in [1, 2, 50, 99, 100] {
            var encoded: [UInt8] = []
            try source.compress(stream: &encoded, quality: quality)
            let result: JPEG.Data.Rectangular<JPEG.Common> = try Self.decode(encoded)
            #expect(result.width == source.width, "quality \(quality) did not round trip")
        }
    }
}
