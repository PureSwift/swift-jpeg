extension JPEG {
    /// The symbol-to-code lookups a scan encodes with.
    ///
    /// The write-side counterpart of ``Tables``, built from it once per scan
    /// rather than per block.
    public struct Encoders: Sendable {
        public var dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder]
        public var ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder]

        /// Derives the lookups for every table currently defined.
        public init(_ tables: JPEG.Tables) {
            self.dc = tables.dc.mapValues { $0.encoder() }
            self.ac = tables.ac.mapValues { $0.encoder() }
        }
    }
}

extension JPEG.Data.Spectral {
    /// The lookups and geometry one scan component needs, resolved once instead
    /// of per block.
    private struct Bound {
        let plane: Int
        let sampling: JPEG.Component.Sampling
        let dc: JPEG.Table.Huffman.Encoder
        let ac: JPEG.Table.Huffman.Encoder
    }

    /// Entropy codes one sequential scan.
    ///
    /// The mirror of the decoder: the same unit walk, the same restart
    /// handling, the same interleaving rules — run in the other direction.
    ///
    /// -   Returns:
    ///     The entropy coded data, with byte stuffing and restart markers in
    ///     place, ready to follow a scan header.
    public func encode(
        scan: JPEG.Header.Scan,
        encoders: JPEG.Encoders,
        restartInterval: Int
    ) throws -> [UInt8] {
        guard case .baseline = self.layout.process else {
            throw JPEG.EncodingError.unsupportedProcess(self.layout.process)
        }

        let planes: [Int] = try self.layout.validate(scan: scan)
        let bound: [Bound] = try zip(planes, scan.components).map {
            guard let dc: JPEG.Table.Huffman.Encoder = encoders.dc[$1.dc] else {
                throw JPEG.EncodingError.undefinedHuffmanTable($1.dc, .dc)
            }
            guard let ac: JPEG.Table.Huffman.Encoder = encoders.ac[$1.ac] else {
                throw JPEG.EncodingError.undefinedHuffmanTable($1.ac, .ac)
            }
            return .init(
                plane: $0,
                sampling: self.layout.planes[$0].sampling,
                dc: dc,
                ac: ac
            )
        }

        let interleaved: Bool = bound.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? self.layout.mcus
            : self.layout.blocks(plane: bound[0].plane, scan: scan)
        let total: Int = units.x * units.y

        var output: [UInt8] = []
        var bits: JPEG.BitstreamWriter = .init()
        var predictor: [Int32] = .init(repeating: 0, count: self.planes.count)
        var phase: Int = 0

        for index: Int in 0 ..< total {
            let unit: (x: Int, y: Int) = (x: index % units.x, y: index / units.x)

            for component: Bound in bound {
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

                        try self.encode(
                            block: block,
                            of: component,
                            to: &bits,
                            predictor: &predictor[component.plane]
                        )
                    }
                }
            }

            // A restart marker is byte aligned, so the bit writer has to be
            // flushed and padded before one is emitted. No marker follows the
            // final interval: the scan simply ends.
            if restartInterval > 0,
               (index + 1) % restartInterval == 0,
               index + 1 < total
            {
                output.append(contentsOf: bits.finish())
                output.append(0xFF)
                output.append(0xD0 + .init(truncatingIfNeeded: phase))
                phase = (phase + 1) & 7
                predictor = .init(repeating: 0, count: self.planes.count)
            }
        }

        output.append(contentsOf: bits.finish())
        return output
    }

    /// Entropy codes one 8×8 block.
    private func encode(
        block: (x: Int, y: Int),
        of component: Bound,
        to bits: inout JPEG.BitstreamWriter,
        predictor: inout Int32
    ) throws {
        let plane: Plane = self.planes[component.plane]

        // The DC coefficient goes out as a difference from the previous block
        // of the same component.
        let dc: Int32 = .init(plane[x: block.x, y: block.y, z: 0])
        let difference: Int = .init(dc - predictor)
        predictor = dc

        let amplitude: (category: Int, bits: UInt16) =
            JPEG.BitstreamWriter.amplitude(of: difference)
        guard amplitude.category <= 15 else {
            throw JPEG.EncodingError.coefficientOutOfRange(difference)
        }
        component.dc.encode(.init(truncatingIfNeeded: amplitude.category), to: &bits)
        bits.write(amplitude.bits, count: amplitude.category)

        // AC coefficients go out as run-length and magnitude pairs along the
        // zigzag. A run of more than fifteen zeros needs an explicit ZRL for
        // each full sixteen, because only four bits carry the run.
        var run: Int = 0
        for z: Int in 1 ..< 64 {
            let value: Int = .init(plane[x: block.x, y: block.y, z: JPEG.zigzag[z]])

            guard value != 0 else {
                run += 1
                continue
            }

            while run >= 16 {
                component.ac.encode(0xF0, to: &bits)
                run -= 16
            }

            let amplitude: (category: Int, bits: UInt16) =
                JPEG.BitstreamWriter.amplitude(of: value)
            guard amplitude.category <= 15 else {
                throw JPEG.EncodingError.coefficientOutOfRange(value)
            }
            component.ac.encode(
                .init(truncatingIfNeeded: run << 4 | amplitude.category),
                to: &bits
            )
            bits.write(amplitude.bits, count: amplitude.category)
            run = 0
        }

        // A trailing run is not coded position by position: one end-of-block
        // symbol says the rest of the block is zero. This is where most of the
        // compression in a high-frequency-poor block comes from.
        if run > 0 {
            component.ac.encode(0x00, to: &bits)
        }
    }
}
