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

            // A run at a time rather than a byte at a time, like the lexer that
            // produced this data: everything up to and including a 0xFF is
            // appended in bulk, and only the byte after a 0xFF is examined —
            // a 0x00 is the stuffing itself and is dropped; anything else means
            // the caller passed data that still contains a marker, and is kept
            // without being examined for stuffing of its own, which is what the
            // byte-at-a-time state machine this replaces did.
            interval.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) in
                let end: Int = buffer.count
                var i: Int = 0
                while i < end {
                    var j: Int = i
                    while j < end, buffer[j] != 0xFF {
                        j += 1
                    }
                    guard j < end else {
                        bytes.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[i ..< end]))
                        break
                    }
                    bytes.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[i ... j]))
                    i = j + 1
                    if i < end {
                        if buffer[i] != 0x00 {
                            bytes.append(buffer[i])
                        }
                        i += 1
                    }
                }
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
    /// The reason is that this function is already most of a bit cache. It loads
    /// its window and keeps no state at all. A cache replaces that load with
    /// state that every ``advance(_:)`` must update — shift the register,
    /// decrement the count, test whether to refill, and refill at a shift amount
    /// derived from the count — and that chain is serial, where the load is not.
    /// libjpeg gains from a cache because the alternative it is compared against
    /// extracts one bit at a time; against a windowed peek there is nothing left
    /// to win.
    ///
    /// The measurement is worth more than the conclusion: if this is tried again,
    /// the number to beat is in the table, and `BitstreamTests` holds a
    /// differential check against a bit-at-a-time reference that a broken refill
    /// will fail.
    ///
    /// Several smaller things were tried on the shape below. Instruction counts
    /// for the whole decode of a megapixel 4:2:0 image, which is the figure worth
    /// moving:
    ///
    /// | | instructions | |
    /// | --- | --- | --- |
    /// | three byte loads, a mask, no attribute | 1920.4M | |
    /// | that, plus `@inline(never)` | 1919.6M | −0.04% |
    /// | one unaligned load, no mask, no attribute | 1927.6M | +0.37% |
    /// | one unaligned load, no mask, `@inline(never)` | 1801.8M | **−6.18%** |
    ///
    /// The last two rows are why the attribute is there, and it is load bearing
    /// rather than decoration. The arithmetic below is a third smaller than what
    /// it replaced, and *on its own that made things worse*: a smaller body
    /// crossed the optimizer's threshold and got inlined into all four callers,
    /// and inlining this is a loss. That was already known — an earlier round
    /// measured `@inline(__always)` at +1.6% — but the attribute that records it
    /// was never written down, so the knowledge did not survive contact with a
    /// body that changed size. Pinning it costs nothing when the optimizer agrees
    /// and 6% when it does not.
    ///
    /// This is the opposite of ``BitstreamWriter/write(_:count:)``, where inlining
    /// was the single largest win on the encode side; the difference is that a
    /// write is eighteen instructions and a peek is closer to forty, at four call
    /// sites rather than one.
    ///
    /// Two things the current shape gets that the three-load version could not.
    /// The window is left justified, so the field comes out in two shifts with no
    /// mask — `(1 << count) - 1` was not one instruction, because Swift's shift
    /// yields zero rather than undefined for an over-wide amount and so carried a
    /// compare and a select. And both shift amounts are provably in range, so they
    /// use the masking operators and re-check nothing. An earlier note here said a
    /// 64-bit window did not pay because "nothing here shifts by an amount that
    /// reaches 32"; that is no longer true of the 32-bit form, and the 64-bit one
    /// has not been retried against it.
    ///
    /// -   Parameter count:
    ///     A bit count, at most 16 — the longest Huffman code T.81 permits.
    @inline(never)
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

        // The window is kept left-justified — the byte at the read position
        // occupies the *top* eight bits — which is what lets the field come
        // out in two shifts with no mask. Aligning left by `bit & 7` puts the
        // wanted field at the top of the word, and a logical right shift by
        // `32 - count` brings it down zero-filled. The mask this replaces was
        // `(1 << count) - 1`, and it was not one instruction: Swift's shift
        // yields zero rather than undefined for an over-wide amount, so it
        // carried a compare and a select.
        //
        // Both shift amounts are provably in range — `bit & 7` is at most 7,
        // and `count` is 1 through 16 by the precondition and the guard above,
        // so `32 - count` is 16 through 31. That is why they are the masking
        // operators: an ordinary shift would re-check what is already known.
        let start: Int = self.bit >> 3
        var window: UInt32 = 0
        if start + 4 <= self.bytes.count {
            // One unaligned 32-bit load and a byte swap, rather than three
            // byte loads and the shift-or tree to assemble them. A 16-bit
            // field can straddle three bytes, so three is the minimum that
            // would do; reading the fourth costs nothing on any processor this
            // runs on and turns the gather into a single instruction pair.
            //
            // The other branch still has to exist: a decoder is allowed to
            // read past the end and get zeros, and it does, on the final block
            // of every scan.
            self.bytes.withUnsafeBufferPointer {
                // `UInt32(bigEndian:)` rather than `.bigEndian` — the two are
                // the same byte swap, but this one says what is meant: the
                // bytes in the stream are most significant first, and this
                // interprets them, which is also why it is correct on a
                // big-endian machine where it compiles to nothing.
                window = UInt32(
                    bigEndian: UnsafeRawPointer($0.baseAddress! + start)
                        .loadUnaligned(as: UInt32.self)
                )
            }
        } else {
            // Left-justified the same way, so the arithmetic below is shared:
            // four bytes from the read position, zero past the end.
            for offset: Int in 0 ..< 4 {
                window <<= 8
                let i: Int = start + offset
                if i < self.bytes.count {
                    window |= .init(self.bytes[i])
                }
            }
        }

        return .init(truncatingIfNeeded: (window &<< (self.bit & 7)) &>> (32 - count))
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
