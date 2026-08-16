extension JPEG {
    /// A namespace for the three representations an image passes through.
    ///
    /// Decoding walks down the tiers and encoding walks back up:
    ///
    /// ``Spectral`` — quantized DCT coefficients, one 8×8 block at a time. This
    /// is JPEG's native form, the one the entropy coder actually reads and
    /// writes. Rotating, cropping to a block boundary, or requantizing an image
    /// is lossless here and lossy anywhere else.
    ///
    /// ``Planar`` — samples, after dequantization and the inverse DCT, still at
    /// each component's own subsampled resolution.
    ///
    /// ``Rectangular`` — samples upsampled to the full image resolution and
    /// interleaved, which is what a caller who just wants pixels wants.
    public enum Data {
    }
}

extension JPEG.Data {
    /// One component's coefficients.
    ///
    /// Spelled ``Spectral/Plane`` everywhere it is used, and that is the name to
    /// use. It lives out here, rather than nested inside ``Spectral`` where it
    /// reads more naturally, because it does not mention `Format` and nesting it
    /// would make it pay for the generic parameter anyway.
    ///
    /// `Spectral<A>.Plane` and `Spectral<B>.Plane` would be two distinct types of
    /// identical layout, and neither one's metadata could be emitted at compile
    /// time by a caller that does not know the format. The entropy decoder
    /// touches a plane once per block, so every block instantiated the metadata
    /// for this type and for the array holding it — a cache lookup in the Swift
    /// runtime, about a thousand instructions, for a type that turns out not to
    /// vary. That came to 31M instructions per megapixel image, 19% of the
    /// entropy decode, spent entirely on discovering the same answer 24576 times.
    public struct SpectralPlane {
        /// The plane's size, in 8×8 blocks.
        public let blocks: (x: Int, y: Int)
        /// The quantization table slot this plane's coefficients were
        /// quantized with.
        public var quanta: JPEG.Table.Quantization.Key

        /// Coefficients, block-major: all 64 of one block, then the next.
        ///
        /// Block-major rather than plane-major because every consumer —
        /// entropy coding, dequantization, the inverse DCT — works one
        /// whole block at a time, so this is the layout that keeps them
        /// touching contiguous memory.
        ///
        /// `Int16` matches libjpeg's coefficient type. T.81 caps a
        /// magnitude category at 15, so a coefficient cannot exceed
        /// 32767 and cannot overflow this.
        private var buffer: [Int16]

        init(blocks: (x: Int, y: Int), quanta: JPEG.Table.Quantization.Key) {
            self.blocks = blocks
            self.quanta = quanta
            self.buffer = .init(repeating: 0, count: blocks.x * blocks.y * 64)
        }
    }

    /// An image as quantized DCT coefficients.
    public struct Spectral<Format> where Format: JPEG.Format {
        /// One component's coefficients.
        public typealias Plane = JPEG.Data.SpectralPlane

        /// The planes, in layout order.
        ///
        /// Writable within the module so the entropy decoder can fill them in
        /// place; callers outside it get read-only access.
        public internal(set) var planes: [Plane]
        /// The image geometry and component structure.
        public internal(set) var layout: JPEG.Layout<Format>
        /// The quantization tables in effect, keyed by slot.
        ///
        /// Held alongside the coefficients rather than applied to them, because
        /// leaving the coefficients quantized is what makes lossless editing
        /// possible.
        public var quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization]
        /// The metadata segments of the stream this image was decoded from, in
        /// stream order, or whatever the caller wants written when it is
        /// encoded.
        public var metadata: [JPEG.Metadata]
    }
}

extension JPEG.Data.SpectralPlane {
    /// Accesses the coefficient at index `z` of the block at `(x, y)`.
    ///
    /// -   Parameter z:
    ///     A row-major index into the block, 0 through 63. Not a zigzag index —
    ///     the entropy decoder converts before it gets here.
    ///
    /// Out-of-range blocks read as zero and ignore writes. A scan may code
    /// blocks past the edge of a subsampled plane, and silently discarding them
    /// is simpler and safer than making every caller bounds-check.
    public subscript(x x: Int, y y: Int, z z: Int) -> Int16 {
        get {
            guard 0 ..< self.blocks.x ~= x, 0 ..< self.blocks.y ~= y else {
                return 0
            }
            return self.buffer[((y * self.blocks.x) + x) * 64 + z]
        }
        set {
            guard 0 ..< self.blocks.x ~= x, 0 ..< self.blocks.y ~= y else {
                return
            }
            self.buffer[((y * self.blocks.x) + x) * 64 + z] = newValue
        }
    }

    /// Runs `body` on the 64 coefficients of the block at `(x, y)`, in place.
    ///
    /// Avoids the copy ``block(x:y:)`` makes, which matters because decoding
    /// touches every block of every plane exactly once.
    /// Generic over the thrown type rather than `rethrows`. A plain `rethrows`
    /// propagates `any Error`, which would put an existential back into the
    /// engine and take Embedded Swift away again.
    ///
    /// This reaches the array once per block, which looks like exactly the
    /// waste that hoisting the quantization factors and the kernel pointers out
    /// of their loops removed. Hoisting it the same way — one accessor over the
    /// whole plane, and the dequantizer indexing `levels[block + z]` — measures
    /// **7.1% worse** on a megapixel decode, 1283.7M instructions against
    /// 1198.2M.
    ///
    /// The difference is what the callee can see. Rebasing hands the body a
    /// buffer of exactly sixty-four elements starting at zero, and the
    /// dequantize loop over it vectorizes; an index into the whole plane is an
    /// address the optimizer cannot prove anything about, and the same loop
    /// comes out scalar. The slice is not overhead here, it is the information.
    ///
    /// So this is deliberate, and the number is here because the change is an
    /// attractive one to make twice.
    func withBlock<T, E>(
        x: Int, y: Int, _ body: (UnsafeBufferPointer<Int16>) throws(E) -> T
    ) throws(E) -> T {
        let base: Int = ((y * self.blocks.x) + x) * 64
        return try self.buffer.withUnsafeBufferPointer { (buffer) throws(E) in
            try body(.init(rebasing: buffer[base ..< base + 64]))
        }
    }

    /// Runs `body` on the 64 coefficients of the block at `(x, y)`, writably.
    ///
    /// The mutable counterpart of ``withBlock(x:y:_:)``, and the reason the
    /// entropy decoder does not use the subscript. A `planes[i][x:y:z:] = v`
    /// nests two `_modify` accesses — one on the plane array, one on the plane's
    /// buffer — and each carries its own uniqueness check and bounds check, so a
    /// coefficient store costs far more than the store. This pays that once per
    /// block instead of once per coefficient.
    ///
    /// The block must be inside the plane; unlike the subscript, this does not
    /// silently discard an out-of-range write. The decoder checks first, because
    /// it has somewhere better to put the coefficients of a block the plane does
    /// not contain.
    mutating func withMutableBlock<T, E>(
        x: Int, y: Int, _ body: (UnsafeMutableBufferPointer<Int16>) throws(E) -> T
    ) throws(E) -> T {
        let base: Int = ((y * self.blocks.x) + x) * 64
        return try self.buffer.withUnsafeMutableBufferPointer {
            (buffer) throws(E) in
            try body(.init(rebasing: buffer[base ..< base + 64]))
        }
    }

    /// Whether this plane contains the block at `(x, y)`.
    ///
    /// A scan codes whole MCUs, so a subsampled component at the right or
    /// bottom edge of the image gets blocks the plane has no room for.
    func contains(x: Int, y: Int) -> Bool {
        0 ..< self.blocks.x ~= x && 0 ..< self.blocks.y ~= y
    }

    /// Runs `body` on one row of blocks, in place.
    ///
    /// Block-major storage makes a row contiguous: all 64 coefficients of the
    /// first block, then the next, for the width of the plane. That is exactly
    /// the shape a coefficient-domain filter expects, so it can be handed the
    /// buffer directly rather than a copy of it.
    public mutating func withBlockRow<T>(
        _ y: Int,
        _ body: (UnsafeMutableBufferPointer<Int16>) -> T
    ) -> T {
        let base: Int = y * self.blocks.x * 64
        return self.buffer.withUnsafeMutableBufferPointer {
            body(.init(rebasing: $0[base ..< base + self.blocks.x * 64]))
        }
    }

    /// Copies the block at `(x, y)` out as 64 row-major coefficients.
    public func block(x: Int, y: Int) -> [Int16] {
        guard 0 ..< self.blocks.x ~= x, 0 ..< self.blocks.y ~= y else {
            return .init(repeating: 0, count: 64)
        }
        let base: Int = ((y * self.blocks.x) + x) * 64
        return .init(self.buffer[base ..< base + 64])
    }
}

extension JPEG.Data.Spectral {
    /// Creates a zeroed image sized for the given layout.
    public init(layout: JPEG.Layout<Format>) {
        self.planes = layout.planes.indices.map {
            .init(blocks: layout.blocks(plane: $0), quanta: layout.planes[$0].selector)
        }
        self.layout = layout
        self.quanta = [:]
        self.metadata = []
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

    /// Returns this image re-labelled for a different coding process.
    ///
    /// The coefficients are untouched — only the process that will be written
    /// into the frame header changes. Baseline, extended sequential and
    /// progressive all describe the same quantized coefficients and differ only
    /// in how those are packed into scans, so switching between them costs
    /// nothing and loses nothing.
    ///
    /// Returns `nil` if the process cannot carry this image's sample precision.
    public func reprocessed(as process: JPEG.Process) -> Self? {
        guard process.precisions.contains(self.layout.format.precision) else {
            return nil
        }
        var image: Self = self
        image.layout.process = process
        return image
    }

    /// Runs `body` on one row of blocks of the given plane, in place.
    ///
    /// The entry point a coefficient-domain filter uses. It is exposed here
    /// rather than on the plane because the planes themselves are not writable
    /// from outside the module, and a filter must be able to change what it is
    /// shown.
    public mutating func withBlockRow<T>(
        plane: Int,
        _ y: Int,
        _ body: (UnsafeMutableBufferPointer<Int16>) -> T
    ) -> T {
        self.planes[plane].withBlockRow(y, body)
    }

    /// Records the image height once a `DNL` segment supplies it.
    ///
    /// Only the layout changes. The planes were already allocated from the
    /// frame's MCU count, which a streaming encoder writes correctly even when
    /// it leaves the height at zero.
    mutating func set(height: Int) {
        guard self.layout.height == 0, height > 0 else {
            return
        }
        self.layout.height = height
    }
}
