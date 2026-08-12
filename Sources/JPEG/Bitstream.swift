extension JPEG {
    /// A most-significant-bit-first reader over one restart interval of entropy
    /// coded data.
    ///
    /// Huffman codes are not byte aligned, so decoding is a matter of peeking a
    /// window of bits, matching the longest code that fits, and advancing by
    /// that code's length. This type provides that window; it does not know
    /// what the bits mean.
    ///
    /// Construct one from a single interval — use ``intervals(of:restartInterval:)``
    /// to split a scan's entropy coded data first, since restart markers are
    /// byte aligned boundaries and must not be read as data.
    public struct Bitstream: Sendable {
        /// The interval's data, with stuffed `0x00` bytes removed.
        private let bytes: [UInt8]
        /// The read position, in bits from the start of ``bytes``.
        public private(set) var bit: Int

        /// Creates a bit reader over one restart interval, removing byte
        /// stuffing.
        ///
        /// Every literal `0xFF` in entropy coded data is written as `FF 00`, so
        /// the trailing `0x00` is dropped here. The input must not contain
        /// restart markers; split them out beforehand.
        ///
        /// -   Parameter interval:
        ///     Raw entropy coded bytes, stuffing included.
        public init(_ interval: [UInt8]) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(interval.count)

            var stuffed: Bool = false
            for byte: UInt8 in interval {
                if stuffed {
                    // The byte after 0xFF. A 0x00 is the stuffing itself and is
                    // dropped; anything else means the caller passed data that
                    // still contains a marker.
                    stuffed = false
                    if byte != 0x00 {
                        bytes.append(byte)
                    }
                    continue
                }
                bytes.append(byte)
                stuffed = byte == 0xFF
            }

            self.bytes = bytes
            self.bit = 0
        }
    }
}

extension JPEG.Bitstream {
    /// The number of bits in this interval.
    public var count: Int {
        self.bytes.count << 3
    }

    /// Whether the read position has passed the end of the interval.
    ///
    /// Reads beyond the end are permitted and yield zero bits; a decoder
    /// detects truncation by finding it ran out of data before it ran out of
    /// blocks, not by checking this on every read.
    public var isExhausted: Bool {
        self.bit >= self.count
    }

    /// Returns the next `count` bits without advancing, zero-padded past the
    /// end of the interval.
    ///
    /// This gathers its window from the array on every call rather than keeping
    /// one in a register, which is the opposite of what libjpeg does and looks
    /// like the obvious thing to fix. It was tried, twice, and both times it was
    /// slower. Instruction counts under callgrind, draining a 64 KB interval
    /// twenty times in the peek-advance-read pattern a Huffman coefficient
    /// produces:
    ///
    /// | | instructions | |
    /// | --- | --- | --- |
    /// | gathering the window here | 175,002,540 | |
    /// | a 64-bit cache refilled a byte at a time | 240,909,963 | +37.7% |
    /// | a 64-bit cache refilled 32 bits at a time | 217,317,738 | +24.2% |
    ///
    /// The reason is that this function is already most of a bit cache. It reads
    /// three bytes with three *independent* conditional loads and keeps no state
    /// at all. A cache replaces those loads with state that every ``advance(_:)``
    /// must update — shift the register, decrement the count, test whether to
    /// refill, and refill at a shift amount derived from the count — and that
    /// chain is serial, where the three loads are not. libjpeg gains from a cache
    /// because the alternative it is compared against extracts one bit at a time;
    /// against a windowed peek there is nothing left to win.
    ///
    /// The measurement is worth more than the conclusion: if this is tried again,
    /// the number to beat is in the table, and `BitstreamTests` holds a
    /// differential check against a bit-at-a-time reference that a broken refill
    /// will fail.
    ///
    /// Three smaller things were tried on the shape below. Instruction counts for
    /// the whole entropy decode of a megapixel 4:2:0 image, which is the figure
    /// worth moving:
    ///
    /// | | instructions | |
    /// | --- | --- | --- |
    /// | a conditional load per byte | 211.9M | |
    /// | the whole-window fast path below | 200.6M | −5.3% |
    /// | that, plus `@inline(__always)` | 215.3M | +1.6% |
    /// | that, with a 64-bit window | 204.5M | −3.5% |
    ///
    /// Inlining it is worse, and worse by more than the fast path is better — so
    /// the two together measure flat, which is how the fast path nearly got
    /// discarded. This is the opposite of ``BitstreamWriter/write(_:count:)``,
    /// where inlining was the single largest win on the encode side; the
    /// difference is that a write is eighteen instructions and a peek is closer
    /// to thirty, at four call sites rather than one. Widening the window to 64
    /// bits is also the opposite of what helped the writer's accumulator, and for
    /// the same reason in reverse: nothing here shifts by an amount that reaches
    /// 32, so there is no width check to make cheaper, and the wider loads and
    /// mask just cost more.
    ///
    /// -   Parameter count:
    ///     A bit count, at most 16 — the longest Huffman code T.81 permits.
    public func peek(_ count: Int) -> UInt16 {
        precondition(count <= 16, "cannot peek more than 16 bits")
        // Not the special case for magnitude category 0 it looks like — that
        // never arrives, because every caller passes 8, 1, or a category it has
        // already found nonzero. What this earns is the *lower* bound on `count`,
        // which the precondition above does not give: without one, `24 - (bit &
        // 7) - count` is unbounded above, so the shift below keeps an overflow
        // check on the subtraction, sign checks on both operands, a test that the
        // amount fits 32 bits, and the compare-and-select that makes an
        // over-wide shift yield zero. Nine instructions on the hot path, and
        // 224.4M against 200.6M for the entropy decode.
        guard count > 0 else {
            return 0
        }

        // A 16-bit window can straddle three bytes when unaligned, so gather 24
        // bits and shift the requested field down out of them.
        let start: Int = self.bit >> 3
        var window: UInt32 = 0
        if start + 3 <= self.bytes.count {
            // All three bytes are present, which is every position but the last
            // two of the interval — so one compare covers what would otherwise
            // be a compare and a branch per byte, and the loads issue in
            // parallel instead of behind them. The other branch still has to
            // exist: a decoder is allowed to read past the end and get zeros,
            // and it does, on the final block of every scan.
            self.bytes.withUnsafeBufferPointer {
                window = .init($0[start]) << 16
                    | .init($0[start + 1]) << 8
                    | .init($0[start + 2])
            }
        } else {
            for offset: Int in 0 ..< 3 {
                window <<= 8
                let i: Int = start + offset
                if i < self.bytes.count {
                    window |= .init(self.bytes[i])
                }
            }
        }

        let shift: Int = 24 - (self.bit & 7) - count
        let mask: UInt32 = (1 << UInt32(count)) - 1
        return .init((window >> UInt32(shift)) & mask)
    }

    /// Advances the read position by `count` bits.
    public mutating func advance(_ count: Int) {
        self.bit += count
    }

    /// Reads `count` bits and advances past them.
    public mutating func read(_ count: Int) -> UInt16 {
        defer {
            self.advance(count)
        }
        return self.peek(count)
    }

    /// Reads a signed coefficient amplitude of the given magnitude category.
    ///
    /// This is the `RECEIVE` and `EXTEND` pair from T.81 §F.2.2.1. A category
    /// of `t` bits encodes the `2^t` values from `-(2^t - 1)` through `-2^(t-1)`
    /// and `2^(t-1)` through `2^t - 1`; the top half is stored directly and the
    /// bottom half is offset, so a leading zero bit marks a negative value.
    ///
    /// -   Parameter category:
    ///     The magnitude category, 0 through 16. Category 0 encodes the value
    ///     zero in no bits at all.
    public mutating func amplitude(category: Int) -> Int {
        guard category > 0 else {
            return 0
        }

        let raw: Int = .init(self.read(category))
        // A leading 1 bit means the value is positive and stored as-is.
        if raw >> (category - 1) != 0 {
            return raw
        } else {
            return raw - (1 << category) + 1
        }
    }
}

extension JPEG.Bitstream {
    /// Splits a scan's entropy coded data at its restart markers.
    ///
    /// Restart markers are byte aligned and reset both the DC predictor and the
    /// bit position, so each interval decodes independently. Their low three
    /// bits carry a phase that counts 0 through 7 and wraps, which is what lets
    /// a decoder notice that an interval was lost rather than silently
    /// producing garbage.
    ///
    /// -   Parameters:
    ///     -   data: Raw entropy coded bytes, stuffing and markers included.
    ///     -   restartInterval: The interval declared by the most recent `DRI`
    ///         segment, or 0 if restarts are not in use. Zero suppresses
    ///         splitting entirely, since a stream without `DRI` has no restart
    ///         markers to find.
    ///
    /// -   Returns:
    ///     One byte range per interval, in stream order. Always at least one
    ///     element, even when the data is empty.
    public static func intervals(of data: [UInt8], restartInterval: Int) throws(JPEG.Failure) -> [[UInt8]] {
        guard restartInterval > 0 else {
            return [data]
        }

        var intervals: [[UInt8]] = []
        var start: Int = 0
        var phase: Int = 0
        var i: Int = 0

        while i + 1 < data.count {
            guard data[i] == 0xFF, case 0xD0 ... 0xD7 = data[i + 1] else {
                i += 1
                continue
            }

            let found: Int = .init(data[i + 1] - 0xD0)
            guard found == phase else {
                throw .decoding(.invalidRestartPhase(found, expected: phase))
            }

            intervals.append(.init(data[start ..< i]))
            phase = (phase + 1) & 7
            i += 2
            start = i
        }

        intervals.append(.init(data[start...]))
        return intervals
    }
}
