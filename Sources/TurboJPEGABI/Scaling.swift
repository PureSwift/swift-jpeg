import CTurboJPEG

/// The scaling factors this library supports during decompression.
///
/// Eight of them, `n/8` for `n` from 1 through 8. They are exactly the
/// reductions a scaled inverse transform can produce directly: an `n`-point
/// transform of the lowest `n` frequencies on each axis. libjpeg-turbo also
/// offers the eight *enlargements* from 9/8 to 2/1, which need interpolation
/// rather than a smaller transform, and which this library does not do.
///
/// Advertising exactly what is supported is the point. A caller picks a factor
/// from this list and then asks for that size, so listing one that would be
/// refused turns a capability query into a runtime failure.
///
/// Storage is a global rather than a per-call allocation because the C
/// signature returns a pointer the caller does not own and never frees.
private nonisolated(unsafe) let supported: UnsafeMutablePointer<tjscalingfactor> = {
    // Lowest terms, ascending, which is the order libjpeg-turbo lists them in.
    let fractions: [(Int32, Int32)] = [
        (1, 8), (1, 4), (3, 8), (1, 2), (5, 8), (3, 4), (7, 8), (1, 1),
    ]
    let buffer: UnsafeMutablePointer<tjscalingfactor> = .allocate(capacity: fractions.count)
    for (i, fraction): (Int, (Int32, Int32)) in fractions.enumerated() {
        buffer[i] = tjscalingfactor(num: fraction.0, denom: fraction.1)
    }
    return buffer
}()

private let supportedCount: Int32 = 8

/// The output size a dimension scales to, matching the header's `TJSCALED`.
func scaled(_ dimension: Int, by factor: (numerator: Int, denominator: Int)) -> Int {
    (dimension * factor.numerator + factor.denominator - 1) / factor.denominator
}

@c @implementation
public func tj3GetScalingFactors(
    _ numScalingFactors: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<tjscalingfactor>? {
    guard let numScalingFactors: UnsafeMutablePointer<Int32> = numScalingFactors else {
        return nil
    }
    numScalingFactors.pointee = supportedCount
    return supported
}

@c @implementation
public func tjGetScalingFactors(
    _ numscalingfactors: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<tjscalingfactor>? {
    tj3GetScalingFactors(numscalingfactors)
}

@c @implementation
public func tj3SetScalingFactor(_ handle: tjhandle?, _ scalingFactor: tjscalingfactor) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard scalingFactor.denom > 0, scalingFactor.num > 0 else {
        return instance.fail("a scaling factor must be positive")
    }
    // Compared as a fraction rather than by field equality, so that a caller
    // passing 2/16 gets the same answer as one passing 1/8.
    for index: Int in 0 ..< Int(supportedCount) {
        let candidate: tjscalingfactor = supported[index]
        if Int(candidate.num) * Int(scalingFactor.denom)
            == Int(candidate.denom) * Int(scalingFactor.num)
        {
            instance.scalingFactor = (
                numerator: .init(candidate.num),
                denominator: .init(candidate.denom)
            )
            return 0
        }
    }

    return instance.fail(
        "unsupported scaling factor \(scalingFactor.num)/\(scalingFactor.denom)"
    )
}

@c @implementation
public func tj3SetCroppingRegion(_ handle: tjhandle?, _ croppingRegion: tjregion) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    // An all-zero region means "no cropping", which is how the region is
    // cleared once set.
    if croppingRegion.x == 0, croppingRegion.y == 0,
       croppingRegion.w == 0, croppingRegion.h == 0
    {
        instance.croppingRegion = nil
        return 0
    }

    guard croppingRegion.x >= 0, croppingRegion.y >= 0,
          croppingRegion.w > 0, croppingRegion.h > 0
    else {
        return instance.fail("a cropping region must have a positive size and origin")
    }

    instance.croppingRegion = (
        x: .init(croppingRegion.x),
        y: .init(croppingRegion.y),
        width: .init(croppingRegion.w),
        height: .init(croppingRegion.h)
    )
    return 0
}
