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

            public init(size: (x: Int, y: Int)) {
                self.size = size
                self.buffer = .init(repeating: 0, count: size.x * size.y)
            }

            /// Runs `body` on this plane's samples, row-major.
            func withSamples<T>(_ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
                self.buffer.withUnsafeBufferPointer(body)
            }

            /// Runs `body` on this plane's samples, row-major and writable.
            mutating func withMutableSamples<T>(
                _ body: (UnsafeMutableBufferPointer<UInt16>) -> T
            ) -> T {
                self.buffer.withUnsafeMutableBufferPointer { body($0) }
            }

            /// Copies an `n`×`n` block of samples in at `(x, y)`.
            ///
            /// A block at a time rather than a sample at a time, so the bounds
            /// check and the row offset are computed once per row instead of
            /// once per sample.
            mutating func write(
                block: UnsafeMutableBufferPointer<UInt16>, x: Int, y: Int, size n: Int
            ) {
                self.buffer.withUnsafeMutableBufferPointer { destination in
                    for row: Int in 0 ..< n where y + row < self.size.y {
                        let base: Int = (y + row) * self.size.x + x
                        for column: Int in 0 ..< n where x + column < self.size.x {
                            destination[base + column] = block[row * n + column]
                        }
                    }
                }
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
    /// Creates a zeroed image sized for the given layout.
    ///
    /// Planes come out padded to whole blocks, which is larger than each
    /// component's own resolution. A caller filling one in is expected to
    /// extend the last real sample into that padding rather than leave it at
    /// zero, for the same reason subsampling does: a step to black at the edge
    /// is a discontinuity the transform has to spend bits encoding.
    public init(layout: JPEG.Layout<Format>) {
        self.init(
            planes: layout.planes.indices.map {
                let blocks: (x: Int, y: Int) = layout.blocks(plane: $0)
                return .init(size: (x: blocks.x * 8, y: blocks.y * 8))
            },
            layout: layout
        )
    }

    /// The image size, in samples.
    public var size: (x: Int, y: Int) {
        (x: self.layout.width, y: self.layout.height)
    }

    public subscript(plane: Int) -> Plane {
        _read {
            yield self.planes[plane]
        }
        _modify {
            yield &self.planes[plane]
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
        self.decomposed(scale: 8)
    }

    /// Dequantizes and transforms this image into samples at a reduced size.
    ///
    /// Each 8×8 block becomes `n`×`n` samples, so the image comes out `n/8` of
    /// its coded size. This is not decode-then-resample: the higher frequencies
    /// are never transformed at all, which is why a one-eighth image costs a
    /// sixty-fourth of the transform work. It is also why the result is
    /// slightly softer than a resampled full decode would be — the detail is
    /// discarded rather than averaged.
    ///
    /// -   Parameter n:
    ///     The output block size, 1 through 8.
    public func decomposed(scale n: Int) -> JPEG.Data.Planar<Format> {
        precondition(1 ... 8 ~= n)
        let precision: Int = self.layout.format.precision

        let planes: [JPEG.Data.Planar<Format>.Plane] = self.planes.map { plane in
            var output: JPEG.Data.Planar<Format>.Plane = .init(
                size: (x: plane.blocks.x * n, y: plane.blocks.y * n)
            )

            guard let table: JPEG.Table.Quantization = self.quanta[plane.quanta] else {
                for y: Int in 0 ..< output.size.y {
                    for x: Int in 0 ..< output.size.x {
                        output[x: x, y: y] = .init(1 << (precision - 1))
                    }
                }
                return output
            }

            // Two scratch blocks for the whole plane rather than four heap
            // allocations per block. On a megapixel image that is the
            // difference between a hundred thousand allocations and none.
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 64) { coefficients in
                withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 64) { samples in
                    for by: Int in 0 ..< plane.blocks.y {
                        for bx: Int in 0 ..< plane.blocks.x {
                            plane.withBlock(x: bx, y: by) { levels in
                                for z: Int in 0 ..< 64 {
                                    coefficients[z] = .init(levels[z]) * .init(table[z: z])
                                }
                            }
                            JPEG.IDCT.transform(
                                .init(coefficients), precision: precision, size: n, into: samples
                            )
                            output.write(block: samples, x: bx * n, y: by * n, size: n)
                        }
                    }
                }
            }

            return output
        }

        var layout: JPEG.Layout<Format> = self.layout
        layout.width = (self.layout.width * n + 7) / 8
        layout.height = (self.layout.height * n + 7) / 8

        return .init(planes: planes, layout: layout)
    }
}
