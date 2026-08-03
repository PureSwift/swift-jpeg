extension JPEG {
    /// A rotation or reflection applied to an image.
    ///
    /// These are exactly the eight symmetries of a rectangle, and every one of
    /// them is *lossless* at this tier. Rotating a decoded image means an
    /// inverse transform, a rotation, and a forward transform, each of which
    /// rounds; rotating the coefficients means rearranging numbers that are
    /// already exact. An image can be rotated back and forth indefinitely
    /// without degrading.
    ///
    /// The catch is at the edges — see ``transformed(_:)``.
    public enum Transform: Sendable, Hashable, CaseIterable {
        case none
        /// Mirror left to right.
        case horizontalFlip
        /// Mirror top to bottom.
        case verticalFlip
        /// Reflect across the main diagonal.
        case transpose
        /// Reflect across the antidiagonal.
        case transverse
        case rotate90
        case rotate180
        case rotate270
    }
}

extension JPEG.Transform {
    /// Whether this transform exchanges the horizontal and vertical axes.
    ///
    /// The four that do also swap the image's dimensions and each component's
    /// sampling factors, which is why a 4:2:2 image becomes 4:4:0 when rotated
    /// a quarter turn rather than staying 4:2:2.
    public var swapsAxes: Bool {
        switch self {
        case .transpose, .transverse, .rotate90, .rotate270:    return true
        case .none, .horizontalFlip, .verticalFlip, .rotate180: return false
        }
    }

    /// Where the block at `(x, y)` moves to, in a grid `blocks` wide and tall.
    ///
    /// Expressed as compositions of the three primitives libjpeg implements —
    /// mirror horizontally, mirror vertically, transpose — because that is what
    /// makes the sign rules below follow mechanically rather than needing eight
    /// separate derivations.
    func destination(
        of block: (x: Int, y: Int),
        in blocks: (x: Int, y: Int)
    ) -> (x: Int, y: Int) {
        switch self {
        case .none:
            return block
        case .horizontalFlip:
            return (x: blocks.x - 1 - block.x, y: block.y)
        case .verticalFlip:
            return (x: block.x, y: blocks.y - 1 - block.y)
        case .rotate180:
            return (x: blocks.x - 1 - block.x, y: blocks.y - 1 - block.y)
        case .transpose:
            return (x: block.y, y: block.x)
        case .transverse:
            return (x: blocks.y - 1 - block.y, y: blocks.x - 1 - block.x)
        case .rotate90:
            // Transpose, then mirror the result horizontally. The transposed
            // grid is `blocks.y` wide, which is what the subtraction is from.
            return (x: blocks.y - 1 - block.y, y: block.x)
        case .rotate270:
            // Transpose, then mirror vertically.
            return (x: block.y, y: blocks.x - 1 - block.x)
        }
    }

    /// Where the coefficient at horizontal frequency `u` and vertical frequency
    /// `v` moves to, and whether its sign flips.
    ///
    /// Mirroring a block is not a rearrangement of its coefficients at all —
    /// the basis functions of odd frequency are themselves odd, so reflecting
    /// the block negates exactly those. Transposing swaps the two frequency
    /// axes. Everything here is one or both of those.
    func destination(of u: Int, _ v: Int) -> (u: Int, v: Int, negated: Bool) {
        switch self {
        case .none:
            return (u, v, false)
        case .horizontalFlip:
            return (u, v, u & 1 == 1)
        case .verticalFlip:
            return (u, v, v & 1 == 1)
        case .rotate180:
            return (u, v, (u ^ v) & 1 == 1)
        case .transpose:
            return (v, u, false)
        case .rotate90:
            // Transpose puts frequency v on the horizontal axis; the following
            // horizontal mirror is what negates it when it is odd.
            return (v, u, v & 1 == 1)
        case .rotate270:
            return (v, u, u & 1 == 1)
        case .transverse:
            return (v, u, (u ^ v) & 1 == 1)
        }
    }
}

extension JPEG.Layout {
    /// Returns this layout with its axes exchanged.
    func transposed() -> Self {
        .init(
            format: self.format,
            process: self.process,
            width: self.height,
            height: self.width,
            planes: self.planes.map {
                .init(
                    sampling: .init(x: $0.sampling.y, y: $0.sampling.x),
                    selector: $0.selector
                )
            },
            keys: self.keys,
            residents: self.residents,
            scale: .init(x: self.scale.y, y: self.scale.x)
        )
    }
}

extension JPEG.Data.Spectral {
    /// Whether a transform can be applied without discarding or mangling edge
    /// blocks.
    ///
    /// A transform moves whole blocks. When the image is not a whole number of
    /// MCUs across, the last column of blocks is partial — it holds real
    /// samples in its left portion and padding in the rest. Mirroring moves
    /// that partial block to the *start* of the row, where the padding lands in
    /// the middle of the image.
    ///
    /// libjpeg's answer is to leave partial edge MCUs untouched, which keeps
    /// the file valid but makes the transform not quite a reflection. Reporting
    /// whether the question even arises lets a caller choose.
    public func isPerfect(for transform: JPEG.Transform) -> Bool {
        guard transform != .none else {
            return true
        }
        let mcu: (x: Int, y: Int) = (
            x: 8 * self.layout.scale.x,
            y: 8 * self.layout.scale.y
        )
        // Mirroring horizontally only cares about the width dividing evenly,
        // and vice versa; the axis-swapping transforms care about both.
        switch transform {
        case .horizontalFlip:
            return self.layout.width % mcu.x == 0
        case .verticalFlip:
            return self.layout.height % mcu.y == 0
        default:
            return self.layout.width % mcu.x == 0 && self.layout.height % mcu.y == 0
        }
    }

    /// The largest whole number of MCUs this image contains, in samples.
    ///
    /// A transform that mirrors an axis has to start from a whole number of
    /// MCUs on that axis. Anything else and the partial block at the far edge —
    /// part real samples, part padding — lands at the near edge, shifting every
    /// row by the width of the padding. That is not a blemish at one edge; it
    /// displaces the entire image.
    func trimmed(for transform: JPEG.Transform) -> (width: Int, height: Int) {
        let mcu: (x: Int, y: Int) = (
            x: 8 * self.layout.scale.x,
            y: 8 * self.layout.scale.y
        )
        let whole: (width: Int, height: Int) = (
            width: self.layout.width / mcu.x * mcu.x,
            height: self.layout.height / mcu.y * mcu.y
        )

        switch transform {
        case .none:
            return (self.layout.width, self.layout.height)
        case .horizontalFlip:
            return (whole.width, self.layout.height)
        case .verticalFlip:
            return (self.layout.width, whole.height)
        default:
            return whole
        }
    }

    /// Applies a lossless rotation or reflection.
    ///
    /// The coefficients are rearranged and selectively negated; nothing is
    /// dequantized, transformed, or requantized, so the result carries exactly
    /// the information the original did. An image can be rotated back and forth
    /// indefinitely without degrading.
    ///
    /// **The result may be slightly smaller than the input.** When the image is
    /// not a whole number of MCUs on an axis the transform mirrors, the partial
    /// edge is dropped rather than mirrored, because mirroring it would move
    /// its padding into the interior and shift the whole image. Losing at most
    /// fifteen columns or rows is the lesser evil, and it is what libjpeg's
    /// `TJXOPT_TRIM` does. Use ``isPerfect(for:)`` to find out in advance
    /// whether anything will be dropped.
    public func transformed(_ transform: JPEG.Transform) -> Self {
        guard transform != .none else {
            return self
        }

        let trimmed: (width: Int, height: Int) = self.trimmed(for: transform)
        var source: JPEG.Layout<Format> = self.layout
        source.height = trimmed.height
        source.width = trimmed.width

        let layout: JPEG.Layout<Format> = transform.swapsAxes
            ? source.transposed()
            : source

        var output: Self = .init(layout: layout)
        // The quantization tables travel with the coefficients. A transform
        // that exchanges the frequency axes has to exchange the factors too,
        // or every coefficient is dequantized by its transpose's factor.
        output.quanta = transform.swapsAxes
            ? self.quanta.mapValues { $0.transposed() }
            : self.quanta

        for plane: Int in self.planes.indices {
            // The block grid of the *trimmed* image, which is what gets
            // mirrored. Blocks outside it are the partial edge and are dropped.
            let blocks: (x: Int, y: Int) = source.blocks(plane: plane)

            for by: Int in 0 ..< blocks.y {
                for bx: Int in 0 ..< blocks.x {
                    let target: (x: Int, y: Int) = transform.destination(
                        of: (x: bx, y: by), in: blocks
                    )

                    for v: Int in 0 ..< 8 {
                        for u: Int in 0 ..< 8 {
                            let moved: (u: Int, v: Int, negated: Bool) =
                                transform.destination(of: u, v)
                            let coefficient: Int16 = self.planes[plane][
                                x: bx, y: by, z: v << 3 | u
                            ]

                            output.planes[plane][
                                x: target.x,
                                y: target.y,
                                z: moved.v << 3 | moved.u
                            ] = moved.negated ? 0 &- coefficient : coefficient
                        }
                    }
                }
            }
        }

        return output
    }
}
