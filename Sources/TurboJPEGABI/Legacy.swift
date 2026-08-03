import CTurboJPEG

/// The 1.x and 2.x entry points, expressed in terms of the TJ3 API.
///
/// Deprecated upstream but very much alive: most software linking TurboJPEG
/// today was written against these, so a library that implements only the TJ3
/// surface is not a drop-in replacement for anything. They are thin on purpose
/// — every one of them translates its arguments and delegates, so there is one
/// implementation of each behavior rather than two that can disagree.
///
/// The translation is not always trivial. The old API carried its options in a
/// `flags` bitmask and its sizes in `unsigned long`; the new one uses handle
/// parameters and `size_t`. Both differences are handled here so the engine
/// never sees either convention.

/// Applies the legacy `flags` bitmask to a handle's parameters.
///
/// Only the flags that map onto something real are honored. The `TJFLAG_FORCE*`
/// family selected SIMD paths in TurboJPEG 1.x and was already ignored by
/// TurboJPEG itself long before it was removed, so ignoring it here matches
/// the reference build rather than silently dropping something meaningful.
private func apply(flags: Int32, to instance: Instance) {
    instance.parameters[TJPARAM_BOTTOMUP.id] = flags & TJFLAG_BOTTOMUP != 0 ? 1 : 0
    instance.parameters[TJPARAM_FASTUPSAMPLE.id] = flags & TJFLAG_FASTUPSAMPLE != 0 ? 1 : 0
    instance.parameters[TJPARAM_NOREALLOC.id] = flags & TJFLAG_NOREALLOC != 0 ? 1 : 0
    instance.parameters[TJPARAM_FASTDCT.id] = flags & TJFLAG_FASTDCT != 0 ? 1 : 0
    instance.parameters[TJPARAM_STOPONWARNING.id] = flags & TJFLAG_STOPONWARNING != 0 ? 1 : 0
    instance.parameters[TJPARAM_PROGRESSIVE.id] = flags & TJFLAG_PROGRESSIVE != 0 ? 1 : 0
}

// -- lifecycle ---------------------------------------------------------------

// These call tj3InitLegacy rather than going through the version-checked entry
// point: a 1.x client has no API version to declare, which is precisely the
// situation the unversioned initializer exists for.

@c @implementation
public func tjInitCompress() -> tjhandle! {
    tj3InitLegacy(TJINIT_COMPRESS.id)
}

@c @implementation
public func tjInitDecompress() -> tjhandle! {
    tj3InitLegacy(TJINIT_DECOMPRESS.id)
}

@c @implementation
public func tjInitTransform() -> tjhandle! {
    tj3InitLegacy(TJINIT_TRANSFORM.id)
}

@c @implementation
public func tjDestroy(_ handle: tjhandle?) -> Int32 {
    // Unlike tj3Destroy this returns a status, and TurboJPEG documents it as
    // always succeeding.
    tj3Destroy(handle)
    return 0
}

@c @implementation
public func tjAlloc(_ bytes: Int32) -> UnsafeMutablePointer<UInt8>? {
    guard bytes > 0 else {
        return nil
    }
    return tj3Alloc(.init(bytes))?.bindMemory(to: UInt8.self, capacity: .init(bytes))
}

@c @implementation
public func tjFree(_ buffer: UnsafeMutablePointer<UInt8>?) {
    tj3Free(buffer)
}

// -- error reporting ---------------------------------------------------------

@c @implementation
public func tjGetErrorStr2(_ handle: tjhandle?) -> UnsafeMutablePointer<CChar>? {
    tj3GetErrorStr(handle)
}

@c @implementation
public func tjGetErrorStr() -> UnsafeMutablePointer<CChar>? {
    // The 1.x form had no handle at all, so it can only report the global
    // error slot.
    tj3GetErrorStr(nil)
}

@c @implementation
public func tjGetErrorCode(_ handle: tjhandle?) -> Int32 {
    tj3GetErrorCode(handle)
}

// -- buffer sizing -----------------------------------------------------------

@c @implementation
public func tjBufSize(_ width: Int32, _ height: Int32, _ jpegSubsamp: Int32) -> UInt {
    .init(tj3JPEGBufSize(width, height, jpegSubsamp))
}

@c @implementation
public func tjPlaneWidth(_ componentID: Int32, _ width: Int32, _ subsamp: Int32) -> Int32 {
    guard let sampling: Subsampling = .init(subsamp), width >= 1 else {
        return -1
    }
    guard componentID != 0 else {
        return width
    }
    guard componentID < (sampling.isGray ? 1 : 3) else {
        return -1
    }
    // Chrominance is sampled once per luma sampling factor, rounded up so a
    // partial group still gets a sample.
    return .init((Int(width) + sampling.luma.x - 1) / sampling.luma.x)
}

@c @implementation
public func tjPlaneHeight(_ componentID: Int32, _ height: Int32, _ subsamp: Int32) -> Int32 {
    guard let sampling: Subsampling = .init(subsamp), height >= 1 else {
        return -1
    }
    guard componentID != 0 else {
        return height
    }
    guard componentID < (sampling.isGray ? 1 : 3) else {
        return -1
    }
    return .init((Int(height) + sampling.luma.y - 1) / sampling.luma.y)
}

// -- compression -------------------------------------------------------------

@c @implementation
public func tjCompress2(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<UInt>?,
    _ jpegSubsamp: Int32,
    _ jpegQual: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let jpegSize: UnsafeMutablePointer<UInt> = jpegSize else {
        return instance.fail("size pointer must not be NULL")
    }

    apply(flags: flags, to: instance)
    instance.parameters[TJPARAM_SUBSAMP.id] = jpegSubsamp
    instance.parameters[TJPARAM_QUALITY.id] = jpegQual

    // The old API measured sizes in unsigned long and the new one in size_t.
    // They are the same width on the platforms this builds for, but going
    // through a local keeps the conversion explicit rather than assumed.
    var size: Int = .init(jpegSize.pointee)
    let status: Int32 = tj3Compress8(
        handle, srcBuf, width, pitch, height, pixelFormat, jpegBuf, &size
    )
    jpegSize.pointee = .init(size)
    return status
}

// -- decompression -----------------------------------------------------------

@c @implementation
public func tjDecompressHeader3(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: UInt,
    _ width: UnsafeMutablePointer<Int32>?,
    _ height: UnsafeMutablePointer<Int32>?,
    _ jpegSubsamp: UnsafeMutablePointer<Int32>?,
    _ jpegColorspace: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let status: Int32 = tj3DecompressHeader(handle, jpegBuf, .init(jpegSize))
    guard status == 0 else {
        return status
    }

    width?.pointee = tj3Get(handle, TJPARAM_JPEGWIDTH.id)
    height?.pointee = tj3Get(handle, TJPARAM_JPEGHEIGHT.id)
    jpegSubsamp?.pointee = tj3Get(handle, TJPARAM_SUBSAMP.id)
    jpegColorspace?.pointee = tj3Get(handle, TJPARAM_COLORSPACE.id)
    return 0
}

@c @implementation
public func tjDecompressHeader2(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafeMutablePointer<UInt8>?,
    _ jpegSize: UInt,
    _ width: UnsafeMutablePointer<Int32>?,
    _ height: UnsafeMutablePointer<Int32>?,
    _ jpegSubsamp: UnsafeMutablePointer<Int32>?
) -> Int32 {
    tjDecompressHeader3(handle, jpegBuf, jpegSize, width, height, jpegSubsamp, nil)
}

@c @implementation
public func tjDecompressHeader(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafeMutablePointer<UInt8>?,
    _ jpegSize: UInt,
    _ width: UnsafeMutablePointer<Int32>?,
    _ height: UnsafeMutablePointer<Int32>?
) -> Int32 {
    tjDecompressHeader3(handle, jpegBuf, jpegSize, width, height, nil, nil)
}

@c @implementation
public func tjDecompress2(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: UInt,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    apply(flags: flags, to: instance)

    // Reading the header first is what makes the size check below possible,
    // and it is cheap relative to the decode that follows.
    let status: Int32 = tj3DecompressHeader(handle, jpegBuf, .init(jpegSize))
    guard status == 0 else {
        return status
    }

    // Zero means "the JPEG's own size". Anything else is a request for scaled
    // output, which this library does not do yet — and refusing is the only
    // honest answer, since writing full-size pixels into a buffer sized for a
    // smaller image would overrun it.
    let full: (width: Int32, height: Int32) = (
        tj3Get(handle, TJPARAM_JPEGWIDTH.id),
        tj3Get(handle, TJPARAM_JPEGHEIGHT.id)
    )
    guard width == 0 || width == full.width, height == 0 || height == full.height else {
        return instance.fail(
            "scaled decompression is not implemented: asked for \(width)x\(height), "
                + "image is \(full.width)x\(full.height)"
        )
    }

    return tj3Decompress8(handle, jpegBuf, .init(jpegSize), dstBuf, pitch, pixelFormat)
}
