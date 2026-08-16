import Foundation
import Testing

@testable import JPEG

/// Exercises the extended sequential process, `SOF1`.
///
/// This process was carried by the claim that it "shares the baseline path",
/// which is true and was the reason it went untested: an untested claim of
/// equivalence is exactly the kind that stops being true quietly. What follows
/// states it as a property rather than as a comment — an extended sequential
/// stream and the baseline stream of the same coefficients differ in one byte,
/// the frame marker, and decode to the same image.
///
/// The 12-bit case is covered elsewhere, through the C boundary, since
/// `tj3Compress12` emits this process by necessity. What was uncovered is the
/// 8-bit one, which is the case a real file uses.
struct ExtendedTests {
    static let extended: JPEG.Process = .extended(coding: .huffman, differential: false)

    private static func resource(_ name: String, _ ext: String) throws -> [UInt8] {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: ext),
            "missing test resource \(name).\(ext)"
        )
        return .init(try Data(contentsOf: url))
    }

    /// The offset of the frame marker's code byte in a stream.
    ///
    /// Found by walking segments rather than by searching for the byte, since
    /// `FF C0` occurs inside quantization tables often enough to matter.
    static func frameMarker(in stream: [UInt8]) throws -> Int {
        var cursor: JPEG.Bytestream.Cursor = .init(stream)
        try cursor.start()
        var offset: Int = 2
        while true {
            let (marker, data): (JPEG.Marker, [UInt8]) = try cursor.segment()
            if case .frame = marker {
                return offset + 1
            }
            guard marker != .end, marker != .scan else {
                throw JPEG.Failure.decoding(.missingFrameHeader)
            }
            // Two bytes of marker, two of length, and the body.
            offset += 4 + data.count
        }
    }

    /// A real baseline file with its frame marker changed to `SOF1` is a valid
    /// extended sequential file, because the two processes code 8-bit samples
    /// identically. So this decodes the same fixture twice and holds the two
    /// results to equality.
    @Test(arguments: ["gray", "full", "subsampled", "wide"])
    func decodesAPatchedBaselineFixture(_ name: String) throws {
        let baseline: [UInt8] = try Self.resource(name, "jpg")
        let offset: Int = try Self.frameMarker(in: baseline)
        // The fixtures are baseline; if one stops being, this test is no
        // longer testing what it says it is.
        try #require(baseline[offset] == 0xC0)

        var patched: [UInt8] = baseline
        patched[offset] = 0xC1

        let original: JPEG.Data.Spectral<JPEG.Common> = try .decompress(baseline)
        let extended: JPEG.Data.Spectral<JPEG.Common> = try .decompress(patched)

        #expect(original.layout.process == .baseline)
        #expect(extended.layout.process == Self.extended)
        #expect(extended.layout.width == original.layout.width)
        #expect(extended.layout.height == original.layout.height)

        // Every coefficient of every block of every plane.
        try #require(extended.planes.count == original.planes.count)
        for plane: Int in original.planes.indices {
            let blocks: (x: Int, y: Int) = original.planes[plane].blocks
            #expect(extended.planes[plane].blocks == blocks)
            for y: Int in 0 ..< blocks.y {
                for x: Int in 0 ..< blocks.x {
                    #expect(
                        extended.planes[plane].block(x: x, y: y)
                            == original.planes[plane].block(x: x, y: y),
                        "plane \(plane), block (\(x), \(y))"
                    )
                }
            }
        }
    }

    /// Encoding the same coefficients as baseline and as extended sequential
    /// must produce streams that differ in exactly one byte: the frame marker.
    ///
    /// The sharp form of "shares the baseline path". A divergence anywhere in
    /// the tables, the scan header, or the entropy coded data shows up as a
    /// second differing byte.
    @Test(arguments: ["gray", "subsampled"])
    func encodesIdenticallyApartFromTheMarker(_ name: String) throws {
        let source: JPEG.Data.Spectral<JPEG.Common> = try .decompress(
            try Self.resource(name, "jpg")
        )
        let reprocessed: JPEG.Data.Spectral<JPEG.Common> = try #require(
            source.reprocessed(as: Self.extended),
            "8-bit samples must fit the extended sequential process"
        )

        var tables: JPEG.Tables = .init()
        tables.push(try .standard(.luminance, class: .dc, target: 0))
        tables.push(try .standard(.luminance, class: .ac, target: 0))
        if source.layout.planes.count > 1 {
            tables.push(try .standard(.chrominance, class: .dc, target: 1))
            tables.push(try .standard(.chrominance, class: .ac, target: 1))
        }

        var asBaseline: [UInt8] = []
        var asExtended: [UInt8] = []
        try source.compress(stream: &asBaseline, tables: tables)
        try reprocessed.compress(stream: &asExtended, tables: tables)

        try #require(asBaseline.count == asExtended.count)
        var differing: [Int] = []
        for index: Int in asBaseline.indices where asBaseline[index] != asExtended[index] {
            differing.append(index)
        }
        #expect(differing.count == 1, "differing at \(differing)")

        let offset: Int = try #require(differing.first)
        #expect(asBaseline[offset] == 0xC0)
        #expect(asExtended[offset] == 0xC1)
        #expect(offset == (try Self.frameMarker(in: asExtended)))
    }

    /// A stream this library wrote as extended sequential must read back as
    /// one, and to the same samples.
    @Test
    func roundTripsThroughItsOwnEncoder() throws {
        let source: JPEG.Data.Rectangular<JPEG.Common> = try JPEG.Data.Spectral<JPEG.Common>
            .decompress(try Self.resource("subsampled", "jpg"))
            .rectangular()

        let spectral: JPEG.Data.Spectral<JPEG.Common> = try source.spectral(
            quanta: [
                0: .standard(.luminance, quality: 90, target: 0, baseline: false),
                1: .standard(.chrominance, quality: 90, target: 1, baseline: false),
            ]
        )
        let reprocessed: JPEG.Data.Spectral<JPEG.Common> = try #require(
            spectral.reprocessed(as: Self.extended)
        )

        var tables: JPEG.Tables = .init()
        tables.push(try .standard(.luminance, class: .dc, target: 0))
        tables.push(try .standard(.luminance, class: .ac, target: 0))
        tables.push(try .standard(.chrominance, class: .dc, target: 1))
        tables.push(try .standard(.chrominance, class: .ac, target: 1))

        var stream: [UInt8] = []
        try reprocessed.compress(stream: &stream, tables: tables)

        let decoded: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream)
        #expect(decoded.layout.process == Self.extended)

        // The coefficients went out and came back untouched: this process is
        // lossless over an already-quantized image, as baseline is.
        for plane: Int in reprocessed.planes.indices {
            let blocks: (x: Int, y: Int) = reprocessed.planes[plane].blocks
            for y: Int in 0 ..< blocks.y {
                for x: Int in 0 ..< blocks.x {
                    #expect(
                        decoded.planes[plane].block(x: x, y: y)
                            == reprocessed.planes[plane].block(x: x, y: y),
                        "plane \(plane), block (\(x), \(y))"
                    )
                }
            }
        }
    }

    /// The marker byte and the process must agree in both directions, for
    /// every combination of the two flags the code encodes.
    ///
    /// `SOF1` is `0xC1`; arithmetic coding sets bit 3 and the differential
    /// flag sets bit 2. Getting this grid wrong is how a stream comes back
    /// labelled as the wrong process.
    @Test
    func markerCodesRoundTrip() {
        let codes: [(UInt8, JPEG.Coding, Bool)] = [
            (0xC1, .huffman, false),
            (0xC5, .huffman, true),
            (0xC9, .arithmetic, false),
            (0xCD, .arithmetic, true),
        ]
        for (code, coding, differential): (UInt8, JPEG.Coding, Bool) in codes {
            let process: JPEG.Process = .extended(coding: coding, differential: differential)
            #expect(process.markerCode == code)
            #expect(JPEG.Process(markerCode: code) == process)
            #expect(JPEG.Marker(code: code) == .frame(process))
        }
    }

    /// The extended process carries 12-bit samples where baseline cannot, and
    /// that difference is the reason it exists.
    @Test
    func acceptsTwelveBitSamples() {
        #expect(Self.extended.precisions == 8 ... 12)
        #expect(JPEG.Process.baseline.precisions == 8 ... 8)
        #expect(Self.extended.precisions.contains(12))
        #expect(!JPEG.Process.baseline.precisions.contains(12))
    }
}
