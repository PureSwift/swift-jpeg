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

    /// Converts the samples into an array of colors, one per pixel, row-major.
    public func unpack<Color>(as _: Color.Type) -> [Color]
        where Color: JPEG.Color, Color.Format == Format
    {
        Color.unpack(self.values, of: self.layout.format)
    }
}

extension JPEG.Data.Planar {
    /// Upsamples and interleaves this image to full resolution.
    ///
    /// Upsampling replicates: a chroma sample covering a 2×2 luma area is
    /// copied to all four pixels. That is what the standard's own reference
    /// decoder does, and it is what makes the operation exactly invertible for
    /// an image that was never subsampled. Smoother filters exist and produce
    /// better-looking chroma edges, but they are a rendering choice rather than
    /// part of decoding, so they do not belong here.
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

            // A component sampled at (sx, sy) against a maximum of (mx, my)
            // contributes one sample per mx/sx pixels horizontally. Multiplying
            // before dividing keeps this exact for factors that do not divide
            // evenly, which 3:1 and 4:3 arrangements do not.
            for y: Int in 0 ..< height {
                let row: Int = y * sampling.y / scale.y
                for x: Int in 0 ..< width {
                    let column: Int = x * sampling.x / scale.x
                    values[(y * width + x) * stride + plane] = source[x: column, y: row]
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
}
