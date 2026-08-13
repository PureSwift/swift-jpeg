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
        /// Bits not yet forming a whole byte, right-aligned in the low 64.
        ///
        /// Wider than the eight-plus-change the byte emitter needs, and the
        /// width is worth 2.6% of the entropy encoder: 130.0M instructions for a
        /// 32-bit accumulator against 126.6M for this one, on a megapixel image.
        /// A `<<` by a runtime amount has to yield zero when the amount reaches
        /// the type's width, which the shift instruction does not do on its own,
        /// so each one carries a compare and a select — and the compiler
        /// discharges that more cheaply at 64 bits than at 32.
        private var accumulator: UInt64
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
    @inline(__always)
    private mutating func emit(_ byte: UInt8) {
        self.bytes.append(byte)
        if byte == 0xFF {
            self.bytes.append(0x00)
        }
    }

    /// Shifts `count` bits of `value` into the accumulator without emitting.
    ///
    /// The caller is responsible for keeping the accumulator from overflowing,
    /// which means draining it before it can exceed 64 bits. A drain leaves fewer
    /// than 32 bits behind and at most 16 go in per call, so the accumulator
    /// never holds more than 47 and a write cannot overflow it.
    ///
    /// A count of zero is deliberately not a special case: the mask comes out
    /// zero and the shift is by zero, so nothing happens, which is exactly what
    /// magnitude category 0 wants. Branching on it costs more than the no-op it
    /// avoids — 132.0M instructions against 130.0M when this was measured with an
    /// early exit in ``write(_:count:)``, because the branch is checked on every
    /// write and taken on almost none of them.
    @inline(__always)
    private mutating func shift(in value: UInt16, count: Int) {
        let mask: UInt64 = (1 << UInt64(count)) - 1
        self.accumulator = self.accumulator << UInt64(count) | (.init(value) & mask)
        self.count += count
    }

    /// Emits every whole byte the accumulator holds, one at a time.
    ///
    /// The tail case. ``drain()`` handles the bulk four bytes at a time and
    /// leaves fewer than four behind; this is what ``finish()`` uses to get them
    /// out, and what ``drain()`` falls back to for a word that needs stuffing.
    @inline(__always)
    private mutating func drainBytes() {
        while self.count >= 8 {
            self.count -= 8
            self.emit(.init(truncatingIfNeeded: self.accumulator >> UInt64(self.count)))
        }
    }

    /// Emits four bytes at a time while the accumulator holds that many.
    ///
    /// The accumulator is allowed to fill rather than being emptied after every
    /// write, so this runs a quarter as often as a byte-at-a-time drain and the
    /// loop's own bookkeeping is paid a quarter as often.
    ///
    /// What that buys is the stuffing test. A `0xFF` in entropy coded data needs
    /// a zero written after it, which is a branch on every byte — and entropy
    /// coded data almost never reaches `0xFF`, so it is a branch that decides
    /// nothing. Testing four bytes at once instead:
    /// `(~w - 0x01010101) & w & 0x80808080` is nonzero exactly when some byte of
    /// `w` is `0xFF`. Only then does this fall back to emitting one at a time.
    ///
    /// The test is exact in both directions, checked against a byte-by-byte
    /// reference over every value of every byte position and three million random
    /// words. A false positive would only be slow; a false negative would write
    /// an unescaped marker into the stream.
    ///
    /// The four bytes go out as four appends, not as one bulk copy. Copying them
    /// with `append(contentsOf:)` over the word's bytes was tried, since it looks
    /// like it should replace four uniqueness checks with one, and it measured
    /// *worse* — 157.2M instructions against 150.9M — because that call goes
    /// through the generic sequence path and spends about 110 instructions moving
    /// four bytes.
    @inline(__always)
    private mutating func drain() {
        while self.count >= 32 {
            self.count -= 32
            let word: UInt32 = .init(
                truncatingIfNeeded: self.accumulator >> UInt64(self.count)
            )
            guard (~word &- 0x0101_0101) & word & 0x8080_8080 == 0 else {
                self.emit(.init(truncatingIfNeeded: word >> 24))
                self.emit(.init(truncatingIfNeeded: word >> 16))
                self.emit(.init(truncatingIfNeeded: word >> 8))
                self.emit(.init(truncatingIfNeeded: word))
                continue
            }
            self.bytes.append(.init(truncatingIfNeeded: word >> 24))
            self.bytes.append(.init(truncatingIfNeeded: word >> 16))
            self.bytes.append(.init(truncatingIfNeeded: word >> 8))
            self.bytes.append(.init(truncatingIfNeeded: word))
        }
    }

    /// Writes the low `count` bits of `value`, most significant first.
    ///
    /// Always inlined, because the call is the expensive part. An entropy coder
    /// calls this about 2.4 million times per megapixel image, and out of line it
    /// spent eight instructions per call on prologue and epilogue for a body of
    /// about eighteen.
    ///
    /// Writing a Huffman code and the amplitude that follows it as *one* call was
    /// tried, since the two are never separated and that would halve the call
    /// count. It measured 131.1M instructions against 126.6M for the pair of
    /// calls — worse, not better. The accumulator is wide enough to hold both, so
    /// the cause is not spilling; the likelier one is that inlining a
    /// two-field-plus-drain body at every symbol site made the encoding loop big
    /// enough to lose more elsewhere than the calls cost.
    ///
    /// -   Parameter count:
    ///     A bit count, at most 16.
    @inline(__always)
    public mutating func write(_ value: UInt16, count: Int) {
        precondition(count <= 16, "cannot write more than 16 bits at once")
        self.shift(in: value, count: count)
        self.drain()
    }

    /// Pads to a byte boundary with one bits and returns the finished data.
    ///
    /// One bits, not zeros. T.81 §F.1.2.3 specifies the padding that way so
    /// that the partial byte cannot be mistaken for the start of a valid
    /// Huffman code — the standard tables leave the all-ones code unassigned
    /// precisely so a decoder reading into the padding fails loudly.
    public mutating func finish() -> [UInt8] {
        // Up to 31 bits may be waiting, not just the up-to-7 of a writer that
        // emptied itself every write, so the padding is to the next byte boundary
        // rather than to the first one.
        let remainder: Int = self.count & 7
        if remainder > 0 {
            let padding: Int = 8 - remainder
            self.write(.init((1 << UInt16(padding)) - 1), count: padding)
        }
        self.drainBytes()
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
    @inline(__always)
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
