extension JPEG.Arithmetic {
    /// The adaptive contexts one scan carries.
    ///
    /// Arithmetic coding replaces code tables with these. Every decision is
    /// coded against a context chosen by what has already been seen — the size
    /// of the previous block's DC difference, how far into the zigzag this
    /// coefficient sits — and each context learns its own probability as the
    /// scan proceeds. There is nothing to transmit: the decoder builds exactly
    /// the same contexts from exactly the same history.
    public struct Statistics {
        /// 64 bins per DC table, indexed by context and magnitude.
        public var dc: [JPEG.Table.Huffman.Key: [Context]]
        /// 256 bins per AC table.
        public var ac: [JPEG.Table.Huffman.Key: [Context]]
        /// The DC context each component carries between blocks, derived from
        /// the size of its previous difference.
        public var contexts: [Int]
        /// The running DC predictor, as in Huffman coding.
        public var predictors: [Int32]
        /// A context that never adapts, used where the standard specifies a
        /// fixed probability.
        ///
        /// Its initial value is not zero but 113 — the one entry of Table D.2
        /// whose successors are both itself. Starting it at zero produces a
        /// context that *adapts*, which desynchronizes the coder at the first
        /// coefficient sign and is invisible in a round trip against one's own
        /// encoder.
        public var fixed: Context

        public init(planes: Int) {
            self.dc = [:]
            self.ac = [:]
            self.contexts = .init(repeating: 0, count: planes)
            self.predictors = .init(repeating: 0, count: planes)
            self.fixed = 113
        }

        mutating func prepare(_ scan: JPEG.Header.Scan) {
            for component: JPEG.ScanComponent in scan.components {
                self.dc[component.dc] = .init(repeating: 0, count: 64)
                self.ac[component.ac] = .init(repeating: 0, count: 256)
            }
        }
    }
}

extension JPEG.Data.Spectral {
    /// Decodes one sequential arithmetic scan.
    ///
    /// The structure mirrors the Huffman decoder — same unit walk, same
    /// interleaving, same restarts — but every value is built one binary
    /// decision at a time rather than looked up in a table.
    mutating func decode(
        arithmetic ecs: [UInt8],
        scan: JPEG.Header.Scan,
        conditioning: JPEG.Arithmetic.Conditioners,
        restartInterval: Int
    ) throws(JPEG.Failure) {
        let planes: [Int] = try self.layout.validate(scan: scan)
        let interleaved: Bool = planes.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? self.layout.mcus
            : self.layout.blocks(plane: planes[0], scan: scan)
        let total: Int = units.x * units.y

        var decoded: Int = 0
        for interval: [UInt8] in try JPEG.Bitstream.intervals(
            of: ecs, restartInterval: restartInterval
        ) {
            // A restart resets the coder *and* everything it has learned. That
            // is what makes each interval independently decodable, and it is
            // why restarts cost noticeably more here than under Huffman coding.
            var coder: JPEG.Arithmetic.Decoder = .init(interval)
            var statistics: JPEG.Arithmetic.Statistics = .init(planes: self.planes.count)
            statistics.prepare(scan)

            let end: Int = restartInterval > 0
                ? Swift.min(total, decoded + restartInterval)
                : total

            while decoded < end {
                let unit: (x: Int, y: Int) = (x: decoded % units.x, y: decoded / units.x)

                for (index, plane): (Int, Int) in planes.enumerated() {
                    let component: JPEG.ScanComponent = scan.components[index]
                    let sampling: JPEG.Component.Sampling = interleaved
                        ? self.layout.planes[plane].sampling
                        : .init(x: 1, y: 1)

                    for v: Int in 0 ..< sampling.y {
                        for h: Int in 0 ..< sampling.x {
                            let block: (x: Int, y: Int) = interleaved
                                ? (
                                    x: unit.x * sampling.x + h,
                                    y: unit.y * sampling.y + v
                                )
                                : unit

                            try self.decode(
                                arithmetic: block,
                                plane: plane,
                                component: component,
                                conditioning: conditioning,
                                coder: &coder,
                                statistics: &statistics,
                                slot: plane
                            )
                        }
                    }
                }
                decoded += 1
            }
        }

        guard decoded == total else {
            throw .decoding(.truncatedEntropyCodedSegment(
                decoded: decoded, expected: total
            ))
        }
    }

    private mutating func decode(
        arithmetic block: (x: Int, y: Int),
        plane: Int,
        component: JPEG.ScanComponent,
        conditioning: JPEG.Arithmetic.Conditioners,
        coder: inout JPEG.Arithmetic.Decoder,
        statistics: inout JPEG.Arithmetic.Statistics,
        slot: Int
    ) throws(JPEG.Failure) {
        let dcConditioning: JPEG.Arithmetic.Conditioning = conditioning.dc(component.dc)
        let acConditioning: JPEG.Arithmetic.Conditioning = conditioning.ac(component.ac)

        // -- the DC difference, per T.81 F.1.4.1 -----------------------------
        var dc: [JPEG.Arithmetic.Context] = statistics.dc[component.dc] ?? .init(
            repeating: 0, count: 64
        )
        let base: Int = statistics.contexts[slot]

        if coder.decode(&dc[base]) != 0 {
            let sign: Int = coder.decode(&dc[base + 1])
            var index: Int = base + 2 + sign
            var magnitude: Int = coder.decode(&dc[index])

            if magnitude != 0 {
                // Table F.4 puts the magnitude ladder at a fixed offset, so
                // every difference size shares one set of contexts however the
                // scan reached it.
                index = 20
                while coder.decode(&dc[index]) != 0 {
                    magnitude <<= 1
                    guard magnitude != 0x8000 else {
                        throw .decoding(.invalidEntropyCodedSymbol)
                    }
                    index += 1
                }
            }

            // The next block's context is chosen by how big this difference
            // was, which is the whole of the conditioning a DAC segment
            // controls.
            if magnitude < (1 << dcConditioning.lower) >> 1 {
                statistics.contexts[slot] = 0
            } else if magnitude > (1 << dcConditioning.upper) >> 1 {
                statistics.contexts[slot] = 12 + sign * 4
            } else {
                statistics.contexts[slot] = 4 + sign * 4
            }

            var value: Int = magnitude
            index += 14
            var bit: Int = magnitude
            while true {
                bit >>= 1
                guard bit != 0 else {
                    break
                }
                if coder.decode(&dc[index]) != 0 {
                    value |= bit
                }
            }
            value += 1
            statistics.predictors[slot] = .init(
                truncatingIfNeeded: Int(statistics.predictors[slot])
                    + (sign != 0 ? -value : value)
            )
        } else {
            statistics.contexts[slot] = 0
        }
        statistics.dc[component.dc] = dc

        self.planes[plane][x: block.x, y: block.y, z: 0] =
            .init(truncatingIfNeeded: statistics.predictors[slot])

        // -- the AC coefficients, per T.81 F.1.4.2 ---------------------------
        var ac: [JPEG.Arithmetic.Context] = statistics.ac[component.ac] ?? .init(
            repeating: 0, count: 256
        )
        defer {
            statistics.ac[component.ac] = ac
        }

        var k: Int = 1
        while k < 64 {
            var index: Int = 3 * (k - 1)
            if coder.decode(&ac[index]) != 0 {
                // End of block: everything above this is zero.
                return
            }
            while coder.decode(&ac[index + 1]) == 0 {
                index += 3
                k += 1
                guard k < 64 else {
                    throw .decoding(.invalidEntropyCodedSymbol)
                }
            }

            let sign: Int = coder.decode(&statistics.fixed)
            index += 2
            var magnitude: Int = coder.decode(&ac[index])

            if magnitude != 0, coder.decode(&ac[index]) != 0 {
                magnitude <<= 1
                // Low and high frequency coefficients get separate magnitude
                // ladders; `kx` is where the standard divides them.
                index = k <= acConditioning.kx ? 189 : 217
                while coder.decode(&ac[index]) != 0 {
                    magnitude <<= 1
                    guard magnitude != 0x8000 else {
                        throw .decoding(.invalidEntropyCodedSymbol)
                    }
                    index += 1
                }
            }

            var value: Int = magnitude
            index += 14
            var bit: Int = magnitude
            while true {
                bit >>= 1
                guard bit != 0 else {
                    break
                }
                if coder.decode(&ac[index]) != 0 {
                    value |= bit
                }
            }
            value += 1

            self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]] =
                .init(truncatingIfNeeded: sign != 0 ? -value : value)
            k += 1
        }
    }
}
