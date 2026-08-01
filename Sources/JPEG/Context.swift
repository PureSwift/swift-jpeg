extension JPEG {
    /// The decoder state that accumulates across a stream.
    ///
    /// A JPEG is a sequence of segments that mutate a shared context — tables
    /// defined here apply to scans that come later, and can be redefined
    /// between them. This type is that context, kept separate from the driver
    /// loop so the ordering rules live in one place.
    public struct Context<Format> where Format: JPEG.Format {
        /// The Huffman tables currently defined.
        public private(set) var tables: JPEG.Tables
        /// The quantization tables currently defined.
        public private(set) var quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization]
        /// MCUs between restart markers, or 0 if restarts are not in use.
        public private(set) var restartInterval: Int
        /// The frame header, once one has been seen.
        public private(set) var frame: JPEG.Header.Frame?
        /// The image being decoded into, once a frame header has been seen.
        public private(set) var spectral: JPEG.Data.Spectral<Format>?

        public init() {
            self.tables = .init()
            self.quanta = [:]
            self.restartInterval = 0
            self.frame = nil
            self.spectral = nil
        }
    }
}

extension JPEG.Context {
    /// Applies a `DQT` segment.
    public mutating func push(quantization data: [UInt8]) throws {
        for table: JPEG.Table.Quantization in try JPEG.Table.Quantization.parse(data) {
            self.quanta[table.target] = table
        }
        // Quantization tables may be redefined between scans, and the spectral
        // image holds only slot references, so the copy it carries has to track
        // the latest definitions rather than the ones in force when it was
        // created.
        self.spectral?.quanta = self.quanta
    }

    /// Applies a `DHT` segment.
    public mutating func push(huffman data: [UInt8]) throws {
        for table: JPEG.Table.Huffman in try JPEG.Table.Huffman.parse(data) {
            self.tables.push(table)
        }
    }

    /// Applies a `DRI` segment.
    public mutating func push(restartInterval data: [UInt8]) throws {
        self.restartInterval = try JPEG.Header.RestartInterval.parse(data).interval
    }

    /// Applies a `DNL` segment.
    public mutating func push(height data: [UInt8]) throws {
        let redefinition: JPEG.Header.HeightRedefinition = try .parse(data)
        self.frame?.redefine(height: redefinition)
        self.spectral?.set(height: redefinition.height)
    }

    /// Applies a start-of-frame segment.
    public mutating func push(frame data: [UInt8], process: JPEG.Process) throws {
        guard self.frame == nil else {
            throw JPEG.DecodingError.duplicateFrameHeader
        }

        let frame: JPEG.Header.Frame = try .parse(data, process: process)
        var spectral: JPEG.Data.Spectral<Format> = .init(layout: try .init(frame: frame))
        spectral.quanta = self.quanta

        self.frame = frame
        self.spectral = spectral
    }

    /// Applies a start-of-scan segment and the entropy coded data following it.
    public mutating func push(scan data: [UInt8], ecs: [UInt8]) throws {
        guard let frame: JPEG.Header.Frame = self.frame else {
            throw JPEG.DecodingError.missingFrameHeader
        }

        let scan: JPEG.Header.Scan = try .parse(data, process: frame.process)
        try self.spectral?.decode(
            ecs,
            scan: scan,
            tables: self.tables,
            restartInterval: self.restartInterval
        )
    }
}

extension JPEG.Data.Spectral {
    /// Decodes an image from a byte source, stopping at the end-of-image
    /// marker.
    ///
    /// Segments the decoder has no use for — application segments, comments,
    /// reserved markers — are skipped rather than rejected. Real files carry
    /// plenty of them, and none affect the coefficients.
    public static func decompress<Source>(
        stream: inout Source
    ) throws -> Self where Source: JPEG.Bytestream.Source {
        try stream.start()

        var context: JPEG.Context<Format> = .init()
        // A scan reads its own entropy coded data, which runs to the *next*
        // marker — so decoding a scan necessarily consumes the segment after
        // it. That segment is held here and processed on the following pass
        // rather than being read again.
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
                try context.push(frame: data, process: process)

            case .scan:
                let (ecs, next): ([UInt8], (JPEG.Marker, [UInt8])) =
                    try stream.segment(prefix: true)
                try context.push(scan: data, ecs: ecs)
                pending = next

            case .quantization:
                try context.push(quantization: data)
            case .huffman:
                try context.push(huffman: data)
            case .restartInterval:
                try context.push(restartInterval: data)
            case .height:
                try context.push(height: data)

            case .start:
                // A second SOI is redundant but harmless; some encoders emit
                // one before a thumbnail.
                continue loop

            default:
                continue loop
            }
        }

        guard let spectral: Self = context.spectral else {
            throw JPEG.DecodingError.missingFrameHeader
        }
        return spectral
    }
}

extension JPEG.Data.Planar {
    /// Decodes an image and transforms it to samples.
    public static func decompress<Source>(
        stream: inout Source
    ) throws -> Self where Source: JPEG.Bytestream.Source {
        try JPEG.Data.Spectral<Format>.decompress(stream: &stream).decomposed()
    }
}

extension JPEG.Data.Rectangular {
    /// Decodes an image all the way to interleaved full-resolution samples.
    public static func decompress<Source>(
        stream: inout Source
    ) throws -> Self where Source: JPEG.Bytestream.Source {
        try JPEG.Data.Spectral<Format>.decompress(stream: &stream).rectangular()
    }
}
