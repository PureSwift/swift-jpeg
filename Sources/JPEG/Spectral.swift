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
    /// An image as quantized DCT coefficients.
    public struct Spectral<Format> where Format: JPEG.Format {
        /// One component's coefficients.
        public struct Plane {
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

        /// The planes, in layout order.
        public private(set) var planes: [Plane]
        /// The image geometry and component structure.
        public private(set) var layout: JPEG.Layout<Format>
        /// The quantization tables in effect, keyed by slot.
        ///
        /// Held alongside the coefficients rather than applied to them, because
        /// leaving the coefficients quantized is what makes lossless editing
        /// possible.
        public var quanta: [JPEG.Table.Quantization.Key: JPEG.Table.Quantization]
    }
}

extension JPEG.Data.Spectral.Plane {
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
