extension JPEG {
    /// A namespace for byte-level input and output.
    ///
    /// The engine performs no IO of its own. It reads through ``Source`` and
    /// writes through ``Destination``, which is what keeps this module free of
    /// imports and therefore usable from Embedded Swift and from behind a C
    /// ABI, where the buffer is owned by the caller.
    public enum Bytestream {
    }
}

extension JPEG.Bytestream {
    /// A source of bytes.
    ///
    /// Conformances are expected to be consuming: successive calls return
    /// successive bytes, and a call that cannot be satisfied in full returns
    /// `nil` without consuming anything.
    public protocol Source {
        /// Reads exactly `count` bytes, or returns `nil` if fewer remain.
        ///
        /// Returning a short buffer is not permitted — a caller that receives a
        /// non-`nil` result relies on it having exactly the requested length.
        mutating func read(count: Int) -> [UInt8]?
    }

    /// A sink for bytes.
    public protocol Destination {
        /// Writes the given bytes, or returns `nil` if the write failed.
        mutating func write(_ bytes: [UInt8]) -> Void?
    }
}

extension JPEG.Bytestream.Source {
    /// Reads a single byte.
    private mutating func byte() -> UInt8? {
        self.read(count: 1)?[0]
    }

    /// Reads the code byte of the next marker, skipping any fill bytes.
    ///
    /// A marker is `0xFF` followed by a non-zero code. T.81 §B.1.1.2 allows any
    /// number of additional `0xFF` bytes to precede the code as padding, so a
    /// run of them is legal and is consumed here.
    ///
    /// -   Parameter first:
    ///     The byte that introduced this marker, already read by the caller.
    private mutating func markerCode(after first: UInt8) throws -> JPEG.Marker {
        var byte: UInt8 = first
        // Consume the fill run. The last 0xFF is the marker prefix proper.
        while byte == 0xFF {
            guard let next: UInt8 = self.byte() else {
                throw JPEG.LexingError.truncatedMarkerSegmentType
            }
            byte = next
        }

        guard let marker: JPEG.Marker = .init(code: byte) else {
            throw JPEG.LexingError.invalidMarkerSegmentPrefix(byte)
        }
        return marker
    }

    /// Reads the length-prefixed body of a marker segment.
    ///
    /// The two-byte length is big-endian and counts itself, so the body is two
    /// bytes shorter than the field states.
    private mutating func body() throws -> [UInt8] {
        guard let header: [UInt8] = self.read(count: 2) else {
            throw JPEG.LexingError.truncatedMarkerSegmentHeader
        }

        let length: Int = .init(header[0]) << 8 | .init(header[1])
        guard length >= 2 else {
            throw JPEG.LexingError.invalidMarkerSegmentLength(length)
        }

        let count: Int = length - 2
        guard count > 0 else {
            return []
        }
        guard let body: [UInt8] = self.read(count: count) else {
            throw JPEG.LexingError.truncatedMarkerSegmentBody(expected: count)
        }
        return body
    }

    /// Reads the next marker segment.
    ///
    /// Throws if entropy coded data is encountered, since a caller using this
    /// method is not expecting any. Use ``segment(prefix:)`` after a scan
    /// header instead.
    public mutating func segment() throws -> (JPEG.Marker, [UInt8]) {
        let (ecs, segment): ([UInt8], (JPEG.Marker, [UInt8])) = try self.segment(prefix: false)
        // `prefix: false` discards rather than collects, so this is a
        // consistency check on the lexer, not on the input.
        assert(ecs.isEmpty)
        return segment
    }

    /// Reads the next marker segment, optionally collecting the entropy coded
    /// data that precedes it.
    ///
    /// Entropy coded data is not length prefixed: it runs until the next
    /// marker. Two byte sequences inside it are *not* segment boundaries —
    /// `FF 00`, which encodes a literal `0xFF`, and `FF D0` through `FF D7`,
    /// the restart markers.
    ///
    /// Both are collected **verbatim**, stuffing included. Removing the stuffed
    /// `0x00` here would be lossy: a literal `0xFF` followed by a data byte
    /// that happens to be `0xD0` would then be indistinguishable from a restart
    /// marker. Unstuffing is the bit reader's job, where the raw bytes are
    /// still unambiguous.
    ///
    /// -   Parameter prefix:
    ///     Whether entropy coded data is expected before the next marker. When
    ///     `false`, any bytes found outside a segment are discarded, which is
    ///     how trailing garbage between segments is tolerated.
    ///
    /// -   Returns:
    ///     The entropy coded data, empty unless `prefix` was `true`, and the
    ///     marker segment that terminated it.
    public mutating func segment(prefix: Bool) throws -> ([UInt8], (JPEG.Marker, [UInt8])) {
        var ecs: [UInt8] = []

        scan:
        while true {
            guard let byte: UInt8 = self.byte() else {
                throw prefix
                    ? JPEG.LexingError.truncatedEntropyCodedSegment
                    : JPEG.LexingError.truncatedMarkerSegmentType
            }

            guard byte == 0xFF else {
                if prefix {
                    ecs.append(byte)
                }
                continue scan
            }

            // 0xFF: either a stuffed literal, a fill byte, or a real marker.
            guard let next: UInt8 = self.byte() else {
                throw prefix
                    ? JPEG.LexingError.truncatedEntropyCodedSegment
                    : JPEG.LexingError.truncatedMarkerSegmentType
            }

            switch next {
            case 0x00:
                // A stuffed 0xFF. Only meaningful inside entropy coded data.
                if prefix {
                    ecs.append(0xFF)
                    ecs.append(0x00)
                }
                continue scan

            case 0xD0 ... 0xD7 where prefix:
                // A restart marker. It belongs to the entropy coded segment;
                // the bit reader uses it to resynchronize and to validate the
                // restart phase, so both bytes are preserved.
                ecs.append(0xFF)
                ecs.append(next)
                continue scan

            default:
                let marker: JPEG.Marker = try self.markerCode(after: next)
                guard marker.hasPayload else {
                    return (ecs, (marker, []))
                }
                return (ecs, (marker, try self.body()))
            }
        }
    }

    /// Reads the start-of-image marker that must open the stream.
    public mutating func start() throws {
        let (marker, _): (JPEG.Marker, [UInt8]) = try self.segment()
        guard case .start = marker else {
            throw JPEG.LexingError.invalidStartOfImage(marker)
        }
    }
}

extension Array: JPEG.Bytestream.Source where Element == UInt8 {
    /// Reads from the front of this array, removing what it reads.
    ///
    /// Provided so that an in-memory image can be decoded without a platform
    /// layer. The cost is quadratic in the number of reads if the array is
    /// large; wrap the buffer in a cursor type if that matters.
    public mutating func read(count: Int) -> [UInt8]? {
        guard self.count >= count else {
            return nil
        }
        defer {
            self.removeFirst(count)
        }
        return .init(self.prefix(count))
    }
}
