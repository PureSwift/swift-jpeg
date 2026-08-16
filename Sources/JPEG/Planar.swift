extension JPEG.Data {
    /// One component's samples.
    ///
    /// Spelled ``Planar/Plane`` everywhere it is used. It lives out here rather
    /// than nested inside ``Planar`` for the reason ``SpectralPlane`` does: it
    /// does not mention `Format`, and nesting it inside a generic type would
    /// make every use of it instantiate metadata at run time for a type that
    /// does not vary.
    public struct PlanarPlane {
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
        ///
        /// The only way to read a whole plane from outside this module. The
        /// subscript below clamps and takes one sample at a time, which is
        /// right for interpolating across an edge and wrong for handing a
        /// plane to something else — a texture upload, a YUV file, another
        /// codec — and going through ``Rectangular`` to get there
        /// interleaves and stretches the samples, which is a copy and a
        /// change of meaning rather than a way of reading these ones.
        ///
        /// A `Span` rather than a pointer, so that reading a plane needs no
        /// unsafe code at the call site and no copy either. The lifetime is
        /// what the closure gives it: the span cannot outlive the call, and
        /// the compiler enforces that rather than the documentation asking
        /// for it.
        ///
        /// -   Parameter body:
        ///     Receives `size.x * size.y` samples, row-major, including the
        ///     block padding — so the row stride is `size.x`, which is
        ///     usually a little wider than the component resolution the
        ///     layout reports.
        public func withSamples<T, E>(
            _ body: (Span<UInt16>) throws(E) -> T
        ) throws(E) -> T where E: Error {
            try body(self.buffer.span)
        }

        /// Runs `body` on this plane's samples, row-major and writable.
        ///
        /// The counterpart to ``withSamples(_:)``, for filling a plane that
        /// is about to be encoded. The subscript's setter drops writes
        /// outside the plane; a `MutableSpan` traps on them instead, which
        /// is the better failure for code that computes its indices.
        public mutating func withMutableSamples<T, E>(
            _ body: (inout MutableSpan<UInt16>) throws(E) -> T
        ) throws(E) -> T where E: Error {
            var span: MutableSpan<UInt16> = self.buffer.mutableSpan
            return try body(&span)
        }

        /// Runs `body` on this plane's samples through a raw pointer.
        ///
        /// The resampling loops use this rather than the `Span` accessor
        /// below, and the reason is measured rather than assumed. A `Span`
        /// subscript is bounds checked, and in these loops the check is not
        /// eliminated: the index is computed from a clamped column plus a row
        /// offset, and the optimizer cannot prove that sum is in range. It
        /// costs a compare and a branch per access — counted under callgrind
        /// on the shape of the upsampler's inner loop, 30% more instructions
        /// for four reads and a write per output, and 60% more on a plain
        /// strided copy where the arithmetic is cheaper and the check is
        /// therefore a larger share of it.
        ///
        /// So the rule in this file is: a `Span` everywhere the cost is
        /// amortized over real work, a pointer in the per-sample loops. The
        /// spelling says which is which, and this one says `unsafe` because
        /// it is.
        func withUnsafeSamples<T>(_ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
            self.buffer.withUnsafeBufferPointer(body)
        }

        /// Runs `body` on this plane's samples through a raw mutable pointer.
        mutating func withUnsafeMutableSamples<T>(
            _ body: (UnsafeMutableBufferPointer<UInt16>) -> T
        ) -> T {
            self.buffer.withUnsafeMutableBufferPointer { body($0) }
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

    /// An image as samples, at each component's own resolution.
    ///
    /// One step below ``Spectral``: the coefficients have been dequantized and
    /// transformed, but a subsampled component is still stored at its own
    /// smaller size rather than stretched to the image's. Planes are padded out
    /// to whole 8×8 blocks, so a plane is usually a little larger than the
    /// component resolution the layout reports.
    public struct Planar<Format> where Format: JPEG.Format {
        /// One component's samples.
        public typealias Plane = JPEG.Data.PlanarPlane

        /// The planes, in layout order.
        public private(set) var planes: [Plane]
        /// The image geometry and component structure.
        public private(set) var layout: JPEG.Layout<Format>
        /// The metadata segments carried over from the stream this image was
        /// decoded from, in stream order.
        public var metadata: [JPEG.Metadata]

        init(planes: [Plane], layout: JPEG.Layout<Format>, metadata: [JPEG.Metadata] = []) {
            self.planes = planes
            self.layout = layout
            self.metadata = metadata
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
        // Once for the image, not once per block. This is a mutable global,
        // and Swift guards a read of one with a dynamic exclusivity check —
        // which per block cost more than the transform dispatch itself. The
        // kernel is documented as a startup setting, so reading it once here
        // is also the only reading that could be coherent.
        let kernel: JPEG.Kernel.InverseTransform = JPEG.Kernel.inverseTransform

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
            // The factors and the destination are reached through pointers taken
            // once for the plane. Both were reached per block before, and the
            // factors per *coefficient*: `table[z: z]` is an array element, so
            // dequantizing paid a bounds check 64 times a block for a table that
            // does not change across the plane.
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 64) { coefficients in
                withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 64) { samples in
                    table.factors.withUnsafeBufferPointer { factors in
                    output.withUnsafeMutableSamples { destination in
                    // A plane is exactly `blocks * n` samples in each direction,
                    // so every block lands wholly inside it and the write is a
                    // straight strided copy. The block writer this replaces
                    // tested every row and column against the plane's edge, which
                    // was never false from here and was its only caller.
                    let extent: Int = plane.blocks.x * n
                    for by: Int in 0 ..< plane.blocks.y {
                        for bx: Int in 0 ..< plane.blocks.x {
                            plane.withBlock(x: bx, y: by) { levels in
                                for z: Int in 0 ..< 64 {
                                    coefficients[z] = .init(levels[z]) * .init(factors[z])
                                }
                            }
                            JPEG.IDCT.transform(
                                .init(coefficients),
                                precision: precision,
                                size: n,
                                into: samples,
                                kernel: kernel
                            )

                            // Both sides of a row are contiguous — `n` samples
                            // of the staging buffer, `n` samples of the plane —
                            // so each row moves as one copy rather than `n`
                            // indexed stores behind a loop whose length the
                            // optimizer cannot see.
                            let base: Int = by * n * extent + bx * n
                            for row: Int in 0 ..< n {
                                UnsafeMutableRawPointer(
                                    destination.baseAddress! + base + row * extent
                                ).copyMemory(
                                    from: samples.baseAddress! + row * n,
                                    byteCount: 2 * n
                                )
                            }
                        }
                    }
                    }
                    }
                }
            }

            return output
        }

        var layout: JPEG.Layout<Format> = self.layout
        layout.width = (self.layout.width * n + 7) / 8
        layout.height = (self.layout.height * n + 7) / 8

        return .init(planes: planes, layout: layout, metadata: self.metadata)
    }
}
