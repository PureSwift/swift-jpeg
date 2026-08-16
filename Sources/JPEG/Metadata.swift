extension JPEG {
    /// A marker segment the codec carries but does not act on.
    ///
    /// JPEG reserves the application segments and the comment segment for
    /// information *about* the image — what its components mean, where it was
    /// taken, what wrote it — none of which affects a single coefficient. The
    /// decoder collects them in stream order so nothing is lost, and the
    /// encoder writes them back out; only the JFIF segment is given structure,
    /// because it is the one whose fields this library's callers actually ask
    /// for.
    ///
    /// Parsing is deliberately non-throwing. An application segment that fails
    /// to parse as what its number suggests is not a malformed image — it is a
    /// segment following some other convention, and the right response is to
    /// keep its bytes, not to reject the file.
    public enum Metadata: Sendable {
        /// A JFIF segment — `APP0` opening with `"JFIF\0"`.
        case jfif(JFIF)
        /// An EXIF segment — `APP1` opening with `"Exif\0\0"`.
        ///
        /// The payload is the TIFF structure after the six signature bytes,
        /// kept opaque: EXIF is a container format of its own, and the codec's
        /// job ends at carrying it intact.
        case exif(data: [UInt8])
        /// An application segment with no recognized structure.
        ///
        /// The payload is the whole segment body, so it serializes back
        /// byte-identically.
        case application(Int, data: [UInt8])
        /// A comment segment — `COM`.
        case comment(data: [UInt8])
    }

    /// The contents of a JFIF `APP0` segment.
    ///
    /// JFIF is what makes three components mean YCbCr rather than whatever the
    /// encoder felt like: a conformance layer over T.81 that fixes the
    /// colorspace, the component order, and adds a pixel density. The density
    /// is the only field with information in it — the rest is versioning and
    /// an optional thumbnail nobody has written since the nineties.
    public struct JFIF: Sendable {
        /// The unit the density is expressed in, or `nil` if the density is
        /// only an aspect ratio.
        ///
        /// `nil` models the segment's unit code 0 — the densities give the
        /// pixel shape but no absolute scale, which is what nearly every
        /// encoder writes.
        public enum Unit: Sendable {
            /// Pixels per inch — unit code 1.
            case inches
            /// Pixels per centimeter — unit code 2.
            case centimeters
        }

        /// The JFIF version, major then minor. 1.02 is current and has been
        /// since 1992.
        public var version: (major: Int, minor: Int)
        /// The pixel density, horizontal then vertical, in ``unit``s.
        public var density: (x: Int, y: Int)
        /// What ``density`` is measured in, or `nil` for a bare aspect ratio.
        public var unit: Unit?
        /// The embedded RGB thumbnail: its size in pixels and its samples,
        /// three bytes per pixel. Almost always empty.
        public var thumbnail: (x: Int, y: Int, data: [UInt8])

        public init(
            version: (major: Int, minor: Int) = (1, 2),
            density: (x: Int, y: Int) = (1, 1),
            unit: Unit? = nil,
            thumbnail: (x: Int, y: Int, data: [UInt8]) = (0, 0, [])
        ) {
            self.version = version
            self.density = density
            self.unit = unit
            self.thumbnail = thumbnail
        }
    }
}

extension JPEG.JFIF {
    /// The signature an `APP0` segment must open with to be JFIF: `"JFIF"` and
    /// a terminator.
    static let signature: [UInt8] = [0x4A, 0x46, 0x49, 0x46, 0x00]

    /// Parses an `APP0` segment body, or returns `nil` if it is not JFIF.
    ///
    /// `nil` rather than an error because `APP0` is not reserved — JFXX
    /// extension segments and vendor segments live there too, and a body that
    /// is not JFIF is another convention's segment, not a defect in the image.
    /// A body that opens with the signature but is shorter than the fixed
    /// fields is treated the same way: kept as an opaque segment rather than
    /// failing a decode that does not otherwise need it.
    public static func parse(_ data: [UInt8]) -> Self? {
        guard data.count >= 14, data[0 ..< 5].elementsEqual(signature) else {
            return nil
        }

        let unit: Unit?
        switch data[7] {
        case 1:     unit = .inches
        case 2:     unit = .centimeters
        default:    unit = nil
        }

        let thumbnail: (x: Int, y: Int) = (x: .init(data[12]), y: .init(data[13]))
        // A body shorter than its declared thumbnail keeps what is there; the
        // segment's own length field already bounded `data`.
        let samples: Int = Swift.min(3 * thumbnail.x * thumbnail.y, data.count - 14)

        return .init(
            version: (major: .init(data[5]), minor: .init(data[6])),
            density: (
                x: .init(data[8]) << 8 | .init(data[9]),
                y: .init(data[10]) << 8 | .init(data[11])
            ),
            unit: unit,
            thumbnail: (
                x: thumbnail.x,
                y: thumbnail.y,
                data: .init(data[14 ..< 14 + samples])
            )
        )
    }

    /// Serializes this segment as an `APP0` body.
    public func serialized() -> [UInt8] {
        var data: [UInt8] = Self.signature
        data.reserveCapacity(14 + self.thumbnail.data.count)

        data.append(.init(truncatingIfNeeded: self.version.major))
        data.append(.init(truncatingIfNeeded: self.version.minor))

        switch self.unit {
        case nil:               data.append(0)
        case .inches?:          data.append(1)
        case .centimeters?:     data.append(2)
        }

        data.append(.init(truncatingIfNeeded: self.density.x >> 8))
        data.append(.init(truncatingIfNeeded: self.density.x))
        data.append(.init(truncatingIfNeeded: self.density.y >> 8))
        data.append(.init(truncatingIfNeeded: self.density.y))

        data.append(.init(truncatingIfNeeded: self.thumbnail.x))
        data.append(.init(truncatingIfNeeded: self.thumbnail.y))
        data.append(contentsOf: self.thumbnail.data)

        return data
    }
}

extension JPEG.Metadata {
    /// The signature an `APP1` segment opens with when it carries EXIF:
    /// `"Exif"` and two terminators.
    static let exifSignature: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]

    /// Classifies an application segment body by its number and signature.
    ///
    /// Anything unrecognized comes back as ``application(_:data:)`` with its
    /// body intact, so classification never loses information — parsing and
    /// serializing every segment of a stream reproduces the stream.
    public static func parse(application n: Int, data: [UInt8]) -> Self {
        switch n {
        case 0:
            guard let jfif: JPEG.JFIF = .parse(data) else {
                return .application(n, data: data)
            }
            return .jfif(jfif)
        case 1:
            guard data.count >= exifSignature.count,
                  data[0 ..< exifSignature.count].elementsEqual(exifSignature)
            else {
                return .application(n, data: data)
            }
            return .exif(data: .init(data[exifSignature.count...]))
        default:
            return .application(n, data: data)
        }
    }

    /// The marker and body this metadata serializes to.
    public var segment: (marker: JPEG.Marker, body: [UInt8]) {
        switch self {
        case .jfif(let jfif):
            return (marker: .application(0), body: jfif.serialized())
        case .exif(let data):
            return (marker: .application(1), body: Self.exifSignature + data)
        case .application(let n, let data):
            return (marker: .application(n), body: data)
        case .comment(let data):
            return (marker: .comment, body: data)
        }
    }
}
