import Testing

@testable import JPEG

/// Exercises the EXIF orientation reader.
///
/// The blocks are built here rather than taken from a fixture so that both
/// byte orders, a missing tag, and every malformed shape are covered. A real
/// camera file exercises exactly one of those.
struct EXIFTests {
    /// Builds a TIFF block whose first directory holds the given entries.
    ///
    /// -   Parameters:
    ///     -   entries: Tag, type, count, and the four value bytes, in order.
    ///     -   littleEndian: The byte order to declare and to write in.
    static func tiff(
        entries: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])],
        littleEndian: Bool = true
    ) -> [UInt8] {
        func short(_ value: UInt16) -> [UInt8] {
            let bytes: [UInt8] = [
                .init(truncatingIfNeeded: value >> 8), .init(truncatingIfNeeded: value),
            ]
            return littleEndian ? bytes.reversed() : bytes
        }
        func long(_ value: UInt32) -> [UInt8] {
            let bytes: [UInt8] = (0 ..< 4).map {
                .init(truncatingIfNeeded: value >> (8 * (3 - $0)))
            }
            return littleEndian ? bytes.reversed() : bytes
        }

        var data: [UInt8] = littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]
        data += short(42)
        data += long(8)                             // the directory follows the header
        data += short(.init(entries.count))
        for entry in entries {
            data += short(entry.tag)
            data += short(entry.type)
            data += long(entry.count)
            data += entry.value
        }
        data += long(0)                             // no second directory
        return data
    }

    /// An orientation entry: a `SHORT` of count one, stored inline and padded.
    static func orientation(_ value: UInt8, littleEndian: Bool = true)
        -> (tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])
    {
        (
            tag: 0x0112,
            type: 3,
            count: 1,
            value: littleEndian ? [value, 0, 0, 0] : [0, value, 0, 0]
        )
    }

    @Test(arguments: [true, false])
    func readsOrientationInEitherByteOrder(_ littleEndian: Bool) {
        for raw: Int in 1 ... 8 {
            let block: [UInt8] = Self.tiff(
                entries: [
                    Self.orientation(.init(raw), littleEndian: littleEndian),
                ],
                littleEndian: littleEndian
            )
            let metadata: JPEG.Metadata = .exif(data: block)
            #expect(metadata.orientation == JPEG.Orientation(rawValue: raw))
        }
    }

    /// The tag is found wherever it sits in the directory, not only first.
    @Test
    func findsTheTagAmongOthers() {
        let block: [UInt8] = Self.tiff(entries: [
            (tag: 0x010F, type: 2, count: 4, value: [0x41, 0x42, 0x43, 0x00]),
            (tag: 0x0100, type: 3, count: 1, value: [0x40, 0, 0, 0]),
            Self.orientation(6),
            (tag: 0x0128, type: 3, count: 1, value: [2, 0, 0, 0]),
        ])
        #expect(JPEG.Metadata.exif(data: block).orientation == .right)
    }

    /// Every EXIF orientation must map to the symmetry that undoes it, and the
    /// eight must be distinct — a duplicate here would silently display two
    /// orientations the same way.
    @Test
    func everyOrientationNormalizes() {
        #expect(JPEG.Orientation.up.transform == .none)
        #expect(JPEG.Orientation.upMirrored.transform == .horizontalFlip)
        #expect(JPEG.Orientation.down.transform == .rotate180)
        #expect(JPEG.Orientation.downMirrored.transform == .verticalFlip)
        #expect(JPEG.Orientation.leftMirrored.transform == .transpose)
        #expect(JPEG.Orientation.right.transform == .rotate90)
        #expect(JPEG.Orientation.rightMirrored.transform == .transverse)
        #expect(JPEG.Orientation.left.transform == .rotate270)

        var seen: Set<JPEG.Transform> = []
        for orientation: JPEG.Orientation in JPEG.Orientation.allCases {
            seen.insert(orientation.transform)
        }
        #expect(seen.count == 8)
    }

    /// `rotate90` must be the clockwise one, or a photograph taken with the
    /// camera on its side comes out upside down rather than upright.
    ///
    /// Checked against the block grid rather than by assertion: orientation 6
    /// says the stored image's first row is the display's right edge, so the
    /// transform that fixes it must carry the top-left block to the top right.
    @Test
    func rotationGoesTheRightWay() {
        let transform: JPEG.Transform = JPEG.Orientation.right.transform
        let destination: (x: Int, y: Int) = transform.destination(
            of: (x: 0, y: 0), in: (x: 4, y: 3)
        )
        // The rotated grid is three blocks wide, so its right edge is x = 2.
        #expect(destination == (x: 2, y: 0))
    }

    @Test(arguments: [true, false])
    func writesOrientationInEitherByteOrder(_ littleEndian: Bool) {
        var metadata: JPEG.Metadata = .exif(
            data: Self.tiff(
                entries: [Self.orientation(6, littleEndian: littleEndian)],
                littleEndian: littleEndian
            )
        )
        #expect(metadata.orientation == .right)
        let written: Bool = metadata.set(orientation: .up)
        #expect(written)
        #expect(metadata.orientation == .up)

        // The patch must not have changed the block's size — an insertion
        // would shift every offset after it.
        guard case .exif(let data) = metadata else {
            Issue.record("the segment stopped being EXIF")
            return
        }
        #expect(
            data.count == Self.tiff(
                entries: [Self.orientation(1, littleEndian: littleEndian)],
                littleEndian: littleEndian
            ).count
        )
    }

    /// Writing must report failure rather than silently doing nothing when
    /// there is no entry to patch.
    @Test
    func writingWithoutAnEntryFails() {
        var absent: JPEG.Metadata = .exif(
            data: Self.tiff(entries: [(tag: 0x0100, type: 3, count: 1, value: [1, 0, 0, 0])])
        )
        let patched: Bool = absent.set(orientation: .down)
        #expect(!patched)
        #expect(absent.orientation == nil)

        var comment: JPEG.Metadata = .comment(data: [1, 2, 3])
        let commented: Bool = comment.set(orientation: .down)
        #expect(!commented)
        #expect(comment.orientation == nil)
    }

    /// A collection reports `up` when nothing states an orientation, so a
    /// caller deciding how to display an image has no separate case.
    @Test
    func collectionDefaultsToUp() {
        let none: [JPEG.Metadata] = [.jfif(.init()), .comment(data: [])]
        #expect(none.orientation == .up)

        var some: [JPEG.Metadata] = [
            .jfif(.init()),
            .exif(data: Self.tiff(entries: [Self.orientation(8)])),
        ]
        #expect(some.orientation == .left)
        let written: Bool = some.set(orientation: .up)
        #expect(written)
        #expect(some.orientation == .up)
    }

    /// An EXIF block is attacker-controlled data whose internal offsets point
    /// wherever they like. Every one of these must come back `nil` rather than
    /// trapping, which is what the bounds checks in the walk are for.
    @Test
    func malformedBlocksAreRefused() {
        var cases: [[UInt8]] = [
            [],                                     // empty
            [0x49, 0x49],                           // byte order and nothing else
            [0x49, 0x49, 0x2A, 0x00, 0x08],         // truncated header
            [0x41, 0x42, 0x2A, 0x00, 8, 0, 0, 0],   // no byte order mark
            [0x49, 0x49, 0x00, 0x00, 8, 0, 0, 0],   // wrong magic number
            // A directory offset past the end of the block.
            [0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0x00, 0x00],
            // A directory offset inside the header itself.
            [0x49, 0x49, 0x2A, 0x00, 0x02, 0x00, 0x00, 0x00],
        ]

        // A directory claiming more entries than the block can hold.
        var overrun: [UInt8] = Self.tiff(entries: [Self.orientation(1)])
        overrun[8] = 0xFF
        overrun[9] = 0xFF
        cases.append(overrun)

        // Every truncation of a well-formed block.
        let whole: [UInt8] = Self.tiff(entries: [Self.orientation(6)])
        for length: Int in 0 ..< whole.count {
            cases.append(.init(whole[0 ..< length]))
        }

        for block: [UInt8] in cases {
            var metadata: JPEG.Metadata = .exif(data: block)
            #expect(metadata.orientation == nil, "\(block.count) bytes parsed as an orientation")
            let written: Bool = metadata.set(orientation: .down)
            #expect(!written)
        }
    }

    /// An entry of the right tag but the wrong shape is not an orientation.
    @Test
    func wrongTypeOrCountIsRefused() {
        let wrongType: [UInt8] = Self.tiff(entries: [
            (tag: 0x0112, type: 4, count: 1, value: [6, 0, 0, 0]),
        ])
        #expect(JPEG.Metadata.exif(data: wrongType).orientation == nil)

        // A count above one puts the values at an offset rather than inline,
        // so the four bytes are a pointer and reading them as a value would be
        // wrong.
        let wrongCount: [UInt8] = Self.tiff(entries: [
            (tag: 0x0112, type: 3, count: 2, value: [6, 0, 0, 0]),
        ])
        #expect(JPEG.Metadata.exif(data: wrongCount).orientation == nil)
    }

    /// A value outside 1 through 8 is not an orientation this library knows,
    /// and must not be invented.
    @Test
    func outOfRangeValuesAreRefused() {
        for raw: UInt8 in [0, 9, 200] {
            let block: [UInt8] = Self.tiff(entries: [Self.orientation(raw)])
            #expect(JPEG.Metadata.exif(data: block).orientation == nil)
        }
    }

    /// The end-to-end case: a stream carrying an EXIF orientation decodes,
    /// normalizes losslessly at the spectral tier, and re-encodes saying so.
    @Test
    func normalizesThroughASpectralTransform() throws {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: .y(1, precision: 8),
            process: .baseline,
            width: 16,
            height: 8,
            sampling: [.init(x: 1, y: 1)],
            selectors: [0]
        )
        var values: [UInt16] = .init(repeating: 0, count: 128)
        for y: Int in 0 ..< 8 {
            for x: Int in 0 ..< 16 {
                values[y * 16 + x] = .init(8 * x + y)
            }
        }
        var image: JPEG.Data.Rectangular<JPEG.Common> = .init(layout: layout, values: values)
        image.metadata = [.exif(data: Self.tiff(entries: [Self.orientation(6)]))]

        var stream: [UInt8] = []
        try image.compress(stream: &stream, quality: 100)

        var spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream)
        #expect(spectral.metadata.orientation == .right)

        var upright: JPEG.Data.Spectral<JPEG.Common> = spectral.transformed(
            spectral.metadata.orientation.transform
        )
        let stamped: Bool = upright.set(orientation: .up)
        #expect(stamped)
        #expect(upright.metadata.orientation == .up)
        // A quarter turn exchanges the dimensions.
        #expect(upright.layout.width == 8)
        #expect(upright.layout.height == 16)

        // And it survives being written back out.
        var rewritten: [UInt8] = []
        var tables: JPEG.Tables = .init()
        tables.push(try .standard(.luminance, class: .dc, target: 0))
        tables.push(try .standard(.luminance, class: .ac, target: 0))
        try upright.compress(stream: &rewritten, tables: tables)

        let reread: JPEG.Data.Spectral<JPEG.Common> = try .decompress(rewritten)
        #expect(reread.metadata.orientation == .up)

        // The transform is its own inverse's partner: turning it back gives
        // the original coefficients exactly.
        spectral = upright.transformed(.rotate270)
        for plane: Int in spectral.planes.indices {
            #expect(spectral.planes[plane].blocks.x == 2)
            #expect(spectral.planes[plane].blocks.y == 1)
        }
    }
}

extension JPEG.Data.Spectral {
    /// Records an orientation in this image's metadata.
    ///
    /// Convenience for the normalize-and-restamp pairing, which is the whole
    /// reason to read an orientation at this tier.
    @discardableResult
    mutating func set(orientation: JPEG.Orientation) -> Bool {
        self.metadata.set(orientation: orientation)
    }
}
