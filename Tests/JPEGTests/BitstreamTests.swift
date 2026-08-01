import Testing

@testable import JPEG

/// Covers the bit reader, whose failures are the hardest to diagnose downstream:
/// a single misplaced bit desynchronizes every symbol after it, so the image
/// goes wrong far from the actual mistake.
struct BitstreamTests {
    @Test
    func removesByteStuffing() {
        // A literal 0xFF in entropy coded data is always written as FF 00. The
        // trailing zero is transport, not data, and must not reach the reader.
        let bits: JPEG.Bitstream = .init([0xFF, 0x00, 0x41])
        #expect(bits.count == 16)
        #expect(bits.peek(16) == 0xFF41)
    }

    @Test
    func removesConsecutiveByteStuffing() {
        let bits: JPEG.Bitstream = .init([0xFF, 0x00, 0xFF, 0x00])
        #expect(bits.count == 16)
        #expect(bits.peek(16) == 0xFFFF)
    }

    @Test
    func leavesUnstuffedDataAlone() {
        let bits: JPEG.Bitstream = .init([0x12, 0x34, 0x56])
        #expect(bits.count == 24)
        #expect(bits.peek(16) == 0x1234)
    }

    @Test
    func readsAcrossByteBoundaries() {
        var bits: JPEG.Bitstream = .init([0b1010_1100, 0b1111_0000])

        #expect(bits.read(3) == 0b101)
        // Straddles the byte boundary: three bits from the first byte and two
        // from the second.
        #expect(bits.read(3) == 0b011)
        #expect(bits.read(4) == 0b0011)
        #expect(bits.read(6) == 0b110000)
    }

    @Test
    func peekDoesNotAdvance() {
        var bits: JPEG.Bitstream = .init([0b1101_0000])
        #expect(bits.peek(4) == 0b1101)
        #expect(bits.peek(4) == 0b1101)
        #expect(bits.read(4) == 0b1101)
        #expect(bits.peek(4) == 0)
    }

    @Test
    func readsMaximumWindowUnaligned() {
        // A 16-bit window starting mid-byte spans three bytes, which is the
        // case the gather has to get right.
        var bits: JPEG.Bitstream = .init([0x0F, 0xFF, 0xF0])
        #expect(bits.read(4) == 0x0)
        #expect(bits.read(16) == 0xFFFF)
    }

    @Test
    func padsPastEndWithZeros() {
        var bits: JPEG.Bitstream = .init([0xFF])
        #expect(bits.read(8) == 0xFF)
        #expect(bits.isExhausted)
        // Reading past the end yields zeros rather than trapping. Truncation is
        // caught by the decoder running out of blocks, not here.
        #expect(bits.read(8) == 0)
    }

    /// The RECEIVE and EXTEND pair of T.81 §F.2.2.1.
    ///
    /// A category of `t` bits encodes `2^t` values: the upper half stored
    /// directly, the lower half offset negative. Category 3 therefore covers
    /// -7 ... -4 and 4 ... 7, and a leading zero bit is what marks the
    /// negative side.
    @Test(arguments: [
        (0b000, -7), (0b001, -6), (0b010, -5), (0b011, -4),
        (0b100, 4), (0b101, 5), (0b110, 6), (0b111, 7),
    ])
    func extendsAmplitudes(_ raw: Int, _ expected: Int) {
        var bits: JPEG.Bitstream = .init([UInt8(raw << 5)])
        #expect(bits.amplitude(category: 3) == expected)
    }

    @Test
    func categoryZeroConsumesNothing() {
        var bits: JPEG.Bitstream = .init([0xFF])
        #expect(bits.amplitude(category: 0) == 0)
        #expect(bits.bit == 0)
    }

    @Test
    func splitsAtRestartMarkers() throws {
        // Two intervals separated by RST0, then RST1.
        let data: [UInt8] = [0x11, 0x22, 0xFF, 0xD0, 0x33, 0xFF, 0xD1, 0x44]
        let intervals: [[UInt8]] = try JPEG.Bitstream.intervals(of: data, restartInterval: 1)

        #expect(intervals.count == 3)
        #expect(intervals[0] == [0x11, 0x22])
        #expect(intervals[1] == [0x33])
        #expect(intervals[2] == [0x44])
    }

    @Test
    func doesNotSplitWithoutRestartInterval() throws {
        let data: [UInt8] = [0x11, 0xFF, 0xD0, 0x22]
        let intervals: [[UInt8]] = try JPEG.Bitstream.intervals(of: data, restartInterval: 0)

        #expect(intervals == [data])
    }

    @Test
    func rejectsOutOfOrderRestartPhase() {
        // Phases must count 0, 1, 2 ... and wrap at 8. Jumping straight to RST3
        // means two intervals were lost, which is exactly what the phase exists
        // to detect.
        let data: [UInt8] = [0x11, 0xFF, 0xD3, 0x22]

        #expect(throws: JPEG.DecodingError.self) {
            _ = try JPEG.Bitstream.intervals(of: data, restartInterval: 1)
        }
    }

    @Test
    func treatsStuffedFFAsDataNotRestart() throws {
        // The reason the lexer keeps stuffing intact: after unstuffing, a
        // literal 0xFF followed by a data byte 0xD0 would be indistinguishable
        // from a restart marker. Here FF 00 is a literal and must not split.
        let data: [UInt8] = [0xFF, 0x00, 0xD0, 0x22]
        let intervals: [[UInt8]] = try JPEG.Bitstream.intervals(of: data, restartInterval: 1)

        #expect(intervals.count == 1)
        #expect(JPEG.Bitstream(intervals[0]).peek(16) == 0xFFD0)
    }
}
