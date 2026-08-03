import CTurboJPEG

/// The TurboJPEG 1.0 entry points.
///
/// The oldest surface still exported, and the least like the modern one. These
/// predate pixel format enumerations, `size_t`, and caller-allocated output
/// buffers, so each carries a translation the later spellings do not need.
///
/// They exist because binaries linked in 2010 still resolve them, which is
/// exactly the constituency a drop-in replacement is for.

/// Translates a 1.0 pixel size, in bytes, to a pixel format.
///
/// The original API described a pixel by how wide it was and assumed the rest.
/// `TJ_BGR` in the flags word selected the reversed component order, which is
/// why the flags have to be consulted to answer a question about layout.
private func format(pixelSize: Int32, flags: Int32) -> Int32? {
    let reversed: Bool = flags & TJ_BGR != 0
    switch pixelSize {
    case 1:     return TJPF_GRAY.rawValue
    case 3:     return reversed ? TJPF_BGR.rawValue : TJPF_RGB.rawValue
    case 4:
        // TJ_ALPHAFIRST moved the padding byte to the front.
        if flags & TJ_ALPHAFIRST != 0 {
            return reversed ? TJPF_XBGR.rawValue : TJPF_XRGB.rawValue
        } else {
            return reversed ? TJPF_BGRX.rawValue : TJPF_RGBX.rawValue
        }
    default:    return nil
    }
}

@c @implementation
public func TJBUFSIZE(_ width: Int32, _ height: Int32) -> UInt {
    // The 1.0 function took no subsampling argument, so it had to return a
    // bound that holds for any of them. 4:4:4 is the largest.
    tjBufSize(width, height, TJSAMP_444.rawValue)
}

@c @implementation
public func TJBUFSIZEYUV(_ width: Int32, _ height: Int32, _ jpegSubsamp: Int32) -> UInt {
    tjBufSizeYUV(width, height, jpegSubsamp)
}

@c @implementation
public func tjCompress(
    _ handle: tjhandle?,
    _ srcBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelSize: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ compressedSize: UnsafeMutablePointer<UInt>?,
    _ jpegSubsamp: Int32,
    _ jpegQual: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let compressedSize: UnsafeMutablePointer<UInt> = compressedSize else {
        return instance.fail("size pointer must not be NULL")
    }
    guard let pixelFormat: Int32 = format(pixelSize: pixelSize, flags: flags) else {
        return instance.fail("pixel size \(pixelSize) has no equivalent format")
    }

    // The 1.0 API had no reallocating form: the caller always supplied the
    // buffer, having sized it with TJBUFSIZE. That is TJFLAG_NOREALLOC in
    // every later spelling, so it is forced here regardless of the flags.
    var destination: UnsafeMutablePointer<UInt8>? = dstBuf
    var size: UInt = TJBUFSIZE(width, height)
    let status: Int32 = tjCompress2(
        handle, srcBuf, width, pitch, height, pixelFormat,
        &destination, &size, jpegSubsamp, jpegQual, flags | TJFLAG_NOREALLOC
    )
    compressedSize.pointee = size
    return status
}

@c @implementation
public func tjDecompress(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafeMutablePointer<UInt8>?,
    _ jpegSize: UInt,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelSize: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let pixelFormat: Int32 = format(pixelSize: pixelSize, flags: flags) else {
        return instance.fail("pixel size \(pixelSize) has no equivalent format")
    }
    return tjDecompress2(
        handle, jpegBuf, jpegSize, dstBuf, width, pitch, height, pixelFormat, flags
    )
}
