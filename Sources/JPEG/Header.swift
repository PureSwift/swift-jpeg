extension JPEG {
    /// A namespace for the parsed contents of marker segments.
    ///
    /// A header is the segment payload interpreted and validated in isolation.
    /// Checking a header against the rest of the stream — that a scan names a
    /// component the frame declared, say — is ``Layout``'s job, not this one's.
    public enum Header {
    }
}

extension JPEG.Header {
    /// A parsed start-of-frame segment.
    ///
    /// Fixes the image geometry, the sample precision, and the set of
    /// components, for the whole image.
    public struct Frame: Sendable {
        /// The coding process, taken from the marker rather than the payload.
        public let process: JPEG.Process
        /// The sample precision, in bits.
        public let precision: Int
        /// The image width, in samples. Always positive.
        public let width: Int
        /// The image height, in samples.
        ///
        /// Zero means the height was not known when the stream was written and
        /// arrives later in a ``HeightRedefinition``. This is legal, and is how
        /// a JPEG produced by a streaming encoder looks.
        public private(set) var height: Int
        /// The frame's components, keyed by identifier.
        public let components: [JPEG.Component.Key: JPEG.Component]
        /// The component identifiers in declaration order.
        ///
        /// Order matters: it fixes which plane a component maps to, and a
        /// dictionary does not preserve it.
        public let order: [JPEG.Component.Key]
    }

    /// A parsed start-of-scan segment.
    public struct Scan: Sendable {
        /// The range of coefficient indices, in zigzag order, that this scan
        /// codes.
        ///
        /// `0 ..< 64` for a sequential scan. A progressive scan codes either
        /// the DC coefficient alone (`0 ..< 1`) or a band of AC coefficients.
        public let band: Range<Int>
        /// The range of coefficient bits this scan codes, as a successive
        /// approximation split.
        ///
        /// A first pass — which is every sequential scan, and a progressive
        /// scan with `Ah` of zero — has no upper bound: it codes the
        /// coefficient from bit `Al` upward, however many significant bits
        /// there turn out to be. That is spelled `Int.max` here rather than the
        /// sample precision, so that "unbounded" stays distinguishable from a
        /// refinement that happens to reach the top bit.
        public let bits: Range<Int>
        /// The components this scan codes, in interleave order.
        public let components: [JPEG.ScanComponent]

        /// What a scan codes, and whether it is refining what an earlier scan
        /// already wrote.
        ///
        /// A sequential scan codes every coefficient of every block once. A
        /// progressive image splits that work up two ways at once — by spectral
        /// band, and by bit position — and the four resulting combinations are
        /// coded by genuinely different procedures, not by one procedure with
        /// parameters. Naming them here keeps that dispatch in one place.
        public enum Kind: Sendable, Hashable {
            /// Every coefficient, in one pass.
            case sequential
            /// The DC coefficient only.
            ///
            /// May be interleaved across several components.
            case dc(refining: Bool)
            /// A band of AC coefficients.
            ///
            /// Never interleaved: T.81 requires a single component, because
            /// there is no meaningful MCU when only some coefficients are
            /// present.
            case ac(refining: Bool)
        }
    }

    /// A parsed define-number-of-lines segment.
    public struct HeightRedefinition: Sendable {
        /// The image height, in samples.
        public let height: Int
    }

    /// A parsed define-restart-interval segment.
    public struct RestartInterval: Sendable {
        /// The number of minimum coded units between restart markers, or 0 to
        /// disable restarts.
        public let interval: Int
    }
}

extension JPEG.Header.Frame {
    /// Parses the body of a start-of-frame segment.
    ///
    /// -   Parameters:
    ///     -   data: The segment body, excluding the length field.
    ///     -   process: The coding process, which the marker code carried.
    public static func parse(_ data: [UInt8], process: JPEG.Process) throws -> Self {
        guard data.count >= 6 else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .frame(process),
                count: data.count,
                expected: 6 ... 6
            )
        }

        let precision: Int = .init(data[0])
        guard process.precisions.contains(precision) else {
            throw JPEG.ParsingError.invalidFramePrecision(precision, process)
        }

        // Height precedes width, and height alone may be zero.
        let height: Int = .init(data[1]) << 8 | .init(data[2])
        let width: Int = .init(data[3]) << 8 | .init(data[4])
        guard width > 0 else {
            throw JPEG.ParsingError.invalidFrameWidth(width)
        }

        let count: Int = .init(data[5])
        guard count > 0 else {
            throw JPEG.ParsingError.invalidFrameComponentCount(count, process)
        }
        guard data.count == 6 + 3 * count else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .frame(process),
                count: data.count,
                expected: (6 + 3 * count) ... (6 + 3 * count)
            )
        }

        var components: [JPEG.Component.Key: JPEG.Component] = [:]
        var order: [JPEG.Component.Key] = []
        order.reserveCapacity(count)

        for i: Int in 0 ..< count {
            let base: Int = 6 + 3 * i
            let key: JPEG.Component.Key = .init(data[base])

            let x: Int = .init(data[base + 1] >> 4)
            let y: Int = .init(data[base + 1] & 0x0F)
            guard 1 ... 4 ~= x, 1 ... 4 ~= y else {
                throw JPEG.ParsingError.invalidFrameSamplingFactor(x: x, y: y, key)
            }

            let selector: UInt8 = data[base + 2]
            guard selector < 4 else {
                throw JPEG.ParsingError.invalidQuantizationTargetCode(selector)
            }

            guard components.updateValue(
                .init(
                    sampling: .init(x: x, y: y),
                    selector: .init(.init(selector))
                ),
                forKey: key
            ) == nil
            else {
                throw JPEG.ParsingError.duplicateFrameComponentIndex(key)
            }
            order.append(key)
        }

        return .init(
            process: process,
            precision: precision,
            width: width,
            height: height,
            components: components,
            order: order
        )
    }

    /// Applies a define-number-of-lines segment.
    ///
    /// Only meaningful when the frame header declared a height of zero; a
    /// redefinition of an already-known height is ignored rather than treated
    /// as an error, since it carries no new information.
    public mutating func redefine(height: JPEG.Header.HeightRedefinition) {
        guard self.height == 0 else {
            return
        }
        self.height = height.height
    }
}

extension JPEG.Header.Scan {
    /// Parses the body of a start-of-scan segment.
    ///
    /// -   Parameters:
    ///     -   data: The segment body, excluding the length field.
    ///     -   process: The coding process, which constrains the spectral
    ///         selection and successive approximation fields.
    public static func parse(_ data: [UInt8], process: JPEG.Process) throws -> Self {
        guard data.count >= 4 else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .scan,
                count: data.count,
                expected: 4 ... 4
            )
        }

        let count: Int = .init(data[0])
        guard 1 ... 4 ~= count else {
            throw JPEG.ParsingError.invalidScanComponentCount(count)
        }
        guard data.count == 4 + 2 * count else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .scan,
                count: data.count,
                expected: (4 + 2 * count) ... (4 + 2 * count)
            )
        }

        var components: [JPEG.ScanComponent] = []
        components.reserveCapacity(count)

        for i: Int in 0 ..< count {
            let base: Int = 1 + 2 * i
            let dc: UInt8 = data[base + 1] >> 4
            let ac: UInt8 = data[base + 1] & 0x0F
            guard dc < 4 else {
                throw JPEG.ParsingError.invalidHuffmanTargetCode(dc)
            }
            guard ac < 4 else {
                throw JPEG.ParsingError.invalidHuffmanTargetCode(ac)
            }

            components.append(
                .init(
                    component: .init(data[base]),
                    dc: .init(.init(dc)),
                    ac: .init(.init(ac))
                )
            )
        }

        let tail: Int = 1 + 2 * count
        let start: Int = .init(data[tail])
        let end: Int = .init(data[tail + 1])
        let high: Int = .init(data[tail + 2] >> 4)
        let low: Int = .init(data[tail + 2] & 0x0F)

        // A sequential scan must cover the whole block; T.81 requires Ss = 0
        // and Se = 63 in that case, and the encoded `end` is inclusive.
        // A lossless scan reuses these two fields for something else entirely:
        // Ss carries the predictor selection value and Se is zero. Nothing
        // below applies to it, and reading them as a spectral band would
        // reject every conforming lossless image.
        if case .lossless = process {
            guard 1 ... 7 ~= start, end == 0 else {
                throw JPEG.ParsingError.invalidPredictor(start)
            }
            guard high == 0 else {
                throw JPEG.ParsingError.invalidScanSuccessiveApproximation(
                    high: high, low: low
                )
            }
            return .init(
                band: start ..< start + 1,
                bits: low ..< Int.max,
                components: components
            )
        }

        // `Swift.max` keeps the reported range well-formed when start > end;
        // constructing `start ..< end` directly would trap before the error
        // could be thrown.
        guard start <= end, end < 64 else {
            throw JPEG.ParsingError.invalidScanBandRange(
                start ..< Swift.max(start, end) + 1,
                process
            )
        }
        if !process.isProgressive, start != 0 || end != 63 {
            throw JPEG.ParsingError.invalidScanBandRange(start ..< end + 1, process)
        }

        // The successive approximation high field is either zero, for a first
        // pass, or exactly one more than the low field, for a refinement.
        guard high == 0 || high == low + 1 else {
            throw JPEG.ParsingError.invalidScanSuccessiveApproximation(high: high, low: low)
        }

        if process.isProgressive {
            // A DC scan is exactly Ss = Se = 0. Anything else starting at zero
            // would mix DC and AC coding in one pass, which the standard does
            // not define.
            if start == 0, end != 0 {
                throw JPEG.ParsingError.invalidScanBandRange(start ..< end + 1, process)
            }
            // An AC scan has no interleaving to define, since an MCU made of
            // partial blocks is meaningless.
            if start != 0, count != 1 {
                throw JPEG.ParsingError.invalidScanComponentCount(count)
            }
        }

        return .init(
            band: start ..< end + 1,
            bits: low ..< (high == 0 ? Int.max : high),
            components: components
        )
    }
}

extension JPEG.Header.Scan {
    /// The point transform: the bit position this scan codes down to.
    ///
    /// Coefficients are stored shifted left by this much, so a later refinement
    /// can fill in the bits below.
    public var approximation: Int {
        self.bits.lowerBound
    }

    /// Whether this scan is the first to write the bits it covers.
    ///
    /// A first pass writes whole coefficient values; a refinement only appends
    /// one bit to each, and has to be told which coefficients already exist.
    public var isFirstPass: Bool {
        self.bits.upperBound == Int.max
    }

    /// Classifies this scan for the given coding process.
    public func kind(process: JPEG.Process) -> Kind {
        guard process.isProgressive else {
            return .sequential
        }
        if self.band.lowerBound == 0 {
            return .dc(refining: !self.isFirstPass)
        } else {
            return .ac(refining: !self.isFirstPass)
        }
    }
}

extension JPEG.Header.HeightRedefinition {
    /// Parses the body of a define-number-of-lines segment.
    public static func parse(_ data: [UInt8]) throws -> Self {
        guard data.count == 2 else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .height,
                count: data.count,
                expected: 2 ... 2
            )
        }
        return .init(height: .init(data[0]) << 8 | .init(data[1]))
    }
}

extension JPEG.Header.RestartInterval {
    /// Parses the body of a define-restart-interval segment.
    public static func parse(_ data: [UInt8]) throws -> Self {
        guard data.count == 2 else {
            throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                .restartInterval,
                count: data.count,
                expected: 2 ... 2
            )
        }
        return .init(interval: .init(data[0]) << 8 | .init(data[1]))
    }
}
