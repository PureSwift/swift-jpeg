extension JPEG {
    /// A most-significant-bit-first writer for entropy coded data.
    ///
    /// The mirror of ``Bitstream``, and it takes on that type's other
    /// responsibility too: byte stuffing is applied here, as bytes are emitted,
    /// rather than in a later pass. Doing it later would mean scanning the
    /// output for `0xFF` bytes that the bit packing happened to produce, which
    /// is both slower and easy to get wrong at a buffer boundary.
    public struct BitstreamWriter: Sendable {
        /// The bytes written so far, stuffing included.
        public private(set) var bytes: [UInt8]
        /// Bits not yet forming a whole byte, left-aligned in the low 32.
        private var accumulator: UInt32
        /// How many bits ``accumulator`` holds.
        private var count: Int

        public init() {
            self.bytes = []
            self.accumulator = 0
            self.count = 0
        }
    }
}

extension JPEG.BitstreamWriter {
    /// Appends one byte, stuffing a zero after `0xFF`.
    ///
    /// A literal `0xFF` in entropy coded data would otherwise be
    /// indistinguishable from the start of a marker, so the standard requires
    /// the following `0x00`. A decoder removes it again on the way in.
    private mutating func emit(_ byte: UInt8) {
        self.bytes.append(byte)
        if byte == 0xFF {
            self.bytes.append(0x00)
        }
    }

    /// Writes the low `count` bits of `value`, most significant first.
    ///
    /// -   Parameter count:
    ///     A bit count, at most 16.
    public mutating func write(_ value: UInt16, count: Int) {
        precondition(count <= 16, "cannot write more than 16 bits at once")
        guard count > 0 else {
            return
        }

        let mask: UInt32 = (1 << UInt32(count)) - 1
        self.accumulator = self.accumulator << UInt32(count) | (.init(value) & mask)
        self.count += count

        while self.count >= 8 {
            self.count -= 8
            self.emit(.init(truncatingIfNeeded: self.accumulator >> UInt32(self.count)))
        }
    }

    /// Pads to a byte boundary with one bits and returns the finished data.
    ///
    /// One bits, not zeros. T.81 §F.1.2.3 specifies the padding that way so
    /// that the partial byte cannot be mistaken for the start of a valid
    /// Huffman code — the standard tables leave the all-ones code unassigned
    /// precisely so a decoder reading into the padding fails loudly.
    public mutating func finish() -> [UInt8] {
        if self.count > 0 {
            let padding: Int = 8 - self.count
            self.write(.init((1 << UInt16(padding)) - 1), count: padding)
        }
        defer {
            self.bytes = []
            self.accumulator = 0
            self.count = 0
        }
        return self.bytes
    }
}

extension JPEG.BitstreamWriter {
    /// Splits a signed coefficient into the magnitude category and the bits
    /// that encode it.
    ///
    /// The inverse of ``Bitstream/amplitude(category:)``. A value needs as many
    /// bits as its magnitude occupies; negative values are stored offset so the
    /// leading bit comes out zero, which is what lets a decoder recover the
    /// sign without a separate flag.
    ///
    /// -   Returns:
    ///     The category, 0 through 16, and the bits to write. Category 0
    ///     encodes zero and writes nothing.
    public static func amplitude(of value: Int) -> (category: Int, bits: UInt16) {
        guard value != 0 else {
            return (category: 0, bits: 0)
        }

        let magnitude: Int = abs(value)
        let category: Int = Int.bitWidth - magnitude.leadingZeroBitCount

        if value > 0 {
            return (category: category, bits: .init(truncatingIfNeeded: value))
        } else {
            return (
                category: category,
                bits: .init(truncatingIfNeeded: value + (1 << category) - 1)
            )
        }
    }
}
