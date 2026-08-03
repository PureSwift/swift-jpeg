extension JPEG.Table {
    /// A Huffman table.
    ///
    /// JPEG does not transmit the codes themselves, only how many codes there
    /// are of each length and which symbols they map to. The codes are then
    /// reconstructed canonically: shortest first, and in increasing numeric
    /// order within a length. That makes decoding possible without storing a
    /// tree — see ``symbol(from:)``.
    public struct Huffman: Sendable {
        /// A Huffman table slot.
        ///
        /// DC and AC tables occupy separate slot spaces, so a stream may define
        /// up to four of each. Baseline frames are limited to slots 0 and 1.
        public struct Key: Sendable, Hashable, Comparable, CustomStringConvertible {
            /// The slot index, 0 through 3.
            public let value: Int

            public init(_ value: Int) {
                self.value = value
            }

            public static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.value < rhs.value
            }

            public var description: String {
                "\(self.value)"
            }
        }

        /// Which coefficients a table codes.
        public enum Class: Sendable, Hashable, CustomStringConvertible {
            /// Codes DC coefficient magnitude categories.
            case dc
            /// Codes AC run-length and magnitude category pairs.
            case ac

            public var description: String {
                switch self {
                case .dc:   return "DC"
                case .ac:   return "AC"
                }
            }
        }

        /// The symbols, ordered by code length and then by code value.
        let values: [UInt8]
        /// How many codes have each length from 1 through 16.
        ///
        /// Kept because writing the table back out needs exactly what was read
        /// in — a `DHT` segment transmits the counts and symbols, never the
        /// codes — and deriving them back from the decode tables would be work
        /// to undo work.
        let counts: [Int]
        /// The numerically smallest code of each length, indexed by length.
        ///
        /// Index 0 is unused so that a length can index directly.
        private let mincode: [Int]
        /// The numerically largest code of each length, or `-1` if no code has
        /// that length.
        private let maxcode: [Int]
        /// Where each length's symbols begin in ``values``.
        private let offset: [Int]

        /// A lookup keyed on the next eight bits, resolving any code that
        /// short in one step.
        ///
        /// Each entry packs the symbol in its high byte and the code length in
        /// its low; a length of zero means the code is longer than eight bits
        /// and the slow path has to walk it.
        ///
        /// Eight bits is the useful width because canonical codes are assigned
        /// shortest first, so the common symbols are the short ones — in a
        /// typical image the overwhelming majority of codes resolve here, and
        /// the table costs 512 bytes.
        private let lookup: [UInt16]

        /// The slot this table was defined in.
        public let target: Key
        /// Whether this table codes DC or AC coefficients.
        public let `class`: Class
    }
}

extension JPEG.Table.Huffman.Key: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension JPEG.Table.Huffman {
    /// Builds a table from the per-length code counts and the symbol list.
    ///
    /// This is the canonical code construction of T.81 Annex C. Codes are
    /// assigned in increasing length, incrementing within a length and shifting
    /// left when the length increases, which makes every code a prefix-free
    /// extension of the ones before it.
    ///
    /// -   Parameters:
    ///     -   counts: How many codes have each length from 1 through 16.
    ///     -   values: The symbols, in code order. Must be `counts.reduce(0, +)`
    ///         elements long.
    init(counts: [Int], values: [UInt8], target: Key, class: Class) throws {
        precondition(counts.count == 16)

        guard values.count == counts.reduce(0, +) else {
            throw JPEG.ParsingError.invalidHuffmanTable
        }

        var mincode: [Int] = .init(repeating: 0, count: 17)
        var maxcode: [Int] = .init(repeating: -1, count: 17)
        var offset: [Int] = .init(repeating: 0, count: 17)

        var code: Int = 0
        var index: Int = 0
        for length: Int in 1 ... 16 {
            let count: Int = counts[length - 1]
            offset[length] = index
            mincode[length] = code

            if count > 0 {
                maxcode[length] = code + count - 1
                code += count
                index += count
            }

            // A code of length `length` must remain a valid prefix: once more
            // codes have been handed out than the length can address, the code
            // space is overfull and the table is not decodable.
            guard code <= 1 << length else {
                throw JPEG.ParsingError.invalidHuffmanTable
            }
            code <<= 1
        }

        // Fill the fast path. Every code of length n claims the 2^(8-n)
        // entries that begin with it, because the bits after it belong to
        // whatever follows and cannot change which symbol this is.
        var lookup: [UInt16] = .init(repeating: 0, count: 256)
        var fast: Int = 0
        var symbol: Int = 0
        for length: Int in 1 ... 8 {
            for _: Int in 0 ..< counts[length - 1] {
                let code: Int = mincode[length] + (symbol - offset[length])
                let start: Int = code << (8 - length)
                for entry: Int in start ..< start + (1 << (8 - length)) {
                    lookup[entry] = .init(values[symbol]) << 8 | .init(truncatingIfNeeded: length)
                }
                symbol += 1
                fast += 1
            }
        }
        _ = fast

        self.values = values
        self.counts = counts
        self.lookup = lookup
        self.mincode = mincode
        self.maxcode = maxcode
        self.offset = offset
        self.target = target
        self.class = `class`
    }

    /// Parses the body of a `DHT` segment.
    ///
    /// One segment may define several tables back to back, each prefixed by a
    /// byte holding the table class in its high nibble and the destination slot
    /// in its low nibble, then sixteen length counts, then the symbols.
    ///
    /// -   Parameter data:
    ///     The segment body, excluding the length field.
    public static func parse(_ data: [UInt8]) throws -> [Self] {
        var tables: [Self] = []
        var base: Int = 0

        while base < data.count {
            guard base + 17 <= data.count else {
                throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                    .huffman,
                    count: data.count,
                    expected: (base + 17) ... (base + 17)
                )
            }

            let byte: UInt8 = data[base]

            let `class`: Class
            switch byte >> 4 {
            case 0:     `class` = .dc
            case 1:     `class` = .ac
            default:    throw JPEG.ParsingError.invalidHuffmanTypeCode(byte >> 4)
            }

            let slot: UInt8 = byte & 0x0F
            guard slot < 4 else {
                throw JPEG.ParsingError.invalidHuffmanTargetCode(slot)
            }

            let counts: [Int] = data[base + 1 ..< base + 17].map(Int.init)
            let total: Int = counts.reduce(0, +)
            guard base + 17 + total <= data.count else {
                throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                    .huffman,
                    count: data.count,
                    expected: (base + 17 + total) ... (base + 17 + total)
                )
            }

            tables.append(
                try .init(
                    counts: counts,
                    values: .init(data[base + 17 ..< base + 17 + total]),
                    target: .init(.init(slot)),
                    class: `class`
                )
            )
            base += 17 + total
        }

        return tables
    }
}

extension JPEG.Table.Huffman {
    /// Reads one symbol from the bit reader.
    ///
    /// Implements the decoding procedure of T.81 Figure F.16. Bits are consumed
    /// one at a time, accumulating a candidate code, until the code falls
    /// within the range of codes of the current length. Because the codes are
    /// canonical, a code's position within that range is also its symbol's
    /// position in ``values``, so no tree traversal is needed.
    ///
    /// Codes of eight bits or fewer resolve from ``lookup`` in one step, which
    /// is nearly all of them: canonical assignment gives the shortest codes to
    /// the commonest symbols. Longer ones fall back to walking the bits, which
    /// is correct but costs a peek per bit.
    public func symbol(from bits: inout JPEG.Bitstream) throws -> UInt8 {
        let entry: UInt16 = self.lookup[.init(bits.peek(8))]
        let length: Int = .init(entry & 0xFF)
        if length > 0 {
            bits.advance(length)
            return .init(truncatingIfNeeded: entry >> 8)
        }

        var code: Int = 0
        for length: Int in 1 ... 16 {
            code = code << 1 | .init(bits.read(1))

            if code <= self.maxcode[length] {
                return self.values[self.offset[length] + code - self.mincode[length]]
            }
        }
        throw JPEG.DecodingError.invalidEntropyCodedSymbol
    }
}
