extension JPEG.Data {
    /// An image as samples, at each component's own resolution.
    ///
    /// One step below ``Spectral``: the coefficients have been dequantized and
    /// transformed, but a subsampled component is still stored at its own
    /// smaller size rather than stretched to the image's. Planes are padded out
    /// to whole 8×8 blocks, so a plane is usually a little larger than the
    /// component resolution the layout reports.
    public struct Planar<Format> where Format: JPEG.Format {
        /// One component's samples.
        public struct Plane {
            /// The plane's size, in samples, including block padding.
            public let size: (x: Int, y: Int)
            /// Samples, row-major.
            ///
            /// `UInt16` regardless of precision. A 12- or 16-bit image needs
            /// the width, and carrying one sample type keeps every stage above
            /// this one from being written twice.
            private var buffer: [UInt16]

            init(size: (x: Int, y: Int)) {
                self.size = size
                self.buffer = .init(repeating: 0, count: size.x * size.y)
            }

            /// Accesses the sample at `(x, y)`.
            ///
            /// Reads outside the plane clamp to the edge, which is what
            /// upsampling wants at the right and bottom margins.
            public subscript(x x: Int, y y: Int) -> UInt16 {
                get {
                    let x: Int = Swift.min(Swift.max(x, 0), self.size.x - 1)
                    let y: Int = Swift.min(Swift.max(y, 0), self.size.y - 1)
                    return self.buffer[y * self.size.x + x]
                }
                set {
                    guard 0 ..< self.size.x ~= x, 0 ..< self.size.y ~= y else {
                        return
                    }
                    self.buffer[y * self.size.x + x] = newValue
                }
            }
        }

        /// The planes, in layout order.
        public private(set) var planes: [Plane]
        /// The image geometry and component structure.
        public private(set) var layout: JPEG.Layout<Format>

        init(planes: [Plane], layout: JPEG.Layout<Format>) {
            self.planes = planes
            self.layout = layout
        }
    }
}

extension JPEG.Data.Planar {
    /// The image size, in samples.
    public var size: (x: Int, y: Int) {
        (x: self.layout.width, y: self.layout.height)
    }

    public subscript(plane: Int) -> Plane {
        _read {
            yield self.planes[plane]
        }
    }
}

extension JPEG.Data.Spectral {
    /// Dequantizes and transforms this image into samples.
    ///
    /// Every block is dequantized with the table its plane names and then
    /// inverse transformed. A plane whose quantization table was never defined
    /// decodes to a flat midpoint rather than failing, since the coefficients
    /// themselves are intact and the caller may still want the rest of the
    /// image.
    public func decomposed() -> JPEG.Data.Planar<Format> {
        let precision: Int = self.layout.format.precision

        let planes: [JPEG.Data.Planar<Format>.Plane] = self.planes.map { plane in
            var output: JPEG.Data.Planar<Format>.Plane = .init(
                size: (x: plane.blocks.x * 8, y: plane.blocks.y * 8)
            )

            guard let table: JPEG.Table.Quantization = self.quanta[plane.quanta] else {
                for y: Int in 0 ..< output.size.y {
                    for x: Int in 0 ..< output.size.x {
                        output[x: x, y: y] = .init(1 << (precision - 1))
                    }
                }
                return output
            }

            for by: Int in 0 ..< plane.blocks.y {
                for bx: Int in 0 ..< plane.blocks.x {
                    let samples: [UInt16] = JPEG.IDCT.transform(
                        JPEG.IDCT.dequantize(plane.block(x: bx, y: by), by: table),
                        precision: precision
                    )
                    for i: Int in 0 ..< 64 {
                        output[x: bx * 8 + (i & 7), y: by * 8 + (i >> 3)] = samples[i]
                    }
                }
            }

            return output
        }

        return .init(planes: planes, layout: self.layout)
    }
}
