extension JPEG {
    /// A predictor for the lossless process.
    ///
    /// Lossless JPEG shares almost nothing with the DCT-based processes but the
    /// marker structure. There is no transform, no quantization and no
    /// frequency domain at all: each sample is predicted from its already-coded
    /// neighbours, and only the prediction error is coded. That error is
    /// usually small and clusters near zero, which is where the compression
    /// comes from — and because nothing is discarded, the samples come back
    /// bit-exact.
    ///
    /// The three neighbours, for a sample at `(x, y)`:
    ///
    ///     Rc Rb
    ///     Ra  ?
    ///
    /// T.81 Table H.1 defines seven combinations of them. Which one suits an
    /// image depends on whether its detail runs horizontally, vertically or
    /// diagonally, and no single choice wins everywhere.
    public enum Predictor: Int, Sendable, Hashable, CaseIterable {
        /// `Ra` — the sample to the left. Suits horizontal detail.
        case horizontal = 1
        /// `Rb` — the sample above. Suits vertical detail.
        case vertical = 2
        /// `Rc` — the sample above and to the left.
        case diagonal = 3
        /// `Ra + Rb - Rc`, which extrapolates a plane through all three.
        case plane = 4
        /// `Ra + (Rb - Rc)/2`.
        case horizontalPlane = 5
        /// `Rb + (Ra - Rc)/2`.
        case verticalPlane = 6
        /// `(Ra + Rb)/2`, the average of the two nearest.
        case average = 7

        /// Predicts a sample from its neighbours.
        ///
        /// The halvings are arithmetic right shifts, not divisions: they round
        /// toward negative infinity, and rounding toward zero instead would
        /// disagree with every other implementation on negative differences.
        func predict(a: Int32, b: Int32, c: Int32) -> Int32 {
            switch self {
            case .horizontal:       return a
            case .vertical:         return b
            case .diagonal:         return c
            case .plane:            return a &+ b &- c
            case .horizontalPlane:  return a &+ ((b &- c) >> 1)
            case .verticalPlane:    return b &+ ((a &- c) >> 1)
            case .average:          return (a &+ b) >> 1
            }
        }
    }
}

extension JPEG.Bitstream {
    /// Reads a lossless difference of the given magnitude category.
    ///
    /// The same `EXTEND` procedure the DCT processes use, with one addition:
    /// category 16 carries no bits at all and always means −32768. That case
    /// exists because a 16-bit difference needs 17 values' worth of range on
    /// the negative side, and the standard spends the otherwise-unused category
    /// on it rather than widening every other one.
    mutating func difference(category: Int) -> Int32 {
        guard category != 16 else {
            return -32768
        }
        return .init(self.amplitude(category: category))
    }
}

extension JPEG.BitstreamWriter {
    /// Splits a lossless difference into its category and bits.
    ///
    /// -   Returns:
    ///     The category, and how many bits follow. Category 16 writes none.
    static func difference(of value: Int32) -> (category: Int, bits: UInt16, count: Int) {
        // Differences are coded modulo 2^16, so the encoder and decoder agree
        // on the wrap rather than on the true arithmetic value.
        let wrapped: Int32 = value & 0xFFFF
        guard wrapped != 0x8000 else {
            return (category: 16, bits: 0, count: 0)
        }
        let signed: Int = .init(wrapped >= 0x8000 ? wrapped - 0x10000 : wrapped)
        let amplitude: (category: Int, bits: UInt16) = Self.amplitude(of: signed)
        // Every category but 16 writes exactly its own number of bits.
        return (amplitude.category, amplitude.bits, amplitude.category)
    }
}

extension JPEG.Data {
    /// An image coded without loss.
    ///
    /// Just samples: there is no coefficient tier here because the lossless
    /// process has no transform to produce one. The samples are exactly those
    /// that were encoded.
    public struct Lossless<Format> where Format: JPEG.Format {
        /// The image geometry and component structure.
        public private(set) var layout: JPEG.Layout<Format>
        /// One plane per component, at that component's own resolution, padded
        /// out to whole minimum coded units.
        public private(set) var planes: [JPEG.Data.Planar<Format>.Plane]

        init(layout: JPEG.Layout<Format>) {
            self.layout = layout
            // A lossless minimum coded unit is `scale` *samples*, not `scale`
            // blocks of 64 — there are no blocks. Everything about the geometry
            // follows from that one difference.
            let units: (x: Int, y: Int) = Lossless.units(of: layout)
            self.planes = layout.planes.map {
                .init(size: (x: units.x * $0.sampling.x, y: units.y * $0.sampling.y))
            }
        }

        /// The number of minimum coded units spanning the image.
        static func units(of layout: JPEG.Layout<Format>) -> (x: Int, y: Int) {
            (
                x: (layout.width + layout.scale.x - 1) / layout.scale.x,
                y: (layout.height + layout.scale.y - 1) / layout.scale.y
            )
        }
    }
}

extension JPEG.Data.Lossless {
    public subscript(plane: Int) -> JPEG.Data.Planar<Format>.Plane {
        _read {
            yield self.planes[plane]
        }
        _modify {
            yield &self.planes[plane]
        }
    }

    /// Reinterprets this image as planar samples.
    ///
    /// A no-op beyond the type: the lossless representation *is* planar
    /// samples. It exists so the rest of the library — upsampling, colour
    /// conversion, the C boundary — works on lossless images unchanged.
    public func planar() -> JPEG.Data.Planar<Format> {
        .init(planes: self.planes, layout: self.layout)
    }

    /// Decodes to interleaved full-resolution samples.
    public func rectangular() -> JPEG.Data.Rectangular<Format> {
        self.planar().interleaved()
    }
}

extension JPEG.Data.Lossless {
    /// The predictor to use at `(x, y)`, given the one the scan selected.
    ///
    /// The edges cannot use the scan's predictor because their neighbours do
    /// not exist. T.81 §H.1.2.1 fixes what to do instead: the very first sample
    /// has no neighbours at all and is predicted from the midpoint of the
    /// sample range; the rest of the first row has only a left neighbour; and
    /// the first column of every later row has only the one above.
    private static func predictor(
        _ selected: JPEG.Predictor,
        x: Int,
        y: Int,
        first: Bool
    ) -> JPEG.Predictor? {
        if y == 0 || first {
            // `first` marks the row that opens a restart interval, which is
            // treated exactly like the top of the image.
            return x == 0 ? nil : .horizontal
        }
        return x == 0 ? .vertical : selected
    }

    /// Decodes one lossless scan.
    ///
    /// -   Parameters:
    ///     -   ecs: The scan's entropy coded data, stuffing and restart markers
    ///         intact.
    ///     -   scan: The scan header. Its band carries the predictor and its
    ///         low bit position the point transform.
    public mutating func decode(
        _ ecs: [UInt8],
        scan: JPEG.Header.Scan,
        tables: JPEG.Tables,
        restartInterval: Int
    ) throws {
        guard let selected: JPEG.Predictor = .init(rawValue: scan.band.lowerBound) else {
            throw JPEG.ParsingError.invalidPredictor(scan.band.lowerBound)
        }

        let planes: [Int] = try self.layout.validate(scan: scan)
        let decoders: [JPEG.Table.Huffman] = try scan.components.map {
            guard let table: JPEG.Table.Huffman = tables.dc[$0.dc] else {
                throw JPEG.DecodingError.undefinedScanHuffmanTableReference($0.dc)
            }
            return table
        }

        let interleaved: Bool = planes.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? Self.units(of: self.layout)
            : (
                x: self.layout.samples(plane: planes[0]).x,
                y: self.layout.samples(plane: planes[0]).y
            )
        let total: Int = units.x * units.y

        // The point transform divides every sample by a power of two before
        // coding, which is the one way the "lossless" process can lose
        // something — and the only reason it is ever anything but zero.
        let transform: Int32 = .init(scan.approximation)
        let midpoint: Int32 =
            1 << Int32(self.layout.format.precision - scan.approximation - 1)

        var decoded: Int = 0
        for interval: [UInt8] in try JPEG.Bitstream.intervals(
            of: ecs, restartInterval: restartInterval
        ) {
            var bits: JPEG.Bitstream = .init(interval)
            let start: Int = decoded
            let end: Int = restartInterval > 0
                ? Swift.min(total, decoded + restartInterval)
                : total

            while decoded < end {
                let unit: (x: Int, y: Int) = (x: decoded % units.x, y: decoded / units.x)

                for (index, plane): (Int, Int) in planes.enumerated() {
                    let sampling: JPEG.Component.Sampling = interleaved
                        ? self.layout.planes[plane].sampling
                        : .init(x: 1, y: 1)

                    for v: Int in 0 ..< sampling.y {
                        for h: Int in 0 ..< sampling.x {
                            let x: Int = interleaved
                                ? unit.x * sampling.x + h
                                : unit.x
                            let y: Int = interleaved
                                ? unit.y * sampling.y + v
                                : unit.y

                            let category: Int = .init(
                                try decoders[index].symbol(from: &bits)
                            )
                            guard category <= 16 else {
                                throw JPEG.DecodingError.invalidEntropyCodedSymbol
                            }
                            let difference: Int32 = bits.difference(category: category)

                            let prediction: Int32
                            if let rule: JPEG.Predictor = Self.predictor(
                                selected, x: x, y: y, first: decoded == start && start > 0
                            ) {
                                prediction = rule.predict(
                                    a: .init(self.planes[plane][x: x - 1, y: y]),
                                    b: .init(self.planes[plane][x: x, y: y - 1]),
                                    c: .init(self.planes[plane][x: x - 1, y: y - 1])
                                )
                            } else {
                                prediction = midpoint
                            }

                            // Modulo 2^16, matching the encoder's wrap.
                            let value: Int32 = (prediction &+ difference) & 0xFFFF
                            self.planes[plane][x: x, y: y] =
                                .init(truncatingIfNeeded: value << transform)
                        }
                    }
                }
                decoded += 1
            }
        }

        guard decoded == total else {
            throw JPEG.DecodingError.truncatedEntropyCodedSegment(
                decoded: decoded, expected: total
            )
        }
    }
}

extension JPEG.Data.Lossless {
    /// Entropy codes one lossless scan.
    ///
    /// The exact mirror of the decoder: the same unit walk, the same edge
    /// rules, and the same modulo-2^16 wrap. Sharing the predictor definitions
    /// between the two is what makes a round trip meaningful — a mistake in one
    /// of them shows up as a failed round trip rather than cancelling out.
    public func encode(
        scan: JPEG.Header.Scan,
        encoders: JPEG.Encoders,
        restartInterval: Int
    ) throws -> [UInt8] {
        guard let selected: JPEG.Predictor = .init(rawValue: scan.band.lowerBound) else {
            throw JPEG.ParsingError.invalidPredictor(scan.band.lowerBound)
        }

        let planes: [Int] = try self.layout.validate(scan: scan)
        let tables: [JPEG.Table.Huffman.Encoder] = try scan.components.map {
            guard let table: JPEG.Table.Huffman.Encoder = encoders.dc[$0.dc] else {
                throw JPEG.EncodingError.undefinedHuffmanTable($0.dc, .dc)
            }
            return table
        }

        let interleaved: Bool = planes.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? Self.units(of: self.layout)
            : (
                x: self.layout.samples(plane: planes[0]).x,
                y: self.layout.samples(plane: planes[0]).y
            )
        let total: Int = units.x * units.y

        let transform: Int32 = .init(scan.approximation)
        let midpoint: Int32 =
            1 << Int32(self.layout.format.precision - scan.approximation - 1)

        var output: [UInt8] = []
        var bits: JPEG.BitstreamWriter = .init()
        var phase: Int = 0
        var start: Int = 0

        for index: Int in 0 ..< total {
            let unit: (x: Int, y: Int) = (x: index % units.x, y: index / units.x)

            for (component, plane): (Int, Int) in planes.enumerated() {
                let sampling: JPEG.Component.Sampling = interleaved
                    ? self.layout.planes[plane].sampling
                    : .init(x: 1, y: 1)

                for v: Int in 0 ..< sampling.y {
                    for h: Int in 0 ..< sampling.x {
                        let x: Int = interleaved ? unit.x * sampling.x + h : unit.x
                        let y: Int = interleaved ? unit.y * sampling.y + v : unit.y

                        // The stored sample carries the point transform; the
                        // coded value is what remains after removing it.
                        let sample: Int32 =
                            .init(self.planes[plane][x: x, y: y]) >> transform

                        let prediction: Int32
                        if let rule: JPEG.Predictor = Self.predictor(
                            selected, x: x, y: y, first: index == start && start > 0
                        ) {
                            prediction = rule.predict(
                                a: .init(self.planes[plane][x: x - 1, y: y]) >> transform,
                                b: .init(self.planes[plane][x: x, y: y - 1]) >> transform,
                                c: .init(self.planes[plane][x: x - 1, y: y - 1]) >> transform
                            )
                        } else {
                            prediction = midpoint
                        }

                        let coded: (category: Int, bits: UInt16, count: Int) =
                            JPEG.BitstreamWriter.difference(of: sample &- prediction)
                        try tables[component].encode(
                            .init(truncatingIfNeeded: coded.category), to: &bits
                        )
                        bits.write(coded.bits, count: coded.count)
                    }
                }
            }

            if restartInterval > 0,
               (index + 1) % restartInterval == 0,
               index + 1 < total
            {
                output.append(contentsOf: bits.finish())
                output.append(0xFF)
                output.append(0xD0 + .init(truncatingIfNeeded: phase))
                phase = (phase + 1) & 7
                start = index + 1
            }
        }

        output.append(contentsOf: bits.finish())
        return output
    }

    /// Counts the symbols one lossless scan would emit.
    ///
    /// The Annex K tables describe DCT statistics and are a poor fit for
    /// prediction residuals, which cluster far more tightly around zero, so a
    /// lossless image always builds its own.
    func tables(for scan: JPEG.Header.Scan, restartInterval: Int) throws -> JPEG.Tables {
        var seed: JPEG.Tables = .init()
        for component: JPEG.ScanComponent in scan.components {
            seed.push(
                try .init(
                    counts: [1] + .init(repeating: 0, count: 15),
                    values: [0], target: component.dc, class: .dc
                )
            )
        }

        let counting = JPEG.Encoders.counting(like: seed)
        _ = try self.encode(
            scan: scan, encoders: counting.encoders, restartInterval: restartInterval
        )

        var tables: JPEG.Tables = .init()
        for (key, counter) in counting.dc {
            tables.push(try .optimal(frequencies: counter.frequencies, target: key, class: .dc))
        }
        return tables
    }
}

extension JPEG.Data.Lossless {
    /// Decodes a lossless image from a byte source.
    ///
    /// A separate driver from the DCT one rather than a branch inside it: the
    /// two share the segment structure and nothing else, and threading a
    /// process check through every step of the other would obscure both.
    public static func decompress<Source>(
        stream: inout Source
    ) throws -> Self where Source: JPEG.Bytestream.Source {
        try stream.start()

        var tables: JPEG.Tables = .init()
        var restartInterval: Int = 0
        var image: Self?
        var pending: (JPEG.Marker, [UInt8])?

        loop:
        while true {
            let marker: JPEG.Marker
            let data: [UInt8]
            if let held: (JPEG.Marker, [UInt8]) = pending {
                (marker, data) = held
                pending = nil
            } else {
                (marker, data) = try stream.segment()
            }

            switch marker {
            case .end:
                break loop

            case .frame(let process):
                guard case .lossless = process else {
                    throw JPEG.DecodingError.unsupportedProcess(process)
                }
                guard image == nil else {
                    throw JPEG.DecodingError.duplicateFrameHeader
                }
                let frame: JPEG.Header.Frame = try .parse(data, process: process)
                image = .init(layout: try .init(frame: frame))

            case .huffman:
                for table: JPEG.Table.Huffman in try JPEG.Table.Huffman.parse(data) {
                    tables.push(table)
                }

            case .restartInterval:
                restartInterval = try JPEG.Header.RestartInterval.parse(data).interval

            case .scan:
                guard var decoding: Self = image else {
                    throw JPEG.DecodingError.missingFrameHeader
                }
                let scan: JPEG.Header.Scan = try .parse(
                    data, process: decoding.layout.process
                )
                let (ecs, next): ([UInt8], (JPEG.Marker, [UInt8])) =
                    try stream.segment(prefix: true)
                try decoding.decode(
                    ecs, scan: scan, tables: tables, restartInterval: restartInterval
                )
                image = decoding
                pending = next

            default:
                continue loop
            }
        }

        guard let image: Self = image else {
            throw JPEG.DecodingError.missingFrameHeader
        }
        return image
    }

    /// Decodes a lossless image from a buffer.
    public static func decompress(_ bytes: [UInt8]) throws -> Self {
        var stream: JPEG.Bytestream.Cursor = .init(bytes)
        return try self.decompress(stream: &stream)
    }
}

extension JPEG.Data.Lossless {
    /// The frame header describing this image.
    func frame() throws -> JPEG.Header.Frame {
        guard 1 ... 65535 ~= self.layout.width, 1 ... 65535 ~= self.layout.height else {
            throw JPEG.EncodingError.imageTooLarge(
                width: self.layout.width, height: self.layout.height
            )
        }
        var components: [JPEG.Component.Key: JPEG.Component] = [:]
        for (plane, key): (Int, JPEG.Component.Key) in self.layout.keys.enumerated() {
            components[key] = self.layout.planes[plane]
        }
        return .init(
            process: self.layout.process,
            precision: self.layout.format.precision,
            width: self.layout.width,
            height: self.layout.height,
            components: components,
            order: self.layout.keys
        )
    }

    /// Writes this image as a complete lossless JPEG.
    ///
    /// -   Parameters:
    ///     -   predictor: Which of the seven to use. No single one is best for
    ///         every image; `.plane` is a reasonable default and is what most
    ///         encoders pick.
    ///     -   transform: The point transform, which divides every sample by
    ///         `2^transform` before coding. Zero is genuinely lossless;
    ///         anything else trades exactness for size and is the only way this
    ///         process loses information.
    public func compress<Destination>(
        stream: inout Destination,
        predictor: JPEG.Predictor = .plane,
        transform: Int = 0,
        restartInterval: Int = 0,
        metadata: [(marker: JPEG.Marker, body: [UInt8])] = []
    ) throws where Destination: JPEG.Bytestream.Destination {
        guard 0 ..< self.layout.format.precision ~= transform else {
            throw JPEG.EncodingError.unsupportedPrecision(self.layout.format.precision)
        }

        let scan: JPEG.Header.Scan = .init(
            band: predictor.rawValue ..< predictor.rawValue + 1,
            bits: transform ..< Int.max,
            components: self.layout.keys.enumerated().map {
                let slot: JPEG.Table.Huffman.Key = .init($0.offset == 0 ? 0 : 1)
                return .init(component: $0.element, dc: slot, ac: slot)
            }
        )

        try stream.format(marker: .start)
        for segment: (marker: JPEG.Marker, body: [UInt8]) in metadata {
            try stream.format(marker: segment.marker, body: segment.body)
        }
        // No quantization tables: there is nothing to quantize.
        try stream.format(
            marker: .frame(self.layout.process), body: try self.frame().serialized()
        )

        let tables: JPEG.Tables = try self.tables(
            for: scan, restartInterval: restartInterval
        )
        for table: JPEG.Table.Huffman in tables.dc.values.sorted(by: { $0.target < $1.target }) {
            try stream.format(marker: .huffman, body: table.serialized())
        }

        if restartInterval > 0 {
            try stream.format(
                marker: .restartInterval,
                body: [
                    .init(truncatingIfNeeded: restartInterval >> 8),
                    .init(truncatingIfNeeded: restartInterval),
                ]
            )
        }

        try stream.format(marker: .scan, body: scan.serialized(process: self.layout.process))
        let ecs: [UInt8] = try self.encode(
            scan: scan, encoders: .init(tables), restartInterval: restartInterval
        )
        guard stream.write(ecs) != nil else {
            throw JPEG.EncodingError.unsupportedProcess(self.layout.process)
        }
        try stream.format(marker: .end)
    }
}

extension JPEG.Data.Lossless {
    /// Creates an image from interleaved samples.
    ///
    /// Each component is sampled down from the interleaved source at its own
    /// resolution. Subsampling a lossless image is legal but unusual — it
    /// discards samples outright, which is at odds with the point of the
    /// process — so the common case is every component at full resolution.
    public init(layout: JPEG.Layout<Format>, values: [UInt16]) {
        self.init(layout: layout)

        let stride: Int = layout.planes.count
        for plane: Int in layout.planes.indices {
            let sampling: JPEG.Component.Sampling = layout.planes[plane].sampling
            let size: (x: Int, y: Int) = self.planes[plane].size

            for y: Int in 0 ..< size.y {
                let row: Int = Swift.min(
                    y * layout.scale.y / sampling.y, layout.height - 1
                )
                for x: Int in 0 ..< size.x {
                    let column: Int = Swift.min(
                        x * layout.scale.x / sampling.x, layout.width - 1
                    )
                    self.planes[plane][x: x, y: y] =
                        values[(row * layout.width + column) * stride + plane]
                }
            }
        }
    }
}
