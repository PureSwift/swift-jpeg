extension JPEG.Data {
    /// An image as interleaved samples at full resolution.
    ///
    /// The bottom tier: subsampled components have been stretched back to the
    /// image size, the block padding has been cropped away, and the components
    /// are interleaved one pixel at a time. This is the representation a caller
    /// who wants pixels is after, and the only one whose dimensions match what
    /// the frame header advertised.
    public struct Rectangular<Format> where Format: JPEG.Format {
        /// The image width, in pixels.
        public let width: Int
        /// The image height, in pixels.
        public let height: Int
        /// The image geometry and component structure.
        public let layout: JPEG.Layout<Format>

        /// Samples, row-major, `layout.planes.count` per pixel.
        public private(set) var values: [UInt16]

        init(width: Int, height: Int, layout: JPEG.Layout<Format>, values: [UInt16]) {
            self.width = width
            self.height = height
            self.layout = layout
            self.values = values
        }
    }
}

extension JPEG.Data.Rectangular {
    /// The image size, in pixels.
    public var size: (x: Int, y: Int) {
        (x: self.width, y: self.height)
    }

    /// The number of components per pixel.
    public var stride: Int {
        self.layout.planes.count
    }

    /// Accesses the sample for the given component of the pixel at `(x, y)`.
    public subscript(x x: Int, y y: Int, plane: Int) -> UInt16 {
        self.values[(y * self.width + x) * self.stride + plane]
    }

    /// Returns the given rectangle of this image.
    ///
    /// Cropping at this tier is a copy, and exact at any offset. Cropping at
    /// the spectral tier would be cheaper — whole blocks outside the region
    /// need never be transformed — but only lands on block boundaries, so this
    /// is the general answer and the other is an optimization for the aligned
    /// case.
    ///
    /// -   Returns:
    ///     `nil` if the rectangle is not wholly inside the image.
    public func cropped(to region: (x: Int, y: Int, width: Int, height: Int)) -> Self? {
        guard
        region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
        region.x + region.width <= self.width,
        region.y + region.height <= self.height
        else {
            return nil
        }

        let stride: Int = self.stride
        var values: [UInt16] = .init(
            repeating: 0, count: region.width * region.height * stride
        )
        for y: Int in 0 ..< region.height {
            for x: Int in 0 ..< region.width {
                for plane: Int in 0 ..< stride {
                    values[(y * region.width + x) * stride + plane] =
                        self[x: region.x + x, y: region.y + y, plane]
                }
            }
        }

        var layout: JPEG.Layout<Format> = self.layout
        layout.width = region.width
        layout.height = region.height

        return .init(
            width: region.width,
            height: region.height,
            layout: layout,
            values: values
        )
    }

    /// Converts the samples into an array of colors, one per pixel, row-major.
    public func unpack<Color>(as _: Color.Type) -> [Color]
        where Color: JPEG.Color, Color.Format == Format
    {
        Color.unpack(self.values, of: self.layout.format)
    }
}

extension JPEG.Data.Planar {
    /// Maps an output coordinate to a position in a plane sampled `numerator`
    /// times for every `denominator` output samples, in Q16 fixed point.
    ///
    /// The half-sample terms are what make this an interpolation rather than a
    /// stretch. A subsampled chroma sample represents the *center* of the area
    /// it covers, not its corner, so the output grid and the source grid are
    /// offset by half a source sample. Dropping the offset shifts chroma by
    /// half a pixel — a subtle error that looks like color fringing on one side
    /// of every edge.
    private static func source(_ x: Int, _ numerator: Int, _ denominator: Int) -> Int {
        (((2 * x + 1) * numerator) << 16) / (2 * denominator) - (1 << 15)
    }

    /// Upsamples and interleaves this image to full resolution.
    ///
    /// A component sampled as densely as the frame is copied verbatim. A
    /// subsampled one is bilinearly interpolated, which for the 2×1 and 2×2
    /// cases reproduces the triangular filter libjpeg calls "fancy upsampling"
    /// and enables by default. Matching it matters here: this library is meant
    /// to stand in for that one, and replication — which is what the standard's
    /// own reference decoder does — differs from it by up to about 40 counts at
    /// a sharp chroma edge.
    ///
    /// Reads past a plane's edge clamp, so the margins repeat the edge sample
    /// instead of interpolating toward nothing.
    ///
    /// The block padding each plane carries is dropped at the same time, since
    /// the crop and the scale share an index calculation.
    public func interleaved() -> JPEG.Data.Rectangular<Format> {
        let width: Int = self.layout.width
        let height: Int = self.layout.height
        let stride: Int = self.planes.count
        let scale: JPEG.Component.Sampling = self.layout.scale

        var values: [UInt16] = .init(repeating: 0, count: width * height * stride)

        for (plane, component): (Int, JPEG.Component) in self.layout.planes.enumerated() {
            let sampling: JPEG.Component.Sampling = component.sampling
            let source: Plane = self.planes[plane]

            let extent: (x: Int, y: Int) = source.size

            guard sampling.x != scale.x || sampling.y != scale.y else {
                // Full resolution. Interpolating would be a no-op in exact
                // arithmetic but not in fixed point, so take the direct path
                // and keep the samples bit-exact. This is the luma plane of
                // every subsampled image, so it is a million samples on a
                // megapixel image and worth writing through a raw pointer.
                source.withSamples { samples in
                    values.withUnsafeMutableBufferPointer { values in
                        for y: Int in 0 ..< height {
                            var output: Int = y * width * stride + plane
                            let input: Int = y * extent.x
                            for x: Int in 0 ..< width {
                                values[output] = samples[input + x]
                                output += stride
                            }
                        }
                    }
                }
                continue
            }

            // Column coordinates repeat on every row, so they are computed
            // once for the plane rather than a million times — and clamped
            // here too, since the clamp also depends only on x.
            var lefts: [Int] = .init(repeating: 0, count: width)
            var rights: [Int] = .init(repeating: 0, count: width)
            var fractions: [Int32] = .init(repeating: 0, count: width)
            for x: Int in 0 ..< width {
                let u: Int = Self.source(x, sampling.x, scale.x)
                let column: Int = u >> 16
                lefts[x] = Swift.min(Swift.max(column, 0), extent.x - 1)
                rights[x] = Swift.min(Swift.max(column + 1, 0), extent.x - 1)
                fractions[x] = .init(u - (column << 16))
            }
            source.withSamples { samples in
              values.withUnsafeMutableBufferPointer { values in
                lefts.withUnsafeBufferPointer { lefts in
                  rights.withUnsafeBufferPointer { rights in
                    fractions.withUnsafeBufferPointer { fractions in
                    for y: Int in 0 ..< height {
                        let v: Int = Self.source(y, sampling.y, scale.y)
                        // Arithmetic shift floors, including for the negative
                        // coordinates the half-sample offset produces at the
                        // top and left margins, so the fraction stays in 0 ..< 1.
                        let row: Int = v >> 16
                        let fy: Int32 = .init(v - (row << 16))

                        // Clamping the two source rows once per output row
                        // removes two bounds checks from every pixel.
                        let above: Int = Swift.min(Swift.max(row, 0), extent.y - 1) * extent.x
                        let below: Int = Swift.min(Swift.max(row + 1, 0), extent.y - 1) * extent.x

                        var output: Int = y * width * stride + plane
                        for x: Int in 0 ..< width {
                            let left: Int = lefts[x]
                            let right: Int = rights[x]
                            let fx: Int32 = fractions[x]

                            // 32-bit intermediates: a sample is at most 16 bits
                            // and a fraction at most 16, so the products fit
                            // with room to spare and the 64-bit arithmetic this
                            // used before was pure overhead.
                            let a: Int32 = .init(samples[above + left])
                            let b: Int32 = .init(samples[above + right])
                            let c: Int32 = .init(samples[below + left])
                            let d: Int32 = .init(samples[below + right])

                            let top: Int32 = (a << 8) + ((b - a) * fx >> 8)
                            let bottom: Int32 = (c << 8) + ((d - c) * fx >> 8)
                            let value: Int32 =
                                ((top << 8) + ((bottom - top) * fy >> 8) + (1 << 15)) >> 16

                            values[output] = .init(value)
                            output += stride
                        }
                    }
                    }
                  }
                }
              }
            }
        }

        return .init(width: width, height: height, layout: self.layout, values: values)
    }
}

extension JPEG.Data.Spectral {
    /// Decodes all the way down to interleaved full-resolution samples.
    public func rectangular() -> JPEG.Data.Rectangular<Format> {
        self.decomposed().interleaved()
    }

    /// Decodes to interleaved samples at `n/8` of the coded size.
    public func rectangular(scale n: Int) -> JPEG.Data.Rectangular<Format> {
        self.decomposed(scale: n).interleaved()
    }
}
