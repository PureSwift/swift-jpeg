import CTurboJPEG

/// The scaling factors this library supports during decompression.
///
/// One entry, 1/1. libjpeg-turbo advertises sixteen, from 2/1 down to 1/8,
/// because its decoder can produce a reduced-size image directly out of the
/// coefficients — cheaper than decoding fully and resampling.
///
/// Advertising only what is actually supported is the point. A caller picks a
/// factor from this list and then asks for that size, so listing 1/2 while
/// refusing to produce it would turn a capability query into a runtime failure.
/// Truthful and unscaled beats optimistic and broken; scaled decoding belongs
/// at the ``JPEG/Data/Spectral`` tier, where discarding high-frequency
/// coefficients gives the reduction almost for free, and this list grows when
/// that lands.
///
/// Storage is a global rather than a per-call allocation because the C
/// signature returns a pointer the caller does not own and never frees.
private nonisolated(unsafe) let supported: UnsafeMutablePointer<tjscalingfactor> = {
    let buffer: UnsafeMutablePointer<tjscalingfactor> = .allocate(capacity: 1)
    buffer.initialize(to: tjscalingfactor(num: 1, denom: 1))
    return buffer
}()

private let supportedCount: Int32 = 1

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
