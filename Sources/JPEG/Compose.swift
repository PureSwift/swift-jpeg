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
    ) throws(JPEG.Failure) {
        let keys: [JPEG.Component.Key] = format.components
        guard sampling.count == keys.count, selectors.count == keys.count else {
            throw .encoding(.unsupportedProcess(process))
        }
        guard 1 ... 65535 ~= width, 1 ... 65535 ~= height else {
            throw .encoding(.imageTooLarge(width: width, height: height))
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

                // The horizontal box for each output column, and the clamped
                // source index of each sample in it. Both depend only on x, and
                // computing them per pixel meant two integer divisions and a
                // clamp for every sample of every plane — on a megapixel image
                // that was the dominant cost of the whole encoder.
                let size: (x: Int, y: Int) = output.size
                var spans: [(start: Int, end: Int)] = []
                spans.reserveCapacity(size.x)
                for x: Int in 0 ..< size.x {
                    let column: Int = Swift.min(x, extent.x - 1)
                    let x0: Int = column * scale.x / sampling.x
                    let x1: Int = Swift.max(x0 + 1, (column + 1) * scale.x / sampling.x)
                    spans.append((
                        start: Swift.min(x0, self.width - 1),
                        end: Swift.min(Swift.max(x1, x0 + 1), self.width)
                    ))
                }

                // The leading run of columns whose boxes are all the same width
                // and advance by that width. Everything after it is the
                // narrower boxes at the right edge, where the last one would
                // otherwise run off the image, plus the block padding that
                // repeats them.
                //
                // Knowing that run lets the two box shapes every real image
                // uses be written out as straight-line code. The general loop
                // below is correct for any sampling ratio, but it pays for that
                // generality on every sample: two nested loops whose lengths
                // the optimizer cannot see are one and two, a table lookup for
                // the column, and an integer division by a count it cannot know
                // is one or four.
                let uniform: Int = spans.isEmpty ? 0 : spans[0].end - spans[0].start
                var prefix: Int = 0
                while prefix < spans.count,
                      spans[prefix].end - spans[prefix].start == uniform,
                      spans[prefix].start == prefix * uniform {
                    prefix += 1
                }

                self.values.withUnsafeBufferPointer { values in
                    output.withMutableSamples { samples in
                        for y: Int in 0 ..< size.y {
                            let row: Int = Swift.min(y, extent.y - 1)
                            let y0: Int = Swift.min(
                                row * scale.y / sampling.y, self.height - 1
                            )
                            let y1: Int = Swift.min(
                                Swift.max((row + 1) * scale.y / sampling.y, y0 + 1),
                                self.height
                            )

                            let base: Int = y * size.x
                            var x: Int = 0

                            if uniform == 1, y1 - y0 == 1 {
                                // One source sample per output sample: the luma
                                // plane of every subsampled image, and every
                                // plane of an unsubsampled one. A strided read,
                                // with the averaging gone rather than performed
                                // over a box of one.
                                var index: Int = y0 * self.width * stride + plane
                                while x < prefix {
                                    samples[base + x] = values[index]
                                    index += stride
                                    x += 1
                                }
                            } else if uniform == 2, y1 - y0 == 2 {
                                // A 2x2 box: the chroma planes of a 4:2:0
                                // image, which is the overwhelming majority of
                                // what anything encodes. Four samples, a
                                // rounding term and a shift — the division by
                                // four the general loop cannot avoid is the
                                // single most expensive instruction in it.
                                var above: Int = y0 * self.width * stride + plane
                                var below: Int = above + self.width * stride
                                while x < prefix {
                                    let total: Int32 =
                                        .init(values[above])
                                        + .init(values[above + stride])
                                        + .init(values[below])
                                        + .init(values[below + stride])
                                    samples[base + x] = .init(
                                        truncatingIfNeeded: (total + 2) >> 2
                                    )
                                    above += 2 * stride
                                    below += 2 * stride
                                    x += 1
                                }
                            }

                            // Whatever the specialized loops did not cover: the
                            // narrower boxes at the right and bottom edges, and
                            // any sampling ratio other than one or two.
                            while x < size.x {
                                let span: (start: Int, end: Int) = spans[x]

                                var total: Int = 0
                                var count: Int = 0
                                for sy: Int in y0 ..< y1 {
                                    let offset: Int = sy * self.width
                                    for sx: Int in span.start ..< span.end {
                                        total += .init(
                                            values[(offset + sx) * stride + plane]
                                        )
                                        count += 1
                                    }
                                }

                                samples[base + x] = .init(
                                    truncatingIfNeeded: (total + count / 2) / count
                                )
                                x += 1
                            }
                        }
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
    ) throws(JPEG.Failure) -> JPEG.Data.Spectral<Format> {
        var spectral: JPEG.Data.Spectral<Format> = .init(layout: self.layout)
        spectral.quanta = quanta

        let precision: Int = self.layout.format.precision

        for plane: Int in self.layout.planes.indices {
            let selector: JPEG.Table.Quantization.Key = self.layout.planes[plane].selector
            guard let table: JPEG.Table.Quantization = quanta[selector] else {
                throw .encoding(.undefinedQuantizationTable(selector))
            }

            let blocks: (x: Int, y: Int) = spectral.planes[plane].blocks
            let extent: (x: Int, y: Int) = self.planes[plane].size

            // Three scratch blocks for the whole plane. The array-returning
            // transform and quantize allocate one each per block, and a
            // megapixel image is twenty-odd thousand blocks per plane.
            withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 64) { samples in
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 64) { coefficients in
            withUnsafeTemporaryAllocation(of: Int16.self, capacity: 64) { levels in
                self.planes[plane].withSamples { source in
                    for by: Int in 0 ..< blocks.y {
                        for bx: Int in 0 ..< blocks.x {
                            // The plane is padded to whole blocks, so every
                            // block is inside it and the row offsets are a
                            // straight multiply.
                            for row: Int in 0 ..< 8 {
                                let base: Int = (by * 8 + row) * extent.x + bx * 8
                                for column: Int in 0 ..< 8 {
                                    samples[row << 3 | column] = source[base + column]
                                }
                            }

                            JPEG.Kernel.forwardTransform(
                                samples.baseAddress!,
                                .init(precision),
                                coefficients.baseAddress!
                            )
                            JPEG.FDCT.quantize(
                                .init(coefficients), by: table, into: levels
                            )

                            spectral.planes[plane].withBlockRow(by) { destination in
                                let base: Int = bx * 64
                                for z: Int in 0 ..< 64 {
                                    destination[base + z] = levels[z]
                                }
                            }
                        }
                    }
                }
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
    ) throws(JPEG.Failure) -> JPEG.Data.Spectral<Format> {
        try self.subsampled().transformed(quanta: quanta)
    }
}
