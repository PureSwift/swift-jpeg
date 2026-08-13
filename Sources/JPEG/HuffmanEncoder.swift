extension JPEG.Table.Huffman {
    /// A symbol-to-code lookup, built from a table's canonical assignment.
    ///
    /// Decoding walks bits until a code resolves, so it needs the code ranges;
    /// encoding already knows the symbol and needs the opposite mapping. Both
    /// come from the same construction, so building this from a table cannot
    /// disagree with what a decoder would reconstruct — which is the property
    /// that makes an encode-decode round trip meaningful as a test.
    public final class Encoder {
        /// The code and its length for each symbol, indexed by symbol value.
        ///
        /// Packed rather than held as two arrays: the length in the high 16 bits,
        /// the code in the low 16. Writing a symbol needs both, and one indexed
        /// access costs one bounds check where two cost two. A length of zero —
        /// the table assigns this symbol no code — falls out of the same load.
        private let entries: [UInt32]
        /// Where symbols are tallied instead of written, when this encoder is
        /// gathering statistics for an optimal table.
        private let counter: Counter?

        init(entries: [UInt32], counter: Counter? = nil) {
            self.entries = entries
            self.counter = counter
        }

        /// Packs one symbol's code and length into an entry.
        static func entry(code: UInt16, length: Int) -> UInt32 {
            .init(length) << 16 | .init(code)
        }

        /// An encoder that counts symbols rather than emitting them.
        public static func counting(into counter: Counter) -> Self {
            .init(entries: .init(repeating: 0, count: 256), counter: counter)
        }
    }

    /// Builds the symbol-to-code lookup for this table.
    public func encoder() -> Encoder {
        var entries: [UInt32] = .init(repeating: 0, count: 256)

        var code: Int = 0
        var index: Int = 0
        for length: Int in 1 ... 16 {
            for _: Int in 0 ..< self.counts[length - 1] {
                let symbol: Int = .init(self.values[index])
                entries[symbol] = Encoder.entry(
                    code: .init(truncatingIfNeeded: code), length: length
                )
                code += 1
                index += 1
            }
            code <<= 1
        }

        return .init(entries: entries)
    }
}

extension JPEG.Table.Huffman.Encoder {
    /// Whether this table assigns a code to the given symbol.
    public func encodes(_ symbol: UInt8) -> Bool {
        self.entries[.init(symbol)] >> 16 > 0
    }

    /// Writes the code for one symbol.
    ///
    /// Throws when the table assigns the symbol no code. Silently skipping it
    /// would desynchronize everything after it, and the failure would surface
    /// as a corrupt image rather than as an error — which is exactly what
    /// happened here with 12-bit samples, whose magnitude categories run past
    /// the eleven the Annex K tables cover.
    @inline(__always)
    public func encode(_ symbol: UInt8, to bits: inout JPEG.BitstreamWriter) throws(JPEG.Failure) {
        if let counter: Counter = self.counter {
            counter.record(symbol)
            return
        }

        let entry: UInt32 = self.entries[.init(symbol)]
        let length: Int = .init(entry >> 16)
        guard length > 0 else {
            throw .encoding(.unencodableSymbol(symbol))
        }
        bits.write(.init(truncatingIfNeeded: entry), count: length)
    }
}

extension JPEG.Table.Huffman {
    /// Serializes this table as a `DHT` segment body.
    ///
    /// The counts and symbols go out exactly as they came in. A `DHT` segment
    /// never transmits the codes themselves — both ends derive them from the
    /// same canonical rule.
    public func serialized() -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(17 + self.values.count)

        let `class`: UInt8 = self.class == .dc ? 0 : 1
        data.append(`class` << 4 | .init(truncatingIfNeeded: self.target.value))
        data.append(contentsOf: self.counts.map { UInt8(truncatingIfNeeded: $0) })
        data.append(contentsOf: self.values)

        return data
    }
}

extension JPEG.Table.Quantization {
    /// Serializes this table as a `DQT` segment body.
    ///
    /// Factors are written back in zigzag order, which is how they arrive and
    /// the reverse of the un-zigzagging done at parse time.
    public func serialized() -> [UInt8] {
        var data: [UInt8] = []
        let wide: Bool = self.precision == .uint16
        data.reserveCapacity(1 + (wide ? 128 : 64))

        data.append((wide ? 1 : 0) << 4 | .init(truncatingIfNeeded: self.target.value))
        for z: Int in 0 ..< 64 {
            let factor: UInt16 = self.factors[JPEG.zigzag[z]]
            if wide {
                data.append(.init(truncatingIfNeeded: factor >> 8))
            }
            data.append(.init(truncatingIfNeeded: factor))
        }

        return data
    }
}
