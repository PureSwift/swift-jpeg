extension JPEG.Table.Huffman {
    /// Builds a minimum-redundancy table for the given symbol frequencies.
    ///
    /// The procedure of T.81 Annex K.2. It is a Huffman construction with one
    /// extra constraint: no code may exceed sixteen bits, because that is all
    /// the format can express. The usual algorithm can produce longer codes for
    /// very skewed distributions, so lengths above the limit are redistributed
    /// afterwards — trading a little compression for a table that can actually
    /// be written.
    ///
    /// Two details are easy to miss and both matter. A reserved symbol is given
    /// a frequency of one so that the all-ones code stays unassigned, which is
    /// what stops a decoder reading into padding from finding a valid symbol.
    /// And ties are broken toward the *larger* symbol value, which is what makes
    /// the output reproducible rather than dependent on how the frequencies
    /// happened to be enumerated.
    ///
    /// -   Parameter frequencies:
    ///     How often each of the 256 symbols occurs. Symbols that never occur
    ///     get no code at all.
    public static func optimal(
        frequencies: [Int],
        target: Key,
        class: Class
    ) throws -> Self {
        precondition(frequencies.count == 256)

        // Index 256 is the reserved symbol. It takes part in the construction
        // and is removed at the end, which is what leaves the longest code
        // unassigned.
        var freq: [Int] = frequencies + [1]
        var others: [Int] = .init(repeating: -1, count: 257)
        var codesize: [Int] = .init(repeating: 0, count: 257)

        while true {
            // The two least frequent live entries. Ties go to the larger index
            // so the result does not depend on enumeration order.
            var c1: Int = -1
            var c2: Int = -1
            var v1: Int = .max
            var v2: Int = .max
            for i: Int in 0 ... 256 where freq[i] > 0 {
                if freq[i] <= v1 {
                    c2 = c1
                    v2 = v1
                    c1 = i
                    v1 = freq[i]
                } else if freq[i] <= v2 {
                    c2 = i
                    v2 = freq[i]
                }
            }
            guard c2 >= 0 else {
                break
            }

            // Merge the two trees and lengthen every code in both.
            freq[c1] += freq[c2]
            freq[c2] = 0

            codesize[c1] += 1
            while others[c1] >= 0 {
                c1 = others[c1]
                codesize[c1] += 1
            }
            others[c1] = c2

            codesize[c2] += 1
            while others[c2] >= 0 {
                c2 = others[c2]
                codesize[c2] += 1
            }
        }

        // Counts per code length. 32 is the widest the construction can produce.
        var bits: [Int] = .init(repeating: 0, count: 33)
        for i: Int in 0 ... 256 where codesize[i] > 0 {
            guard codesize[i] <= 32 else {
                throw JPEG.ParsingError.invalidHuffmanTable
            }
            bits[codesize[i]] += 1
        }

        // Push anything longer than sixteen bits back down. Each step takes a
        // pair of overlong codes and rebuilds them one level shallower, which
        // costs a shorter code elsewhere — the standard's own transformation.
        var i: Int = 32
        while i > 16 {
            while bits[i] > 0 {
                var j: Int = i - 2
                while bits[j] == 0 {
                    j -= 1
                }
                bits[i] -= 2
                bits[i - 1] += 1
                bits[j + 1] += 2
                bits[j] -= 1
            }
            i -= 1
        }

        // Drop the reserved symbol, which by construction holds one of the
        // longest codes.
        while i > 0, bits[i] == 0 {
            i -= 1
        }
        bits[i] -= 1

        var values: [UInt8] = []
        values.reserveCapacity(frequencies.count)
        for length: Int in 1 ... 16 {
            for symbol: Int in 0 ..< 256 where codesize[symbol] == length {
                values.append(.init(symbol))
            }
        }

        return try .init(
            counts: .init(bits[1 ... 16]),
            values: values,
            target: target,
            class: `class`
        )
    }
}

extension JPEG.Table.Huffman.Encoder {
    /// Accumulates how often each symbol is written.
    ///
    /// A reference type so the driver that walks the blocks does not have to
    /// thread counters back out; encoding twice — once to count, once to write
    /// — is what optimal tables cost, and the first pass differs from the
    /// second only in using one of these.
    public final class Counter {
        public private(set) var frequencies: [Int]

        public init() {
            self.frequencies = .init(repeating: 0, count: 256)
        }

        func record(_ symbol: UInt8) {
            self.frequencies[.init(symbol)] += 1
        }
    }
}
