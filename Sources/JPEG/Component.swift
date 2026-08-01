extension JPEG {
    /// A color component of a frame.
    ///
    /// A frame header declares one of these per component: how densely the
    /// component is sampled relative to the others, and which quantization
    /// table dequantizes it.
    public struct Component: Sendable, Hashable {
        /// A component identifier.
        ///
        /// The standard assigns no meaning to these bytes — a scan header
        /// refers back to a frame component by matching the identifier, and
        /// that is their only role. Conventions exist (JFIF numbers the
        /// components 1, 2, 3; Adobe sometimes uses `'R'`, `'G'`, `'B'`) and a
        /// color format may choose to recognize them, but the codec does not.
        public struct Key: Sendable, Hashable, Comparable {
            /// The identifier byte.
            public let value: UInt8

            public init(_ value: UInt8) {
                self.value = value
            }

            public static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.value < rhs.value
            }
        }

        /// A sampling factor pair.
        ///
        /// Sampling factors are relative, not absolute. A component is sampled
        /// at `x / maximumX` of the frame's horizontal resolution, where the
        /// maximum is taken across all components in the frame — so `(1, 1)`
        /// for every component means no subsampling, and luma `(2, 2)` against
        /// chroma `(1, 1)` is the arrangement usually written 4:2:0.
        public struct Sampling: Sendable, Hashable {
            /// The horizontal sampling factor, 1 through 4.
            public let x: Int
            /// The vertical sampling factor, 1 through 4.
            public let y: Int

            public init(x: Int, y: Int) {
                self.x = x
                self.y = y
            }

            /// The number of 8×8 blocks this component contributes to each
            /// minimum coded unit.
            public var blocksPerMCU: Int {
                self.x * self.y
            }
        }

        /// How densely this component is sampled.
        public let sampling: Sampling
        /// The quantization table this component's coefficients were quantized
        /// with.
        public let selector: JPEG.Table.Quantization.Key

        public init(sampling: Sampling, selector: JPEG.Table.Quantization.Key) {
            self.sampling = sampling
            self.selector = selector
        }
    }
}

extension JPEG.Component.Key: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt8) {
        self.init(value)
    }
}

extension JPEG.Component.Key: CustomStringConvertible {
    public var description: String {
        "\(self.value)"
    }
}

extension JPEG {
    /// A reference to a component from within a scan header.
    ///
    /// Distinct from ``Component`` because the two headers carry different
    /// information about the same component: the frame header fixes its
    /// geometry for the whole image, while each scan header names the entropy
    /// coding tables that scan uses for it.
    public struct ScanComponent: Sendable, Hashable {
        /// The frame component this refers to.
        public let component: JPEG.Component.Key
        /// The DC table for this component in this scan.
        ///
        /// Unused by a progressive AC scan, which codes no DC coefficients.
        public let dc: JPEG.Table.Huffman.Key
        /// The AC table for this component in this scan.
        ///
        /// Unused by a progressive DC scan.
        public let ac: JPEG.Table.Huffman.Key

        public init(
            component: JPEG.Component.Key,
            dc: JPEG.Table.Huffman.Key,
            ac: JPEG.Table.Huffman.Key
        ) {
            self.component = component
            self.dc = dc
            self.ac = ac
        }
    }
}
