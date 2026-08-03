import CTurboJPEG

/// Rounds `value` up to a multiple of `alignment`.
///
/// The reference implementation uses a bitmask, which is correct only for
/// powers of two. Every alignment this library pads to happens to be one, but
/// the division form costs nothing measurable and cannot be wrong.
func pad(_ value: Int, to alignment: Int) -> Int {
    (value + alignment - 1) / alignment * alignment
}

/// Whether `value` is a positive power of two.
func isPowerOfTwo(_ value: Int) -> Bool {
    value >= 1 && value & (value - 1) == 0
}

/// The geometry of a planar YUV image, as TurboJPEG defines it.
///
/// Worth stating precisely, because the rounding is not the obvious one and
/// getting it wrong produces buffers that are the right shape but the wrong
/// size — which surfaces as a caller's heap being overrun rather than as a
/// visibly broken image.
///
/// The luma plane is padded up to a multiple of the *sampling factor*, not the
/// MCU width, and each chroma plane is then that padded width divided by the
/// factor. So a 133-wide 4:2:0 image has a 134-sample luma plane and 67-sample
/// chroma planes, not 133 and 67.
enum YUVGeometry {
    /// The width of one plane, in samples.
    static func width(component: Int, width: Int, sampling: Subsampling) -> Int {
        let padded: Int = pad(width, to: sampling.mcu.width / 8)
        return component == 0 ? padded : padded * 8 / sampling.mcu.width
    }

    /// The height of one plane, in samples.
    static func height(component: Int, height: Int, sampling: Subsampling) -> Int {
        let padded: Int = pad(height, to: sampling.mcu.height / 8)
        return component == 0 ? padded : padded * 8 / sampling.mcu.height
    }
}

@c @implementation
public func tj3YUVPlaneWidth(_ componentID: Int32, _ width: Int32, _ subsamp: Int32) -> Int32 {
    guard
    width >= 1,
    let sampling: Subsampling = .init(subsamp),
    0 ..< sampling.planes ~= .init(componentID)
    else {
        return 0
    }
    return .init(YUVGeometry.width(component: .init(componentID), width: .init(width),
                                   sampling: sampling))
}

@c @implementation
public func tj3YUVPlaneHeight(_ componentID: Int32, _ height: Int32, _ subsamp: Int32) -> Int32 {
    guard
    height >= 1,
    let sampling: Subsampling = .init(subsamp),
    0 ..< sampling.planes ~= .init(componentID)
    else {
        return 0
    }
    return .init(YUVGeometry.height(component: .init(componentID), height: .init(height),
                                    sampling: sampling))
}

@c @implementation
public func tj3YUVPlaneSize(
    _ componentID: Int32,
    _ width: Int32,
    _ stride: Int32,
    _ height: Int32,
    _ subsamp: Int32
) -> Int {
    guard width >= 1, height >= 1, let sampling: Subsampling = .init(subsamp) else {
        return 0
    }
    let planeWidth: Int32 = tj3YUVPlaneWidth(componentID, width, subsamp)
    let planeHeight: Int32 = tj3YUVPlaneHeight(componentID, height, subsamp)
    guard planeWidth > 0, planeHeight > 0 else {
        return 0
    }

    let stride: Int = stride == 0 ? .init(planeWidth) : abs(.init(stride))
    // The final row is not padded out to the stride: a plane ends at its last
    // real sample. Sizing it as stride * height would over-report by up to one
    // row of padding, which is harmless, but under-reporting anywhere is not,
    // so this matches the reference exactly.
    return stride * (.init(planeHeight) - 1) + .init(planeWidth)
}

@c @implementation
public func tj3YUVBufSize(_ width: Int32, _ align: Int32, _ height: Int32, _ subsamp: Int32) -> Int {
    guard
    width >= 1, height >= 1,
    isPowerOfTwo(.init(align)),
    let sampling: Subsampling = .init(subsamp)
    else {
        return 0
    }

    var total: Int = 0
    for component: Int in 0 ..< sampling.planes {
        let planeWidth: Int = YUVGeometry.width(
            component: component, width: .init(width), sampling: sampling
        )
        let planeHeight: Int = YUVGeometry.height(
            component: component, height: .init(height), sampling: sampling
        )
        // Every row including the last is padded here, unlike a single plane's
        // size, because the next plane has to start on an aligned boundary.
        total += pad(planeWidth, to: .init(align)) * planeHeight
    }
    return total
}

// -- the 1.x and 2.x spellings ----------------------------------------------

@c @implementation
public func tjBufSizeYUV2(_ width: Int32, _ align: Int32, _ height: Int32, _ subsamp: Int32) -> UInt {
    .init(tj3YUVBufSize(width, align, height, subsamp))
}

@c @implementation
public func tjBufSizeYUV(_ width: Int32, _ height: Int32, _ subsamp: Int32) -> UInt {
    // The 1.x form had no alignment parameter and always padded rows to four
    // bytes.
    tjBufSizeYUV2(width, 4, height, subsamp)
}

@c @implementation
public func tjPlaneSizeYUV(
    _ componentID: Int32,
    _ width: Int32,
    _ stride: Int32,
    _ height: Int32,
    _ subsamp: Int32
) -> UInt {
    .init(tj3YUVPlaneSize(componentID, width, stride, height, subsamp))
}
