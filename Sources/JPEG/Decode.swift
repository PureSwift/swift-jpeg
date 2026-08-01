extension JPEG {
    /// The Huffman tables in effect at a point in the stream.
    ///
    /// DC and AC tables occupy separate slot spaces, so a scan naming table 0
    /// for DC and table 0 for AC is referring to two different tables.
    public struct Tables: Sendable {
        public var dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman]
        public var ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman]

        public init() {
            self.dc = [:]
            self.ac = [:]
        }

        /// Installs a table, replacing any previous definition of its slot.
        public mutating func push(_ table: JPEG.Table.Huffman) {
            switch table.class {
            case .dc:   self.dc[table.target] = table
            case .ac:   self.ac[table.target] = table
            }
        }
    }
}

extension JPEG.Data.Spectral {
    /// The tables and geometry one scan component needs, resolved once instead
    /// of per block.
    private struct Resolved {
        let plane: Int
        let sampling: JPEG.Component.Sampling
        let dc: JPEG.Table.Huffman
        let ac: JPEG.Table.Huffman
    }

    /// Decodes one sequential scan into this image's coefficients.
    ///
    /// Handles the baseline and extended sequential processes. Progressive
    /// scans are recognized and rejected rather than misdecoded.
    ///
    /// -   Parameters:
    ///     -   ecs: The scan's entropy coded data, raw, as the lexer produced
    ///         it — stuffing and restart markers intact.
    ///     -   scan: The scan header.
    ///     -   tables: The Huffman tables currently defined.
    ///     -   restartInterval: MCUs between restart markers, or 0 for none.
    public mutating func decode(
        _ ecs: [UInt8],
        scan: JPEG.Header.Scan,
        tables: JPEG.Tables,
        restartInterval: Int
    ) throws {
        guard !self.layout.process.isProgressive else {
            throw JPEG.DecodingError.unsupportedProcess(self.layout.process)
        }

        let planes: [Int] = try self.layout.validate(scan: scan)
        let resolved: [Resolved] = try zip(planes, scan.components).map {
            guard let dc: JPEG.Table.Huffman = tables.dc[$1.dc] else {
                throw JPEG.DecodingError.undefinedScanHuffmanTableReference($1.dc)
            }
            guard let ac: JPEG.Table.Huffman = tables.ac[$1.ac] else {
                throw JPEG.DecodingError.undefinedScanHuffmanTableReference($1.ac)
            }
            return .init(
                plane: $0,
                sampling: self.layout.planes[$0].sampling,
                dc: dc,
                ac: ac
            )
        }

        // An interleaved scan walks whole MCUs; a single-component scan walks
        // that component's own blocks, which is a different and usually smaller
        // grid. Everything below is written against `units`, so the two cases
        // differ only in what a unit means.
        let interleaved: Bool = resolved.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? self.layout.mcus
            : self.layout.blocks(plane: resolved[0].plane, scan: scan)
        let total: Int = units.x * units.y

        var decoded: Int = 0
        for interval: [UInt8] in try JPEG.Bitstream.intervals(
            of: ecs,
            restartInterval: restartInterval
        ) {
            var bits: JPEG.Bitstream = .init(interval)
            // The DC predictor is differential across blocks and resets at every
            // restart marker. That reset is the entire point of restarts: it is
            // what lets a decoder recover from a corrupt interval instead of
            // producing a wrong image from there to the bottom edge.
            var predictor: [Int32] = .init(repeating: 0, count: self.planes.count)

            let end: Int = restartInterval > 0
                ? Swift.min(total, decoded + restartInterval)
                : total

            while decoded < end {
                let unit: (x: Int, y: Int) = (x: decoded % units.x, y: decoded / units.x)

                for component: Resolved in resolved {
                    let blocks: (x: Int, y: Int) = interleaved
                        ? (x: component.sampling.x, y: component.sampling.y)
                        : (x: 1, y: 1)

                    for v: Int in 0 ..< blocks.y {
                        for h: Int in 0 ..< blocks.x {
                            let block: (x: Int, y: Int) = interleaved
                                ? (
                                    x: unit.x * component.sampling.x + h,
                                    y: unit.y * component.sampling.y + v
                                )
                                : unit

                            try self.decode(
                                block: block,
                                of: component,
                                from: &bits,
                                predictor: &predictor[component.plane]
                            )
                        }
                    }
                }

                decoded += 1
            }
        }

        guard decoded == total else {
            throw JPEG.DecodingError.truncatedEntropyCodedSegment(
                decoded: decoded,
                expected: total
            )
        }
    }

    /// Decodes one 8×8 block.
    ///
    /// The DC coefficient is coded as a difference from the previous block of
    /// the same component, so `predictor` carries across calls. The AC
    /// coefficients are coded as run-length and magnitude pairs walking the
    /// zigzag order, which is why the high-frequency tail — usually all zeros —
    /// costs one end-of-block symbol rather than 63 of them.
    private mutating func decode(
        block: (x: Int, y: Int),
        of component: Resolved,
        from bits: inout JPEG.Bitstream,
        predictor: inout Int32
    ) throws {
        let category: Int = .init(try component.dc.symbol(from: &bits))
        guard category <= 16 else {
            throw JPEG.DecodingError.invalidEntropyCodedSymbol
        }
        predictor &+= .init(bits.amplitude(category: category))
        self.planes[component.plane][x: block.x, y: block.y, z: 0] =
            .init(truncatingIfNeeded: predictor)

        var z: Int = 1
        while z < 64 {
            let symbol: UInt8 = try component.ac.symbol(from: &bits)
            let run: Int = .init(symbol >> 4)
            let size: Int = .init(symbol & 0x0F)

            guard size > 0 else {
                if run == 15 {
                    // ZRL: sixteen zeros, and the run continues.
                    z += 16
                    continue
                }
                // EOB: every remaining coefficient in this block is zero.
                return
            }

            z += run
            guard z < 64 else {
                throw JPEG.DecodingError.invalidEntropyCodedSymbol
            }

            self.planes[component.plane][
                x: block.x,
                y: block.y,
                z: JPEG.zigzag[z]
            ] = .init(truncatingIfNeeded: bits.amplitude(category: size))
            z += 1
        }
    }
}
