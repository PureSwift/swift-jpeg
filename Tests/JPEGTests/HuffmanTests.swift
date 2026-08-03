import Testing

@testable import JPEG

/// Covers canonical Huffman code construction against the example tables in
/// T.81 Annex K, which almost every real encoder ships verbatim.
struct HuffmanTests {
    /// The typical luminance DC table, T.81 Table K.3.
    ///
    /// One 2-bit code, five 3-bit codes, then one code at each length from 4
    /// through 9 — twelve symbols covering the magnitude categories.
    private static let luminanceDC: (counts: [Int], values: [UInt8]) = (
        counts: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
        values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    )

    private static func table(
        _ definition: (counts: [Int], values: [UInt8])
    ) throws -> JPEG.Table.Huffman {
        try .init(counts: definition.counts, values: definition.values, target: 0, class: .dc)
    }

    /// The canonical assignment for Table K.3, derived by hand from T.81 Annex
    /// C: codes are handed out shortest first, incrementing within a length and
    /// shifting left when the length grows.
    ///
    /// Symbol 0 is `00`; symbols 1 through 5 are `010` through `110`; then one
    /// symbol per length, each a run of ones followed by a zero.
    @Test(arguments: [
        (0b00, 2, UInt8(0)),
        (0b010, 3, UInt8(1)),
        (0b011, 3, UInt8(2)),
        (0b100, 3, UInt8(3)),
        (0b101, 3, UInt8(4)),
        (0b110, 3, UInt8(5)),
        (0b1110, 4, UInt8(6)),
        (0b11110, 5, UInt8(7)),
        (0b111110, 6, UInt8(8)),
        (0b1111110, 7, UInt8(9)),
        (0b11111110, 8, UInt8(10)),
        (0b111111110, 9, UInt8(11)),
    ])
    func decodesCanonicalCodes(_ code: Int, _ length: Int, _ expected: UInt8) throws {
        let table: JPEG.Table.Huffman = try Self.table(Self.luminanceDC)

        // Left-align the code in a 24-bit buffer so the reader sees it first.
        let padded: Int = code << (24 - length)
        var bits: JPEG.Bitstream = .init([
            .init(truncatingIfNeeded: padded >> 16),
            .init(truncatingIfNeeded: padded >> 8),
            .init(truncatingIfNeeded: padded),
        ])

        #expect(try table.symbol(from: &bits) == expected)
        #expect(bits.bit == length, "consumed \(bits.bit) bits, expected \(length)")
    }

    @Test
    func decodesConsecutiveSymbols() throws {
        let table: JPEG.Table.Huffman = try Self.table(Self.luminanceDC)
        // 00 | 010 | 011 packed into one byte.
        var bits: JPEG.Bitstream = .init([0b00_010_011])

        #expect(try table.symbol(from: &bits) == 0)
        #expect(try table.symbol(from: &bits) == 1)
        #expect(try table.symbol(from: &bits) == 2)
    }

    @Test
    func rejectsOverfullCodeSpace() {
        // Three codes of length 1 cannot be prefix-free — only two exist.
        let failure: JPEG.Failure? = #expect(throws: JPEG.Failure.self) {
            _ = try JPEG.Table.Huffman(
                counts: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                values: [0, 1, 2],
                target: 0,
                class: .dc
            )
        }
        // The stage is the useful part of the assertion: it says the failure
        // was found where it should have been.
        #expect(failure?.stage == JPEG.ParsingError.namespace)
    }

    @Test
    func rejectsSymbolCountMismatch() {
        let failure: JPEG.Failure? = #expect(throws: JPEG.Failure.self) {
            _ = try JPEG.Table.Huffman(
                counts: [0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                values: [0],
                target: 0,
                class: .dc
            )
        }
        // The stage is the useful part of the assertion: it says the failure
        // was found where it should have been.
        #expect(failure?.stage == JPEG.ParsingError.namespace)
    }

    @Test
    func rejectsUnassignedCode() throws {
        let table: JPEG.Table.Huffman = try Self.table(Self.luminanceDC)
        // Table K.3's longest code is nine bits; a run of sixteen ones matches
        // nothing and must be reported rather than silently returning a symbol.
        var bits: JPEG.Bitstream = .init([0xFF, 0xFF, 0xFF])

        let failure: JPEG.Failure? = #expect(throws: JPEG.Failure.self) {
            _ = try table.symbol(from: &bits)
        }
        // The stage is the useful part of the assertion: it says the failure
        // was found where it should have been.
        #expect(failure?.stage == JPEG.DecodingError.namespace)
    }

    @Test
    func parsesSegmentWithTwoTables() throws {
        // Two definitions back to back: a DC table in slot 0 and an AC table in
        // slot 1, each with a single one-bit code.
        var data: [UInt8] = []
        for (selector, symbol): (UInt8, UInt8) in [(0x00, 0xAA), (0x11, 0xBB)] {
            data.append(selector)
            data.append(contentsOf: [1] + [UInt8](repeating: 0, count: 15))
            data.append(symbol)
        }

        let tables: [JPEG.Table.Huffman] = try JPEG.Table.Huffman.parse(data)
        #expect(tables.count == 2)
        #expect(tables[0].class == .dc)
        #expect(tables[0].target == 0)
        #expect(tables[1].class == .ac)
        #expect(tables[1].target == 1)

        var bits: JPEG.Bitstream = .init([0x00])
        #expect(try tables[0].symbol(from: &bits) == 0xAA)
    }

    @Test
    func rejectsInvalidTableClass() {
        var data: [UInt8] = [0x20]
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))

        let failure: JPEG.Failure? = #expect(throws: JPEG.Failure.self) {
            _ = try JPEG.Table.Huffman.parse(data)
        }
        // The stage is the useful part of the assertion: it says the failure
        // was found where it should have been.
        #expect(failure?.stage == JPEG.ParsingError.namespace)
    }
}
