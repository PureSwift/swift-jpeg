import CTurboJPEG
import JPEG

/// A view over the three planes of a YUV image, however the caller supplied
/// them.
///
/// TurboJPEG offers each YUV operation in two spellings: one taking a single
/// packed buffer plus a row alignment, and one taking separate plane pointers
/// plus per-plane strides. They describe the same data, so this type is what
/// both collapse into, and every conversion is written once against it.
struct YUVPlaneSet {
    struct Plane {
        let base: UnsafeMutablePointer<UInt8>
        let stride: Int
        let width: Int
        let height: Int
    }

    let planes: [Plane]
    let sampling: Subsampling

    /// Describes the planes inside one packed buffer.
    ///
    /// Planes follow each other with no gap, each row padded up to `align`
    /// bytes. This is the layout ``tj3YUVBufSize`` measures, so the two have to
    /// agree exactly or a caller sizing with one and writing with the other
    /// overruns their allocation.
    init(
        packed base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        align: Int,
        sampling: Subsampling
    ) {
        var planes: [Plane] = []
        var offset: Int = 0

        for component: Int in 0 ..< sampling.planes {
            let planeWidth: Int = YUVGeometry.width(
                component: component, width: width, sampling: sampling
            )
            let planeHeight: Int = YUVGeometry.height(
                component: component, height: height, sampling: sampling
            )
            let stride: Int = pad(planeWidth, to: align)

            planes.append(
                .init(
                    base: base + offset,
                    stride: stride,
                    width: planeWidth,
                    height: planeHeight
                )
            )
            offset += stride * planeHeight
        }

        self.planes = planes
        self.sampling = sampling
    }

    /// Describes planes the caller supplied separately.
    ///
    /// A stride of zero means "as wide as the plane". A *negative* stride means
    /// the rows are stored bottom-up, which TurboJPEG allows and which is why
    /// the pointer arithmetic below cannot assume rows advance forward.
    init?(
        separate: UnsafePointer<UnsafeMutablePointer<UInt8>?>?,
        strides: UnsafePointer<Int32>?,
        width: Int,
        height: Int,
        sampling: Subsampling
    ) {
        guard let separate: UnsafePointer<UnsafeMutablePointer<UInt8>?> = separate else {
            return nil
        }

        var planes: [Plane] = []
        for component: Int in 0 ..< sampling.planes {
            guard let base: UnsafeMutablePointer<UInt8> = separate[component] else {
                return nil
            }
            let planeWidth: Int = YUVGeometry.width(
                component: component, width: width, sampling: sampling
            )
            let planeHeight: Int = YUVGeometry.height(
                component: component, height: height, sampling: sampling
            )
            let stride: Int = strides.map { Int($0[component]) } ?? 0

            planes.append(
                .init(
                    base: base,
                    stride: stride == 0 ? planeWidth : stride,
                    width: planeWidth,
                    height: planeHeight
                )
            )
        }

        self.planes = planes
        self.sampling = sampling
    }
}

extension YUVPlaneSet.Plane {
    /// The first byte of the given row, honoring a negative stride.
    func row(_ y: Int) -> UnsafeMutablePointer<UInt8> {
        self.base + y * self.stride
    }
}

extension YUVPlaneSet {
    /// The layout a JPEG of these planes would have.
    func layout() throws -> JPEG.Layout<JPEG.Common> {
        try .init(
            format: self.sampling.isGray
                ? .y(1, precision: 8)
                : .ycc(1, 2, 3, precision: 8),
            process: .baseline,
            width: self.planes[0].width,
            height: self.planes[0].height,
            sampling: self.sampling.isGray
                ? [.init(x: 1, y: 1)]
                : [self.sampling.luma, .init(x: 1, y: 1), .init(x: 1, y: 1)],
            selectors: self.sampling.isGray ? [0] : [0, 1, 1]
        )
    }

    /// Copies these planes into a planar image, extending the edge into the
    /// block padding.
    ///
    /// The two paddings do not coincide: a YUV plane is padded to the sampling
    /// factor, a coded plane to a whole 8×8 block. Leaving the difference at
    /// zero would put a hard step to black just past the last real sample,
    /// which the transform then spends bits describing.
    func planar(width: Int, height: Int) throws -> JPEG.Data.Planar<JPEG.Common> {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: self.sampling.isGray
                ? .y(1, precision: 8)
                : .ycc(1, 2, 3, precision: 8),
            process: .baseline,
            width: width,
            height: height,
            sampling: self.sampling.isGray
                ? [.init(x: 1, y: 1)]
                : [self.sampling.luma, .init(x: 1, y: 1), .init(x: 1, y: 1)],
            selectors: self.sampling.isGray ? [0] : [0, 1, 1]
        )

        var image: JPEG.Data.Planar<JPEG.Common> = .init(layout: layout)

        for component: Int in 0 ..< self.planes.count {
            let source: Plane = self.planes[component]
            let size: (x: Int, y: Int) = image[component].size

            for y: Int in 0 ..< size.y {
                let row: UnsafeMutablePointer<UInt8> =
                    source.row(Swift.min(y, source.height - 1))
                for x: Int in 0 ..< size.x {
                    image[component][x: x, y: y] =
                        .init(row[Swift.min(x, source.width - 1)])
                }
            }
        }

        return image
    }

    /// Copies a planar image out into these planes.
    func fill(from image: JPEG.Data.Planar<JPEG.Common>) {
        for component: Int in 0 ..< Swift.min(self.planes.count, image.planes.count) {
            let destination: Plane = self.planes[component]
            let source: JPEG.Data.Planar<JPEG.Common>.Plane = image[component]

            for y: Int in 0 ..< destination.height {
                let row: UnsafeMutablePointer<UInt8> = destination.row(y)
                for x: Int in 0 ..< destination.width {
                    // The coded plane is padded out to whole blocks, so it is
                    // never smaller than the YUV plane and the clamp in its
                    // subscript is not load-bearing here.
                    row[x] = .init(truncatingIfNeeded: source[x: x, y: y])
                }
            }
        }
    }
}
