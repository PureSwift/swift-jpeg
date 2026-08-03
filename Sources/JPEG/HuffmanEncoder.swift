extension JPEG.Table.Huffman {
    /// A symbol-to-code lookup, built from a table's canonical assignment.
    ///
    /// Decoding walks bits until a code resolves, so it needs the code ranges;
    /// encoding already knows the symbol and needs the opposite mapping. Both
    /// come from the same construction, so building this from a table cannot
    /// disagree with what a decoder would reconstruct — which is the property
    /// that makes an encode-decode round trip meaningful as a test.
    public struct Encoder {
        /// The code for each symbol, indexed by symbol value.
        private let codes: [UInt16]
        /// The code length for each symbol, or 0 if the table does not assign
        /// one.
        private let lengths: [Int]
        /// Where symbols are tallied instead of written, when this encoder is
        /// gathering statistics for an optimal table.
        private let counter: Counter?

        init(codes: [UInt16], lengths: [Int], counter: Counter? = nil) {
            self.codes = codes
            self.lengths = lengths
            self.counter = counter
        }

        /// An encoder that counts symbols rather than emitting them.
        public static func counting(into counter: Counter) -> Self {
            .init(
                codes: .init(repeating: 0, count: 256),
                lengths: .init(repeating: 0, count: 256),
                counter: counter
            )
        }
    }

    /// Builds the symbol-to-code lookup for this table.
    public func encoder() -> Encoder {
        var codes: [UInt16] = .init(repeating: 0, count: 256)
        var lengths: [Int] = .init(repeating: 0, count: 256)

        var code: Int = 0
        var index: Int = 0
        for length: Int in 1 ... 16 {
            for _: Int in 0 ..< self.counts[length - 1] {
                let symbol: Int = .init(self.values[index])
                codes[symbol] = .init(truncatingIfNeeded: code)
                lengths[symbol] = length
                code += 1
                index += 1
            }
            code <<= 1
        }

        return .init(codes: codes, lengths: lengths)
    }
}

extension JPEG.Table.Huffman.Encoder {
    /// Whether this table assigns a code to the given symbol.
    public func encodes(_ symbol: UInt8) -> Bool {
        self.lengths[.init(symbol)] > 0
    }

    /// Writes the code for one symbol.
    ///
    /// Throws when the table assigns the symbol no code. Silently skipping it
    /// would desynchronize everything after it, and the failure would surface
    /// as a corrupt image rather than as an error — which is exactly what
    /// happened here with 12-bit samples, whose magnitude categories run past
    /// the eleven the Annex K tables cover.
    public func encode(_ symbol: UInt8, to bits: inout JPEG.BitstreamWriter) throws(JPEG.Failure) {
        if let counter: Counter = self.counter {
            counter.record(symbol)
            return
        }

        let index: Int = .init(symbol)
        guard self.lengths[index] > 0 else {
            throw .encoding(.unencodableSymbol(symbol))
        }
        bits.write(self.codes[index], count: self.lengths[index])
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
