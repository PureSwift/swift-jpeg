extension JPEG {
    /// How a stored image is meant to be displayed, as EXIF records it.
    ///
    /// A camera that is turned on its side does not rotate its sensor; it
    /// writes the pixels as they were read and records which way was up. So a
    /// decoder that ignores this shows a great many photographs sideways, and
    /// the fix is exactly one of the eight symmetries this library can already
    /// apply losslessly — see ``transform``.
    ///
    /// The raw values are the tag's own, 1 through 8. The names describe what
    /// has been *done* to the stored image, which is the opposite of what has
    /// to be done to display it.
    public enum Orientation: Int, Sendable, Hashable, CaseIterable {
        /// Stored the right way up.
        case up = 1
        /// Mirrored left to right.
        case upMirrored = 2
        /// Turned upside down.
        case down = 3
        /// Mirrored top to bottom.
        case downMirrored = 4
        /// Reflected across the main diagonal.
        case leftMirrored = 5
        /// Turned a quarter turn counterclockwise.
        case right = 6
        /// Reflected across the antidiagonal.
        case rightMirrored = 7
        /// Turned a quarter turn clockwise.
        case left = 8
    }
}

extension JPEG.Orientation {
    /// The transform that puts this image the right way up.
    ///
    /// Applying it to a spectral image and then setting the orientation to
    /// ``up`` normalizes the image without touching a sample: the transforms
    /// at that tier rearrange exact coefficients. That is the whole reason
    /// this enumeration is worth having in a codec rather than in the caller.
    public var transform: JPEG.Transform {
        switch self {
        case .up:               return .none
        case .upMirrored:       return .horizontalFlip
        case .down:             return .rotate180
        case .downMirrored:     return .verticalFlip
        case .leftMirrored:     return .transpose
        case .right:            return .rotate90
        case .rightMirrored:    return .transverse
        case .left:             return .rotate270
        }
    }
}

/// A reader for the TIFF structure an EXIF segment carries.
///
/// Only as much of TIFF as the orientation tag needs: the header, the byte
/// order it declares, and a walk of the first image file directory. Reading
/// the rest would mean modelling every tag type and the maker notes, which is
/// a second format's problem — the payload stays opaque and this finds one
/// field inside it.
///
/// Every read is bounds checked against the block, because an EXIF block is
/// attacker-controlled data whose internal offsets point wherever they like.
/// A malformed block yields `nil`, never a trap.
struct TIFF {
    /// Whether multi-byte values are little-endian, as `"II"` declares.
    let littleEndian: Bool
    /// The offset of the first image file directory, from the block's start.
    let directory: Int

    /// The orientation tag, `0x0112`.
    static let orientation: UInt16 = 0x0112
    /// The `SHORT` field type, a 16-bit unsigned integer.
    static let short: UInt16 = 3

    /// Reads the eight-byte TIFF header, or returns `nil` if the block does
    /// not open with one.
    init?(_ data: [UInt8]) {
        guard data.count >= 8 else {
            return nil
        }

        switch (data[0], data[1]) {
        case (0x49, 0x49):  self.littleEndian = true
        case (0x4D, 0x4D):  self.littleEndian = false
        default:            return nil
        }

        // The magic number is 42 in the declared byte order, which is what
        // confirms the byte order was read correctly rather than guessed.
        guard Self.short(data, at: 2, littleEndian: self.littleEndian) == 42 else {
            return nil
        }

        let offset: UInt32 = Self.long(data, at: 4, littleEndian: self.littleEndian)
        // A directory must leave room for its own entry count.
        guard offset >= 8, offset <= UInt32(data.count) - 2 else {
            return nil
        }
        self.directory = .init(offset)
    }

    static func short(_ data: [UInt8], at index: Int, littleEndian: Bool) -> UInt16 {
        let bytes: (UInt16, UInt16) = (.init(data[index]), .init(data[index + 1]))
        return littleEndian ? bytes.1 << 8 | bytes.0 : bytes.0 << 8 | bytes.1
    }

    static func long(_ data: [UInt8], at index: Int, littleEndian: Bool) -> UInt32 {
        var value: UInt32 = 0
        for step: Int in 0 ..< 4 {
            let byte: UInt32 = .init(data[index + (littleEndian ? 3 - step : step)])
            value = value << 8 | byte
        }
        return value
    }

    /// The offset of the orientation entry's value field, or `nil` if the
    /// first directory has no usable orientation entry.
    ///
    /// The value rather than the entry, because both reading and writing want
    /// the same four bytes. A `SHORT` of count one is stored inline in that
    /// field rather than at an offset elsewhere — which is what makes writing
    /// one back a two-byte patch rather than a rebuild of the whole block.
    func orientationValue(in data: [UInt8]) -> Int? {
        let count: Int = .init(Self.short(data, at: self.directory, littleEndian: self.littleEndian))
        // Each entry is twelve bytes, and the directory ends with a four-byte
        // link to the next one.
        guard self.directory + 2 + 12 * count + 4 <= data.count else {
            return nil
        }

        for index: Int in 0 ..< count {
            let entry: Int = self.directory + 2 + 12 * index
            guard Self.short(data, at: entry, littleEndian: self.littleEndian)
                    == Self.orientation,
                  Self.short(data, at: entry + 2, littleEndian: self.littleEndian)
                    == Self.short,
                  Self.long(data, at: entry + 4, littleEndian: self.littleEndian) == 1
            else {
                continue
            }
            return entry + 8
        }
        return nil
    }
}

extension JPEG.Metadata {
    /// The orientation this segment records, if it is an EXIF segment that
    /// carries one.
    ///
    /// `nil` covers every way there is not to have one — a segment that is not
    /// EXIF, an EXIF block whose first directory omits the tag, and a block
    /// too malformed to walk. None of those is an error: an image with no
    /// stated orientation is displayed as stored, which is what ``up`` means.
    public var orientation: JPEG.Orientation? {
        guard case .exif(let data) = self,
              let tiff: TIFF = .init(data),
              let value: Int = tiff.orientationValue(in: data)
        else {
            return nil
        }
        return .init(
            rawValue: .init(TIFF.short(data, at: value, littleEndian: tiff.littleEndian))
        )
    }

    /// Records an orientation, replacing the one this segment states.
    ///
    /// -   Returns:
    ///     Whether the value was written. `false` means there was no entry to
    ///     overwrite — this is a patch of an existing field, not an insertion.
    ///     Adding an entry would shift every offset after it in a block whose
    ///     remaining contents this library deliberately does not model, so a
    ///     caller who needs one is better served building the EXIF block
    ///     themselves.
    @discardableResult
    public mutating func set(orientation: JPEG.Orientation) -> Bool {
        guard case .exif(var data) = self,
              let tiff: TIFF = .init(data),
              let value: Int = tiff.orientationValue(in: data)
        else {
            return false
        }

        let raw: UInt16 = .init(truncatingIfNeeded: orientation.rawValue)
        let bytes: (UInt8, UInt8) = (
            .init(truncatingIfNeeded: raw >> 8), .init(truncatingIfNeeded: raw)
        )
        if tiff.littleEndian {
            data[value] = bytes.1
            data[value + 1] = bytes.0
        } else {
            data[value] = bytes.0
            data[value + 1] = bytes.1
        }
        self = .exif(data: data)
        return true
    }
}

extension Array where Element == JPEG.Metadata {
    /// The orientation the first EXIF segment to state one records.
    ///
    /// ``JPEG/Orientation/up`` when nothing states one, rather than `nil`: an
    /// image with no stated orientation is displayed as stored, so a caller
    /// deciding how to display one has no separate case to handle. Reach for
    /// ``JPEG/Metadata/orientation`` on a segment to tell the two apart.
    public var orientation: JPEG.Orientation {
        for segment: JPEG.Metadata in self {
            if let orientation: JPEG.Orientation = segment.orientation {
                return orientation
            }
        }
        return .up
    }

    /// Records an orientation in the first EXIF segment that states one.
    ///
    /// -   Returns:
    ///     Whether it was written, on the same terms as
    ///     ``JPEG/Metadata/set(orientation:)``.
    @discardableResult
    public mutating func set(orientation: JPEG.Orientation) -> Bool {
        for index: Int in self.indices where self[index].orientation != nil {
            return self[index].set(orientation: orientation)
        }
        return false
    }
}
