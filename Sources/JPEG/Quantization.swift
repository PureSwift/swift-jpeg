extension JPEG {
    /// A namespace for the table types a JPEG stream defines inline.
    public enum Table {
    }
}

extension JPEG {
    /// The order in which the 64 coefficients of a block appear in the entropy
    /// coded stream.
    ///
    /// Entry `z` is the row-major index of the coefficient that occupies
    /// position `z` of the zigzag sequence. The sequence walks the block's
    /// anti-diagonals in alternating directions, so that coefficients are
    /// visited roughly in order of increasing spatial frequency and the
    /// high-frequency tail — which quantization usually flattens to zero — ends
    /// up contiguous and cheap to run-length code.
    ///
    /// Computed rather than transcribed from T.81 Figure A.6, since the pattern
    /// is short to state and a typo in a 64-entry literal is invisible.
    public static let zigzag: [Int] = {
        var order: [Int] = []
        order.reserveCapacity(64)

        for diagonal: Int in 0 ... 14 {
            let lower: Int = max(0, diagonal - 7)
            let upper: Int = min(7, diagonal)
            // Even diagonals run up and to the right, odd ones down and to the
            // left. The alternation is what makes the path a zigzag instead of
            // a sawtooth, and it is what keeps successive entries adjacent.
            let xs: [Int] = diagonal & 1 == 0
                ? .init(lower ... upper)
                : .init((lower ... upper).reversed())

            for x: Int in xs {
                order.append((diagonal - x) << 3 | x)
            }
        }

        return order
    }()
}

extension JPEG.Table {
    /// A quantization table.
    ///
    /// Dequantization is a coefficient-wise multiply, so the whole table is 64
    /// factors. Values are stored in **row-major order**, already un-zigzagged,
    /// which lets the inverse DCT and the dequantization step index a block the
    /// same way.
    public struct Quantization: Sendable {
        /// A quantization table slot.
        ///
        /// A stream defines up to four, and a frame component names the one it
        /// was quantized with. Later definitions of the same slot replace
        /// earlier ones, which is how a progressive stream can requantize
        /// between scans.
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

        /// The width of the values as they appeared in the stream.
        ///
        /// Retained because it has to be reproduced on write: a 16-bit table is
        /// invalid in a baseline frame, so this is not merely cosmetic.
        public enum Precision: Sendable, Hashable {
            /// 8-bit values.
            case uint8
            /// 16-bit values.
            case uint16
        }

        /// The 64 quantization factors, in row-major order.
        public let factors: [UInt16]
        /// The slot this table was defined in.
        public let target: Key
        /// The width of the values as written.
        public let precision: Precision

        init(factors: [UInt16], target: Key, precision: Precision) {
            precondition(factors.count == 64)
            self.factors = factors
            self.target = target
            self.precision = precision
        }
    }
}

extension JPEG.Table.Quantization.Key: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension JPEG.Table.Quantization {
    /// Parses the body of a `DQT` segment.
    ///
    /// One segment may define several tables back to back, each prefixed by a
    /// byte holding the value precision in its high nibble and the destination
    /// slot in its low nibble.
    ///
    /// -   Parameter data:
    ///     The segment body, excluding the length field.
    public static func parse(_ data: [UInt8]) throws(JPEG.Failure) -> [Self] {
        var tables: [Self] = []
        var base: Int = 0

        while base < data.count {
            let byte: UInt8 = data[base]

            let precision: Precision
            switch byte >> 4 {
            case 0:     precision = .uint8
            case 1:     precision = .uint16
            default:    throw .parsing(.invalidQuantizationPrecisionCode(byte >> 4))
            }

            let slot: UInt8 = byte & 0x0F
            guard slot < 4 else {
                throw .parsing(.invalidQuantizationTargetCode(slot))
            }

            let stride: Int = precision == .uint8 ? 1 : 2
            let count: Int = 64 * stride
            guard base + 1 + count <= data.count else {
                throw .parsing(.truncatedMarkerSegmentBody(
                    .quantization,
                    count: data.count,
                    expected: (base + 1 + count) ... (base + 1 + count)
                ))
            }

            // Values arrive in zigzag order; scatter them into row-major so
            // that every later stage can index a block the obvious way.
            var factors: [UInt16] = .init(repeating: 0, count: 64)
            for z: Int in 0 ..< 64 {
                let i: Int = base + 1 + z * stride
                let factor: UInt16 = precision == .uint8
                    ? .init(data[i])
                    : .init(data[i]) << 8 | .init(data[i + 1])
                factors[JPEG.zigzag[z]] = factor
            }

            tables.append(
                .init(factors: factors, target: .init(.init(slot)), precision: precision)
            )
            base += 1 + count
        }

        return tables
    }

    /// The quantization factor for the coefficient at the given row-major
    /// index.
    public subscript(z z: Int) -> UInt16 {
        self.factors[z]
    }

    /// Returns this table with its two frequency axes exchanged.
    ///
    /// Required by any transform that transposes an image. Moving a
    /// coefficient from horizontal frequency `u` to vertical frequency `u`
    /// without moving its quantization factor with it would dequantize it by
    /// the wrong number.
    ///
    /// The mistake hides well: the Annex K *chrominance* table is symmetric, so
    /// chroma looks perfect while luminance — whose table is not symmetric,
    /// with 11 against 12 in the very first off-diagonal pair — comes out
    /// subtly wrong everywhere.
    public func transposed() -> Self {
        var factors: [UInt16] = .init(repeating: 0, count: 64)
        for v: Int in 0 ..< 8 {
            for u: Int in 0 ..< 8 {
                factors[u << 3 | v] = self.factors[v << 3 | u]
            }
        }
        return .init(factors: factors, target: self.target, precision: self.precision)
    }
}
