extension JPEG {
    /// The symbol-to-code lookups a scan encodes with.
    ///
    /// The write-side counterpart of ``Tables``, built from it once per scan
    /// rather than per block.
    public struct Encoders {
        public var dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder]
        public var ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder]

        /// Derives the lookups for every table currently defined.
        public init(_ tables: JPEG.Tables) {
            self.dc = tables.dc.mapValues { $0.encoder() }
            self.ac = tables.ac.mapValues { $0.encoder() }
        }

        private init(
            dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder],
            ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder]
        ) {
            self.dc = dc
            self.ac = ac
        }

        /// Encoders that tally symbols instead of emitting them, one counter
        /// per slot the given tables define.
        ///
        /// This is the first of the two passes an optimal table costs: walk the
        /// image once to learn the symbol distribution, build tables from it,
        /// then walk it again to write.
        public static func counting(
            like tables: JPEG.Tables
        ) -> (encoders: Self, dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder.Counter],
              ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder.Counter])
        {
            let dc: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder.Counter] =
                tables.dc.mapValues { _ in .init() }
            let ac: [JPEG.Table.Huffman.Key: JPEG.Table.Huffman.Encoder.Counter] =
                tables.ac.mapValues { _ in .init() }
            return (
                encoders: .init(
                    dc: dc.mapValues { .counting(into: $0) },
                    ac: ac.mapValues { .counting(into: $0) }
                ),
                dc: dc,
                ac: ac
            )
        }
    }
}

extension JPEG.Data.Spectral {
    /// The lookups and geometry one scan component needs, resolved once instead
    /// of per block.
    private struct Bound {
        let plane: Int
        let sampling: JPEG.Component.Sampling
        // Optional for the same reason the decoder's are: a progressive scan
        // names only the class it codes, and a DC refinement scan names
        // neither, since it is not Huffman coded at all.
        let dc: JPEG.Table.Huffman.Encoder?
        let ac: JPEG.Table.Huffman.Encoder?
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
    ) throws(JPEG.Failure) -> [UInt8] {
        let process: JPEG.Process = self.layout.process
        switch process {
        case .baseline,
             .extended(coding: .huffman, differential: false),
             .progressive(coding: .huffman, differential: false):
            break
        default:
            throw .encoding(.unsupportedProcess(process))
        }

        let kind: JPEG.Header.Scan.Kind = scan.kind(process: process)
        let needsDC: Bool
        let needsAC: Bool
        switch kind {
        case .sequential:           (needsDC, needsAC) = (true, true)
        case .dc(refining: let r):  (needsDC, needsAC) = (!r, false)
        case .ac:                   (needsDC, needsAC) = (false, true)
        }

        let planes: [Int] = try self.layout.validate(scan: scan)
        let bound: [Bound] = try zip(planes, scan.components).map {
            (plane, component) throws(JPEG.Failure) -> Bound in
            var dc: JPEG.Table.Huffman.Encoder?
            var ac: JPEG.Table.Huffman.Encoder?
            if needsDC {
                guard let table: JPEG.Table.Huffman.Encoder = encoders.dc[component.dc] else {
                    throw .encoding(.undefinedHuffmanTable(component.dc, .dc))
                }
                dc = table
            }
            if needsAC {
                guard let table: JPEG.Table.Huffman.Encoder = encoders.ac[component.ac] else {
                    throw .encoding(.undefinedHuffmanTable(component.ac, .ac))
                }
                ac = table
            }
            return .init(
                plane: plane,
                sampling: self.layout.planes[plane].sampling,
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
        var progression: JPEG.Progression = .init()
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

                        switch kind {
                        case .sequential:
                            try self.encode(
                                block: block,
                                of: component,
                                to: &bits,
                                predictor: &predictor[component.plane]
                            )

                        case .dc(refining: false):
                            try self.encode(
                                dcFirst: block,
                                plane: component.plane,
                                encoder: component.dc!,
                                to: &bits,
                                predictor: &predictor[component.plane],
                                approximation: scan.approximation
                            )

                        case .dc(refining: true):
                            self.encode(
                                dcRefining: block,
                                plane: component.plane,
                                to: &bits,
                                approximation: scan.approximation
                            )

                        case .ac(refining: false):
                            try self.encode(
                                acFirst: block,
                                plane: component.plane,
                                encoder: component.ac!,
                                to: &bits,
                                band: scan.band,
                                approximation: scan.approximation,
                                progression: &progression
                            )

                        case .ac(refining: true):
                            try self.encode(
                                acRefining: block,
                                plane: component.plane,
                                encoder: component.ac!,
                                to: &bits,
                                band: scan.band,
                                approximation: scan.approximation,
                                progression: &progression
                            )
                        }
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
                // A run cannot span a restart marker, so it is closed first.
                if let encoder: JPEG.Table.Huffman.Encoder = bound[0].ac {
                    try progression.flush(to: &bits, using: encoder)
                }
                progression = .init()
                output.append(contentsOf: bits.finish())
                output.append(0xFF)
                output.append(0xD0 + .init(truncatingIfNeeded: phase))
                phase = (phase + 1) & 7
                predictor = .init(repeating: 0, count: self.planes.count)
            }
        }

        // Whatever the scan ended in the middle of has to be written before
        // the padding, or the decoder never learns the last blocks were empty.
        if let encoder: JPEG.Table.Huffman.Encoder = bound[0].ac {
            try progression.flush(to: &bits, using: encoder)
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
    ) throws(JPEG.Failure) {
        guard
        let dc: JPEG.Table.Huffman.Encoder = component.dc,
        let ac: JPEG.Table.Huffman.Encoder = component.ac
        else {
            return
        }
        // A block the scan codes but the plane does not contain. It is coded as
        // all zeros, because the decoder walks the same grid and expects
        // something here.
        //
        // No image reaches this, for the reason the decoder's counterpart gives:
        // `blocks(plane:)` rounds every plane up to whole MCUs, so the padding
        // this looks like it handles is already inside the plane. It is kept in
        // both directions because the alternative on the read side is a pointer
        // write past the end of a block.
        guard self.planes[component.plane].contains(x: block.x, y: block.y) else {
            return try withUnsafeTemporaryAllocation(of: Int16.self, capacity: 64) {
                (zeros) throws(JPEG.Failure) in
                zeros.initialize(repeating: 0)
                return try Self.encode(
                    .init(zeros), dc: dc, ac: ac, to: &bits, predictor: &predictor
                )
            }
        }

        try self.planes[component.plane].withBlock(x: block.x, y: block.y) {
            (coefficients) throws(JPEG.Failure) in
            try Self.encode(coefficients, dc: dc, ac: ac, to: &bits, predictor: &predictor)
        }
    }

    /// Encodes one sequential block from 64 coefficients.
    ///
    /// Reading them through a pointer rather than the plane subscript: the
    /// subscript range-checks the block coordinates for every one of the 64,
    /// and taking a copy of the plane to read from — which is what the
    /// straightforward spelling does — retains its storage once per block.
    private static func encode(
        _ coefficients: UnsafeBufferPointer<Int16>,
        dc: JPEG.Table.Huffman.Encoder,
        ac: JPEG.Table.Huffman.Encoder,
        to bits: inout JPEG.BitstreamWriter,
        predictor: inout Int32
    ) throws(JPEG.Failure) {
        // The DC coefficient goes out as a difference from the previous block
        // of the same component.
        let value: Int32 = .init(coefficients[0])
        let difference: Int = .init(value - predictor)
        predictor = value

        let amplitude: (category: Int, bits: UInt16) =
            JPEG.BitstreamWriter.amplitude(of: difference)
        guard amplitude.category <= 15 else {
            throw .encoding(.coefficientOutOfRange(difference))
        }
        try dc.encode(.init(truncatingIfNeeded: amplitude.category), to: &bits)
        bits.write(amplitude.bits, count: amplitude.category)

        // AC coefficients go out as run-length and magnitude pairs along the
        // zigzag. A run of more than fifteen zeros needs an explicit ZRL for
        // each full sixteen, because only four bits carry the run.
        var run: Int = 0
        for z: Int in 1 ..< 64 {
            let value: Int = .init(coefficients[JPEG.zigzag[z]])

            guard value != 0 else {
                run += 1
                continue
            }

            while run >= 16 {
                try ac.encode(0xF0, to: &bits)
                run -= 16
            }

            let amplitude: (category: Int, bits: UInt16) =
                JPEG.BitstreamWriter.amplitude(of: value)
            guard amplitude.category <= 15 else {
                throw .encoding(.coefficientOutOfRange(value))
            }
            try ac.encode(
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
            try ac.encode(0x00, to: &bits)
        }
    }
}
