import Testing

@testable import JPEG

/// Exercises the typed metadata layer: JFIF parsing and serialization, and the
/// classification of application segments.
struct MetadataTests {
    /// The minimal JFIF body the encoder has always written.
    static let minimal: [UInt8] = [
        0x4A, 0x46, 0x49, 0x46, 0x00,
        0x01, 0x02,
        0x00,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x00,
    ]

    @Test
    func parsesTheMinimalSegment() throws {
        let jfif: JPEG.JFIF = try #require(JPEG.JFIF.parse(Self.minimal))
        #expect(jfif.version == (1, 2))
        #expect(jfif.density == (1, 1))
        #expect(jfif.unit == nil)
        #expect(jfif.thumbnail.x == 0)
        #expect(jfif.thumbnail.y == 0)
        #expect(jfif.thumbnail.data.isEmpty)
        #expect(jfif.serialized() == Self.minimal)
    }

    @Test
    func roundTripsEveryField() throws {
        let original: JPEG.JFIF = .init(
            version: (1, 1),
            density: (x: 300, y: 600),
            unit: .inches,
            thumbnail: (x: 1, y: 2, data: [1, 2, 3, 4, 5, 6])
        )
        let jfif: JPEG.JFIF = try #require(JPEG.JFIF.parse(original.serialized()))
        #expect(jfif.version == (1, 1))
        #expect(jfif.density == (x: 300, y: 600))
        #expect(jfif.unit == .inches)
        #expect(jfif.thumbnail.data == [1, 2, 3, 4, 5, 6])
        #expect(jfif.serialized() == original.serialized())
    }

    @Test
    func centimetersRoundTrip() throws {
        let jfif: JPEG.JFIF = try #require(
            JPEG.JFIF.parse(JPEG.JFIF(density: (72, 72), unit: .centimeters).serialized())
        )
        #expect(jfif.unit == .centimeters)
    }

    /// An `APP0` that is not JFIF — a JFXX extension segment, say — must come
    /// back opaque with its body intact, not be rejected.
    @Test
    func foreignSegmentsStayOpaque() {
        let jfxx: [UInt8] = [0x4A, 0x46, 0x58, 0x58, 0x00, 0x10]
        #expect(JPEG.JFIF.parse(jfxx) == nil)
        guard case .application(0, let data) = JPEG.Metadata.parse(application: 0, data: jfxx)
        else {
            Issue.record("JFXX was not kept as an opaque segment")
            return
        }
        #expect(data == jfxx)

        // A truncated JFIF signature is likewise not JFIF.
        #expect(JPEG.JFIF.parse([0x4A, 0x46, 0x49, 0x46, 0x00, 0x01]) == nil)
    }

    @Test
    func classifiesExifBySignature() {
        let tiff: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
        let body: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] + tiff

        guard case .exif(let data) = JPEG.Metadata.parse(application: 1, data: body) else {
            Issue.record("EXIF signature was not recognized")
            return
        }
        #expect(data == tiff)

        // Serialization restores the signature the parse stripped.
        let metadata: JPEG.Metadata = .exif(data: tiff)
        #expect(metadata.segment.marker == .application(1))
        #expect(metadata.segment.body == body)

        // An APP1 without the signature — XMP lives there — stays opaque.
        guard case .application(1, let kept) = JPEG.Metadata.parse(application: 1, data: tiff)
        else {
            Issue.record("a non-EXIF APP1 was not kept as an opaque segment")
            return
        }
        #expect(kept == tiff)
    }

    /// A gray 8×8 image, encoded by this library's own encoder.
    static func encoded() throws -> [UInt8] {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: .y(1, precision: 8),
            process: .baseline,
            width: 8,
            height: 8,
            sampling: [.init(x: 1, y: 1)],
            selectors: [0]
        )
        let image: JPEG.Data.Rectangular<JPEG.Common> = .init(
            layout: layout,
            values: .init(repeating: 128, count: 64)
        )
        var stream: [UInt8] = []
        try image.compress(stream: &stream)
        return stream
    }

    /// Splices a segment into a stream after the two-byte start-of-image
    /// marker.
    static func spliced(
        _ stream: [UInt8], marker: UInt8, body: [UInt8]
    ) -> [UInt8] {
        let length: Int = body.count + 2
        return .init(stream[..<2])
            + [0xFF, marker, .init(length >> 8), .init(length & 0xFF)]
            + body
            + stream[2...]
    }

    /// The decoder must retain application segments and comments, classified
    /// and in stream order, all the way down to the rectangular tier.
    @Test
    func decodeRetainsSegments() throws {
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        var stream: [UInt8] = try Self.encoded()
        // Spliced in reverse so they end up: EXIF, comment, then the JFIF the
        // encoder wrote.
        stream = Self.spliced(stream, marker: 0xFE, body: [0x68, 0x69])
        stream = Self.spliced(
            stream, marker: 0xE1, body: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] + tiff
        )

        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream)
        #expect(image.metadata.count == 3)

        guard case .exif(let data) = image.metadata.first else {
            Issue.record("EXIF was not first: \(image.metadata)")
            return
        }
        #expect(data == tiff)
        guard case .comment(let text) = image.metadata.dropFirst().first else {
            Issue.record("the comment was not second: \(image.metadata)")
            return
        }
        #expect(text == [0x68, 0x69])
        guard case .jfif(let jfif) = image.metadata.last else {
            Issue.record("the JFIF segment was not retained: \(image.metadata)")
            return
        }
        #expect(jfif.density == (1, 1))
    }

    /// A caller's JFIF must replace the encoder's default, and the other
    /// segments must survive an encode-decode round trip in order.
    @Test
    func encodeWritesSuppliedMetadata() throws {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: .y(1, precision: 8),
            process: .baseline,
            width: 8,
            height: 8,
            sampling: [.init(x: 1, y: 1)],
            selectors: [0]
        )
        var image: JPEG.Data.Rectangular<JPEG.Common> = .init(
            layout: layout,
            values: .init(repeating: 128, count: 64)
        )
        image.metadata = [
            .jfif(.init(density: (300, 300), unit: .inches)),
            .comment(data: [0x68, 0x69]),
            .exif(data: [0x4D, 0x4D, 0x00, 0x2A]),
        ]

        var stream: [UInt8] = []
        try image.compress(stream: &stream)
        let decoded: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream)

        #expect(decoded.metadata.count == 3)
        guard case .jfif(let jfif) = decoded.metadata.first else {
            Issue.record("the supplied JFIF was not written: \(decoded.metadata)")
            return
        }
        #expect(jfif.density == (300, 300))
        #expect(jfif.unit == .inches)
        guard case .comment(let text) = decoded.metadata.dropFirst().first else {
            Issue.record("the comment was lost: \(decoded.metadata)")
            return
        }
        #expect(text == [0x68, 0x69])
        guard case .exif(let exif) = decoded.metadata.last else {
            Issue.record("the EXIF segment was lost: \(decoded.metadata)")
            return
        }
        #expect(exif == [0x4D, 0x4D, 0x00, 0x2A])

        // The APP0 must be the stream's first segment, and there must be
        // exactly one of it.
        #expect(stream[2 ..< 4] == [0xFF, 0xE0])
        var count: Int = 0
        for index: Int in stream.indices.dropLast()
            where stream[index] == 0xFF && stream[index + 1] == 0xE0
        {
            count += 1
        }
        #expect(count == 1)
    }

    /// An image with no metadata must encode exactly as it always has: one
    /// minimal JFIF segment, byte-identical to the old hardcoded one.
    @Test
    func encodeDefaultsToTheMinimalSegment() throws {
        let stream: [UInt8] = try Self.encoded()
        #expect(stream[2 ..< 4] == [0xFF, 0xE0])
        #expect(stream[4 ..< 6] == [0x00, 0x10])
        #expect(.init(stream[6 ..< 6 + Self.minimal.count]) == Self.minimal)
    }

    @Test
    func classifiesJFIF() {
        guard case .jfif(let jfif) = JPEG.Metadata.parse(application: 0, data: Self.minimal)
        else {
            Issue.record("a JFIF segment was not recognized")
            return
        }
        #expect(jfif.serialized() == Self.minimal)
    }
}
