extension JPEG.Header.Frame {
    /// Serializes this header as a start-of-frame segment body.
    public func serialized() -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(6 + 3 * self.order.count)

        data.append(.init(truncatingIfNeeded: self.precision))
        data.append(.init(truncatingIfNeeded: self.height >> 8))
        data.append(.init(truncatingIfNeeded: self.height))
        data.append(.init(truncatingIfNeeded: self.width >> 8))
        data.append(.init(truncatingIfNeeded: self.width))
        data.append(.init(truncatingIfNeeded: self.order.count))

        for key: JPEG.Component.Key in self.order {
            guard let component: JPEG.Component = self.components[key] else {
                continue
            }
            data.append(key.value)
            data.append(
                .init(truncatingIfNeeded: component.sampling.x << 4 | component.sampling.y)
            )
            data.append(.init(truncatingIfNeeded: component.selector.value))
        }

        return data
    }
}

extension JPEG.Header.Scan {
    /// Serializes this header as a start-of-scan segment body.
    public func serialized() -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(4 + 2 * self.components.count)

        data.append(.init(truncatingIfNeeded: self.components.count))
        for component: JPEG.ScanComponent in self.components {
            data.append(component.component.value)
            data.append(
                .init(truncatingIfNeeded: component.dc.value << 4 | component.ac.value)
            )
        }

        data.append(.init(truncatingIfNeeded: self.band.lowerBound))
        data.append(.init(truncatingIfNeeded: self.band.upperBound - 1))
        // A first pass writes a high field of zero; the range's sentinel upper
        // bound is not a bit position and must not be written.
        let high: Int = self.isFirstPass ? 0 : self.bits.upperBound
        data.append(.init(truncatingIfNeeded: high << 4 | self.bits.lowerBound))

        return data
    }
}

extension JPEG.Bytestream.Destination {
    /// Writes a marker and, if it takes one, its length-prefixed body.
    ///
    /// The length field counts its own two bytes, which is the detail that
    /// makes an off-by-two here look like a corrupt file several segments
    /// later.
    public mutating func format(marker: JPEG.Marker, body: [UInt8] = []) throws {
        guard self.write([0xFF, marker.code]) != nil else {
            throw JPEG.EncodingError.unsupportedProcess(.baseline)
        }
        guard marker.hasPayload else {
            return
        }

        let length: Int = body.count + 2
        guard length <= 65535 else {
            throw JPEG.EncodingError.imageTooLarge(width: length, height: 0)
        }
        guard
        self.write([.init(truncatingIfNeeded: length >> 8), .init(truncatingIfNeeded: length)])
            != nil,
        body.isEmpty || self.write(body) != nil
        else {
            throw JPEG.EncodingError.unsupportedProcess(.baseline)
        }
    }
}

extension Array: JPEG.Bytestream.Destination where Element == UInt8 {
    /// Appends to this array.
    public mutating func write(_ bytes: [UInt8]) -> Void? {
        self.append(contentsOf: bytes)
        return ()
    }
}

extension JPEG.Data.Spectral {
    /// The frame header describing this image.
    func frame() throws -> JPEG.Header.Frame {
        guard 1 ... 65535 ~= self.layout.width, 1 ... 65535 ~= self.layout.height else {
            throw JPEG.EncodingError.imageTooLarge(
                width: self.layout.width,
                height: self.layout.height
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

    /// Returns tables that can actually code this image.
    ///
    /// The Annex K tables are used when they suffice, because matching what
    /// every other encoder emits keeps output comparable. When they do not —
    /// 12-bit samples reach magnitude categories past the eleven those tables
    /// cover — tables are built from the image's own symbol statistics instead.
    ///
    /// Deciding by trial rather than by rule: encode once with the given tables
    /// and see whether any symbol has no code. That is exact, where a rule
    /// about precision would be a guess about which images need it.
    ///
    /// The successful attempt's output is kept rather than discarded, so the
    /// common case — an image the standard tables handle — encodes exactly
    /// once. Only an image that needs optimal tables pays for a second pass.
    func coded(
        given tables: JPEG.Tables,
        scan: JPEG.Header.Scan,
        restartInterval: Int
    ) throws -> (tables: JPEG.Tables, ecs: [UInt8]) {
        do {
            return (
                tables,
                try self.encode(
                    scan: scan, encoders: .init(tables), restartInterval: restartInterval
                )
            )
        } catch JPEG.EncodingError.unencodableSymbol {
            // Fall through and build tables that cover whatever this image
            // actually produces.
        }

        let counting = JPEG.Encoders.counting(like: tables)

        _ = try self.encode(
            scan: scan, encoders: counting.encoders, restartInterval: restartInterval
        )

        var optimized: JPEG.Tables = .init()
        for (key, counter): (JPEG.Table.Huffman.Key, JPEG.Table.Huffman.Encoder.Counter)
            in counting.dc
        {
            optimized.push(
                try .optimal(frequencies: counter.frequencies, target: key, class: .dc)
            )
        }
        for (key, counter): (JPEG.Table.Huffman.Key, JPEG.Table.Huffman.Encoder.Counter)
            in counting.ac
        {
            optimized.push(
                try .optimal(frequencies: counter.frequencies, target: key, class: .ac)
            )
        }
        return (
            optimized,
            try self.encode(
                scan: scan, encoders: .init(optimized), restartInterval: restartInterval
            )
        )
    }

    /// A single interleaved scan covering every component and every
    /// coefficient.
    ///
    /// Which is what baseline means: one pass, everything at once. The table
    /// assignment follows the universal convention of slot 0 for the first
    /// component and slot 1 for the rest, which is what "luminance and
    /// chrominance tables" means in practice.
    func scan() -> JPEG.Header.Scan {
        .init(
            band: 0 ..< 64,
            bits: 0 ..< Int.max,
            components: self.layout.keys.enumerated().map {
                let slot: JPEG.Table.Huffman.Key = .init($0.offset == 0 ? 0 : 1)
                return .init(component: $0.element, dc: slot, ac: slot)
            }
        )
    }

    /// Writes this image as a complete JPEG stream.
    ///
    /// -   Parameters:
    ///     -   tables: The Huffman tables to code with. Every slot the scan
    ///         names must be present.
    ///     -   restartInterval: MCUs between restart markers, or 0 for none.
    ///     -   metadata: Extra segments to write after the JFIF header, in
    ///         order. Application segments carrying an ICC profile or EXIF
    ///         block go here; the codec neither reads nor validates them.
    public func compress<Destination>(
        stream: inout Destination,
        tables: JPEG.Tables,
        restartInterval: Int = 0,
        metadata: [(marker: JPEG.Marker, body: [UInt8])] = []
    ) throws where Destination: JPEG.Bytestream.Destination {
        let frame: JPEG.Header.Frame = try self.frame()
        let scan: JPEG.Header.Scan = self.scan()
        let coded: (tables: JPEG.Tables, ecs: [UInt8]) = try self.coded(
            given: tables, scan: scan, restartInterval: restartInterval
        )
        let tables: JPEG.Tables = coded.tables

        try stream.format(marker: .start)

        // A minimal JFIF segment. Nothing in the codec needs it, but enough
        // consumers assume a JPEG opens with one that omitting it causes
        // trouble disproportionate to the sixteen bytes it costs.
        try stream.format(
            marker: .application(0),
            body: [
                0x4A, 0x46, 0x49, 0x46, 0x00,   // "JFIF\0"
                0x01, 0x02,                     // version 1.02
                0x00,                           // no density units
                0x00, 0x01, 0x00, 0x01,         // 1:1 pixel aspect
                0x00, 0x00,                     // no thumbnail
            ]
        )

        for segment: (marker: JPEG.Marker, body: [UInt8]) in metadata {
            try stream.format(marker: segment.marker, body: segment.body)
        }

        // Quantization tables must precede the frame header that references
        // them, and Huffman tables the scan that does.
        for key: JPEG.Table.Quantization.Key in self.quanta.keys.sorted() {
            guard let table: JPEG.Table.Quantization = self.quanta[key] else {
                continue
            }
            try stream.format(marker: .quantization, body: table.serialized())
        }

        try stream.format(marker: .frame(self.layout.process), body: frame.serialized())

        for table: JPEG.Table.Huffman in tables.dc.values.sorted(by: { $0.target < $1.target })
            + tables.ac.values.sorted(by: { $0.target < $1.target })
        {
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

        try stream.format(marker: .scan, body: scan.serialized())

        let ecs: [UInt8] = coded.ecs

        guard stream.write(ecs) != nil else {
            throw JPEG.EncodingError.unsupportedProcess(self.layout.process)
        }

        try stream.format(marker: .end)
    }
}

extension JPEG.Data.Planar {
    /// Encodes these planes as a baseline JPEG at the given quality.
    ///
    /// The samples are taken as already being in the frame's colorspace and at
    /// each component's own resolution, so neither color conversion nor
    /// subsampling happens here. That is what a caller who has their own YUV
    /// data wants: those two steps are exactly what they have already done.
    public func compress<Destination>(
        stream: inout Destination,
        quality: Int = 85,
        restartInterval: Int = 0,
        metadata: [(marker: JPEG.Marker, body: [UInt8])] = []
    ) throws where Destination: JPEG.Bytestream.Destination {
        let precision: Int = self.layout.format.precision
        // Baseline is 8-bit by definition; 12-bit samples need the extended
        // sequential process, which is the same coding under a different
        // start-of-frame marker.
        let process: JPEG.Process = precision == 8
            ? .baseline
            : .extended(coding: .huffman, differential: false)
        guard process.precisions.contains(precision) else {
            throw JPEG.EncodingError.unsupportedPrecision(precision)
        }
        let baseline: Bool = process == .baseline

        var quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization] = [:]
        var tables: JPEG.Tables = .init()

        quanta[0] = .standard(.luminance, quality: quality, target: 0, baseline: baseline)
        tables.push(try .standard(.luminance, class: .dc, target: 0))
        tables.push(try .standard(.luminance, class: .ac, target: 0))

        if self.layout.planes.count > 1 {
            quanta[1] = .standard(
                .chrominance, quality: quality, target: 1, baseline: baseline
            )
            tables.push(try .standard(.chrominance, class: .dc, target: 1))
            tables.push(try .standard(.chrominance, class: .ac, target: 1))
        }

        try self.transformed(quanta: quanta).compress(
            stream: &stream,
            tables: tables,
            restartInterval: restartInterval,
            metadata: metadata
        )
    }
}

extension JPEG.Data.Rectangular {
    /// Encodes this image as a baseline JPEG at the given quality.
    ///
    /// Uses the Annex K sample tables throughout: the luminance quantization
    /// table scaled to `quality` for the first plane and the chrominance one
    /// for the rest, with the matching Huffman tables.
    ///
    /// -   Parameters:
    ///     -   quality: A rating from 1 through 100, on the IJG curve.
    ///     -   restartInterval: MCUs between restart markers, or 0 for none.
    public func compress<Destination>(
        stream: inout Destination,
        quality: Int = 85,
        restartInterval: Int = 0,
        metadata: [(marker: JPEG.Marker, body: [UInt8])] = []
    ) throws where Destination: JPEG.Bytestream.Destination {
        let precision: Int = self.layout.format.precision
        // Baseline is 8-bit by definition; 12-bit samples need the extended
        // sequential process, which is the same coding under a different
        // start-of-frame marker.
        let process: JPEG.Process = precision == 8
            ? .baseline
            : .extended(coding: .huffman, differential: false)
        guard process.precisions.contains(precision) else {
            throw JPEG.EncodingError.unsupportedPrecision(precision)
        }
        let baseline: Bool = process == .baseline

        var quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization] = [:]
        var tables: JPEG.Tables = .init()

        // Slot 0 carries luminance and slot 1 chrominance, which is the
        // arrangement every decoder expects and several tools assume.
        quanta[0] = .standard(.luminance, quality: quality, target: 0, baseline: baseline)
        tables.push(try .standard(.luminance, class: .dc, target: 0))
        tables.push(try .standard(.luminance, class: .ac, target: 0))

        if self.layout.planes.count > 1 {
            quanta[1] = .standard(
                .chrominance, quality: quality, target: 1, baseline: baseline
            )
            tables.push(try .standard(.chrominance, class: .dc, target: 1))
            tables.push(try .standard(.chrominance, class: .ac, target: 1))
        }

        // Rebuild the layout so each plane names the slot it will actually be
        // quantized with, rather than whatever it carried in.
        let layout: JPEG.Layout<Format> = try .init(
            format: self.layout.format,
            process: process,
            width: self.width,
            height: self.height,
            sampling: self.layout.planes.map(\.sampling),
            selectors: self.layout.planes.indices.map { .init($0 == 0 ? 0 : 1) }
        )

        let source: Self = .init(layout: layout, values: self.values)
        try source.spectral(quanta: quanta).compress(
            stream: &stream,
            tables: tables,
            restartInterval: restartInterval,
            metadata: metadata
        )
    }
}
