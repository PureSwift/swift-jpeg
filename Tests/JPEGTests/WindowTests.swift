import Testing

@testable import JPEG

/// Holds the window-based reads against the ones they replace.
///
/// The entropy decoder reads a Huffman symbol and then the amplitude that
/// follows it, and used to do that with two calls into the bit reader. These
/// serve both from one 64-bit window. That is only sound if the window agrees
/// with the reader everywhere, so this compares them directly rather than
/// inferring agreement from images that happen to decode.
struct WindowTests {
    /// Bytes with every shape the reader distinguishes: stuffing, runs of set
    /// bits, and enough length to walk a while.
    static let data: [UInt8] = {
        var bytes: [UInt8] = []
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i: Int in 0 ..< 256 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            // A deliberate mix: mostly random, with 0x00 and 0xFE seeded in.
            // 0xFF is excluded because the reader's constructor would treat it
            // as stuffing and change the byte count out from under the test.
            switch i % 7 {
            case 0:     bytes.append(0x00)
            case 1:     bytes.append(0xFE)
            default:    bytes.append(.init(truncatingIfNeeded: state >> 33))
            }
        }
        return bytes
    }()

    /// The window's top `n` bits must be exactly what `peek(n)` returns, at
    /// every bit position and every width — including positions past the end,
    /// where both must read as zero.
    @Test
    func windowMatchesPeekEverywhere() {
        var bits: JPEG.Bitstream = .init(Self.data)
        // Past the end on purpose: the last few positions exercise the
        // byte-at-a-time fallback in both.
        for position: Int in 0 ..< bits.count + 80 {
            bits = .init(Self.data)
            bits.advance(position)
            let window: UInt64 = bits.window()
            for n: Int in 1 ... 16 {
                let fromWindow: UInt16 = .init(
                    truncatingIfNeeded: window &>> (64 - n)
                )
                #expect(
                    fromWindow == bits.peek(n),
                    "position \(position), width \(n)"
                )
            }
        }
    }

    /// A field taken `k` bits into the window must equal what the reader
    /// returns after advancing `k`.
    @Test
    func offsetFieldsMatch() {
        for position: Int in stride(from: 0, to: 700, by: 3) {
            var bits: JPEG.Bitstream = .init(Self.data)
            bits.advance(position)
            let window: UInt64 = bits.window()

            for offset: Int in 0 ... 16 {
                for n: Int in 1 ... 16 {
                    var reader: JPEG.Bitstream = .init(Self.data)
                    reader.advance(position + offset)

                    let fromWindow: UInt16 = .init(
                        truncatingIfNeeded: (window &<< offset) &>> (64 - n)
                    )
                    #expect(
                        fromWindow == reader.peek(n),
                        "position \(position), offset \(offset), width \(n)"
                    )
                }
            }
        }
    }

    /// The windowed amplitude must equal the reader's, for every category and
    /// every preceding code length.
    @Test
    func amplitudeMatches() {
        for position: Int in stride(from: 0, to: 700, by: 5) {
            var bits: JPEG.Bitstream = .init(Self.data)
            bits.advance(position)
            let window: UInt64 = bits.window()

            for offset: Int in 0 ... 16 {
                for category: Int in 0 ... 16 {
                    var reader: JPEG.Bitstream = .init(Self.data)
                    reader.advance(position + offset)

                    #expect(
                        JPEG.Bitstream.amplitude(
                            of: window, at: offset, category: category
                        ) == reader.amplitude(category: category),
                        "position \(position), offset \(offset), category \(category)"
                    )
                }
            }
        }
    }

    /// Builds a table whose codes span the full range of lengths, so the
    /// symbol lookup's fast path and its fallback both get exercised.
    static func table(class: JPEG.Table.Huffman.Class) throws -> JPEG.Table.Huffman {
        // One code of each short length and the rest long, which forces codes
        // past eight bits to exist — the case the lookup table cannot serve.
        var counts: [Int] = .init(repeating: 0, count: 16)
        counts[0] = 0            // no 1-bit codes
        counts[1] = 2            // 2-bit
        counts[3] = 3            // 4-bit
        counts[7] = 4            // 8-bit
        counts[9] = 5            // 10-bit
        counts[13] = 6           // 14-bit
        let total: Int = counts.reduce(0, +)
        let values: [UInt8] = (0 ..< total).map { .init(truncatingIfNeeded: $0 * 7 + 1) }
        return try #require(
            try JPEG.Table.Huffman(counts: counts, values: values, target: 0, class: `class`)
        )
    }

    /// The windowed symbol lookup must agree with the reader-based one on both
    /// the symbol and the number of bits it consumed — at every bit position,
    /// including the long codes that miss the eight-bit lookup table.
    @Test
    func symbolMatches() throws {
        let table: JPEG.Table.Huffman = try Self.table(class: .ac)

        var resolved: Int = 0
        var viaFallback: Int = 0
        for position: Int in 0 ..< 1200 {
            var reader: JPEG.Bitstream = .init(Self.data)
            reader.advance(position)
            let window: UInt64 = reader.window()

            let expected: UInt8? = try? table.symbol(from: &reader)
            let found: (symbol: UInt8, length: Int)? = table.symbol(in: window)

            guard let expected: UInt8 = expected else {
                #expect(found == nil, "position \(position): reader failed, window did not")
                continue
            }
            let actual: (symbol: UInt8, length: Int) = try #require(
                found, "position \(position): window failed, reader did not"
            )
            #expect(actual.symbol == expected, "position \(position)")
            // The reader advanced by exactly the code's length, which is the
            // other half of what the caller needs and the half a symbol alone
            // cannot check.
            #expect(actual.length == reader.bit - position, "position \(position)")
            resolved += 1
            if actual.length > 8 {
                viaFallback += 1
            }
        }

        // The test is only meaningful if both paths ran. A table whose codes
        // all fit the lookup would exercise the fallback zero times and still
        // pass every assertion above.
        //
        // Not every position resolves: the table is deliberately incomplete, so
        // some bit patterns match no code at any length. Those are checked too
        // — both paths have to fail together — but they are not what the count
        // below is asking about.
        #expect(resolved > 700, "only \(resolved) positions resolved")
        #expect(viaFallback > 0, "the long-code fallback never ran")
    }
}
