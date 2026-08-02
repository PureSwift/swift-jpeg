extension JPEG.Layout {
    /// Builds a layout for encoding.
    ///
    /// The decoding initializer derives everything from a frame header that
    /// already exists. Encoding has no header yet, so the geometry is stated
    /// directly here and the header is generated from it later.
    ///
    /// -   Parameters:
    ///     -   format: The color format. Its component list fixes the plane
    ///         order.
    ///     -   sampling: One sampling factor pair per plane, in the format's
    ///         component order.
    ///     -   selectors: One quantization table slot per plane.
    public init(
        format: Format,
        process: JPEG.Process,
        width: Int,
        height: Int,
        sampling: [JPEG.Component.Sampling],
        selectors: [JPEG.Table.Quantization.Key]
    ) throws {
        let keys: [JPEG.Component.Key] = format.components
        guard sampling.count == keys.count, selectors.count == keys.count else {
            throw JPEG.EncodingError.unsupportedProcess(process)
        }
        guard 1 ... 65535 ~= width, 1 ... 65535 ~= height else {
            throw JPEG.EncodingError.imageTooLarge(width: width, height: height)
        }

        var residents: [JPEG.Component.Key: Int] = [:]
        for (plane, key): (Int, JPEG.Component.Key) in keys.enumerated() {
            residents[key] = plane
        }

        self.init(
            format: format,
            process: process,
            width: width,
            height: height,
            planes: zip(sampling, selectors).map {
                .init(sampling: $0, selector: $1)
            },
            keys: keys,
            residents: residents,
            scale: .init(
                x: sampling.map(\.x).max() ?? 1,
                y: sampling.map(\.y).max() ?? 1
            )
        )
    }
}

extension JPEG.Data.Rectangular {
    /// Creates an image from interleaved samples.
    ///
    /// -   Parameter values:
    ///     `layout.planes.count` samples per pixel, row-major.
    public init(layout: JPEG.Layout<Format>, values: [UInt16]) {
        precondition(values.count == layout.width * layout.height * layout.planes.count)
        self.init(
            width: layout.width,
            height: layout.height,
            layout: layout,
            values: values
        )
    }
}

extension JPEG.Data.Rectangular {
    /// Subsamples each component down to its own resolution.
    ///
    /// Averaging, not point sampling. Discarding three of every four chroma
    /// samples aliases badly on saturated edges, and the cost of the box filter
    /// is negligible against the transform that follows.
    ///
    /// Planes come out padded to whole 8×8 blocks. The padding replicates the
    /// last real sample rather than being left at zero, because a hard step to
    /// black at the edge costs real bits: the transform would have to encode a
    /// discontinuity that is not in the image.
    public func subsampled() -> JPEG.Data.Planar<Format> {
        let scale: JPEG.Component.Sampling = self.layout.scale
        let stride: Int = self.layout.planes.count

        let planes: [JPEG.Data.Planar<Format>.Plane] =
            self.layout.planes.indices.map { plane in
                let sampling: JPEG.Component.Sampling = self.layout.planes[plane].sampling
                let blocks: (x: Int, y: Int) = self.layout.blocks(plane: plane)
                var output: JPEG.Data.Planar<Format>.Plane = .init(
                    size: (x: blocks.x * 8, y: blocks.y * 8)
                )

                // The component's own resolution, before block padding. Samples
                // beyond it repeat the edge.
                let extent: (x: Int, y: Int) = self.layout.samples(plane: plane)

                for y: Int in 0 ..< output.size.y {
                    let row: Int = Swift.min(y, extent.y - 1)
                    let y0: Int = row * scale.y / sampling.y
                    let y1: Int = Swift.max(y0 + 1, (row + 1) * scale.y / sampling.y)

                    for x: Int in 0 ..< output.size.x {
                        let column: Int = Swift.min(x, extent.x - 1)
                        let x0: Int = column * scale.x / sampling.x
                        let x1: Int = Swift.max(x0 + 1, (column + 1) * scale.x / sampling.x)

                        var total: Int = 0
                        var count: Int = 0
                        for sy: Int in y0 ..< y1 {
                            let sy: Int = Swift.min(sy, self.height - 1)
                            for sx: Int in x0 ..< x1 {
                                let sx: Int = Swift.min(sx, self.width - 1)
                                total += .init(self.values[(sy * self.width + sx) * stride + plane])
                                count += 1
                            }
                        }

                        output[x: x, y: y] = .init(
                            truncatingIfNeeded: (total + count / 2) / Swift.max(count, 1)
                        )
                    }
                }

                return output
            }

        return .init(planes: planes, layout: self.layout)
    }
}

extension JPEG.Data.Planar {
    /// Transforms and quantizes every block.
    ///
    /// -   Parameter quanta:
    ///     The quantization tables, keyed by slot. Every plane's selector must
    ///     be present.
    public func transformed(
        quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization]
    ) throws -> JPEG.Data.Spectral<Format> {
        var spectral: JPEG.Data.Spectral<Format> = .init(layout: self.layout)
        spectral.quanta = quanta

        let precision: Int = self.layout.format.precision

        for plane: Int in self.layout.planes.indices {
            let selector: JPEG.Table.Quantization.Key = self.layout.planes[plane].selector
            guard let table: JPEG.Table.Quantization = quanta[selector] else {
                throw JPEG.EncodingError.undefinedQuantizationTable(selector)
            }

            let blocks: (x: Int, y: Int) = spectral.planes[plane].blocks
            var samples: [UInt16] = .init(repeating: 0, count: 64)

            for by: Int in 0 ..< blocks.y {
                for bx: Int in 0 ..< blocks.x {
                    for i: Int in 0 ..< 64 {
                        samples[i] = self.planes[plane][
                            x: bx * 8 + (i & 7),
                            y: by * 8 + (i >> 3)
                        ]
                    }

                    let levels: [Int16] = JPEG.FDCT.quantize(
                        JPEG.FDCT.transform(samples, precision: precision),
                        by: table
                    )
                    for i: Int in 0 ..< 64 {
                        spectral.planes[plane][x: bx, y: by, z: i] = levels[i]
                    }
                }
            }
        }

        return spectral
    }
}

extension JPEG.Data.Rectangular {
    /// Subsamples, transforms and quantizes in one step.
    public func spectral(
        quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization]
    ) throws -> JPEG.Data.Spectral<Format> {
        try self.subsampled().transformed(quanta: quanta)
    }
}
