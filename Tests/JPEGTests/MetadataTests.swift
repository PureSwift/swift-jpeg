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
