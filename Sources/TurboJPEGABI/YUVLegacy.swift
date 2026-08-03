import CTurboJPEG

/// The 1.x and 2.x spellings of the YUV operations.
///
/// The shape of the change between generations is consistent: the old calls
/// take `subsamp` and `flags` as arguments where the new ones read them from
/// the handle, and they measure sizes in `unsigned long`. So each of these sets
/// the corresponding parameters and delegates.
///
/// `tjEncodeYUV` is the one exception worth noting — its penultimate argument
/// is a *pixel size* in bytes rather than a pixel format, from before the
/// format enumeration existed.

/// Applies the legacy `flags` bitmask and subsampling to a handle.
private func configure(_ handle: tjhandle?, subsamp: Int32, flags: Int32) {
    guard let instance: Instance = Instance.borrow(handle) else {
        return
    }
    instance.parameters[TJPARAM_SUBSAMP.id] = subsamp
    instance.parameters[TJPARAM_BOTTOMUP.id] = flags & TJFLAG_BOTTOMUP != 0 ? 1 : 0
    instance.parameters[TJPARAM_FASTUPSAMPLE.id] = flags & TJFLAG_FASTUPSAMPLE != 0 ? 1 : 0
    instance.parameters[TJPARAM_NOREALLOC.id] = flags & TJFLAG_NOREALLOC != 0 ? 1 : 0
    instance.parameters[TJPARAM_FASTDCT.id] = flags & TJFLAG_FASTDCT != 0 ? 1 : 0
    instance.parameters[TJPARAM_STOPONWARNING.id] = flags & TJFLAG_STOPONWARNING != 0 ? 1 : 0
}

// -- packed pixels to YUV ----------------------------------------------------

@c @implementation
public func tjEncodeYUVPlanes(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ dstPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ strides: UnsafeMutablePointer<Int32>?,
    _ subsamp: Int32,
    _ flags: Int32
) -> Int32 {
    configure(handle, subsamp: subsamp, flags: flags)
    return tj3EncodeYUVPlanes8(
        handle, srcBuf, width, pitch, height, pixelFormat, dstPlanes, strides
    )
}

@c @implementation
public func tjEncodeYUV3(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ align: Int32,
    _ subsamp: Int32,
    _ flags: Int32
) -> Int32 {
    configure(handle, subsamp: subsamp, flags: flags)
    return tj3EncodeYUV8(handle, srcBuf, width, pitch, height, pixelFormat, dstBuf, align)
}

@c @implementation
public func tjEncodeYUV2(
    _ handle: tjhandle?,
    _ srcBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ subsamp: Int32,
    _ flags: Int32
) -> Int32 {
    // No alignment parameter existed yet; rows were always padded to four.
    tjEncodeYUV3(handle, srcBuf, width, pitch, height, pixelFormat, dstBuf, 4, subsamp, flags)
}

@c @implementation
public func tjEncodeYUV(
    _ handle: tjhandle?,
    _ srcBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelSize: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ subsamp: Int32,
    _ flags: Int32
) -> Int32 {
    // The original took a pixel *size* in bytes, from before pixel formats were
    // enumerated. Three and four bytes meant RGB and RGBX; nothing else was
    // expressible.
    let format: Int32
    switch pixelSize {
    case 3:     format = TJPF_RGB.rawValue
    case 4:     format = TJPF_RGBX.rawValue
    case 1:     format = TJPF_GRAY.rawValue
    default:
        Instance.borrow(handle)?.fail("pixel size \(pixelSize) has no equivalent format")
        return -1
    }
    return tjEncodeYUV2(handle, srcBuf, width, pitch, height, format, dstBuf, subsamp, flags)
}

// -- YUV to packed pixels ----------------------------------------------------

@c @implementation
public func tjDecodeYUVPlanes(
    _ handle: tjhandle?,
    _ srcPlanes: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    _ strides: UnsafePointer<Int32>?,
    _ subsamp: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ flags: Int32
) -> Int32 {
    configure(handle, subsamp: subsamp, flags: flags)
    return tj3DecodeYUVPlanes8(
        handle, srcPlanes, strides, dstBuf, width, pitch, height, pixelFormat
    )
}

@c @implementation
public func tjDecodeYUV(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ align: Int32,
    _ subsamp: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ flags: Int32
) -> Int32 {
    configure(handle, subsamp: subsamp, flags: flags)
    return tj3DecodeYUV8(handle, srcBuf, align, dstBuf, width, pitch, height, pixelFormat)
}

// -- JPEG to YUV -------------------------------------------------------------

@c @implementation
public func tjDecompressToYUVPlanes(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: UInt,
    _ dstPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ width: Int32,
    _ strides: UnsafeMutablePointer<Int32>?,
    _ height: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    configure(handle, subsamp: instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue),
              flags: flags)

    // width and height here are a scaled-output request, which is refused for
    // the same reason it is in tjDecompress2: producing full-size planes into a
    // buffer sized for smaller ones overruns it.
    let status: Int32 = tj3DecompressHeader(handle, jpegBuf, .init(jpegSize))
    guard status == 0 else {
        return status
    }
    let full: (width: Int32, height: Int32) = (
        tj3Get(handle, TJPARAM_JPEGWIDTH.id),
        tj3Get(handle, TJPARAM_JPEGHEIGHT.id)
    )
    guard width == 0 || width == full.width, height == 0 || height == full.height else {
        return instance.fail("scaled decompression to YUV is not implemented")
    }

    return tj3DecompressToYUVPlanes8(handle, jpegBuf, .init(jpegSize), dstPlanes, strides)
}

@c @implementation
public func tjDecompressToYUV2(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: UInt,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ align: Int32,
    _ height: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    configure(handle, subsamp: instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue),
              flags: flags)

    let status: Int32 = tj3DecompressHeader(handle, jpegBuf, .init(jpegSize))
    guard status == 0 else {
        return status
    }
    let full: (width: Int32, height: Int32) = (
        tj3Get(handle, TJPARAM_JPEGWIDTH.id),
        tj3Get(handle, TJPARAM_JPEGHEIGHT.id)
    )
    guard width == 0 || width == full.width, height == 0 || height == full.height else {
        return instance.fail("scaled decompression to YUV is not implemented")
    }

    return tj3DecompressToYUV8(handle, jpegBuf, .init(jpegSize), dstBuf, align)
}

@c @implementation
public func tjDecompressToYUV(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafeMutablePointer<UInt8>?,
    _ jpegSize: UInt,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ flags: Int32
) -> Int32 {
    // The 1.x form always used four-byte row alignment and the image's own
    // dimensions.
    tjDecompressToYUV2(handle, jpegBuf, jpegSize, dstBuf, 0, 4, 0, flags)
}

// -- YUV to JPEG -------------------------------------------------------------

@c @implementation
public func tjCompressFromYUVPlanes(
    _ handle: tjhandle?,
    _ srcPlanes: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    _ width: Int32,
    _ strides: UnsafePointer<Int32>?,
    _ height: Int32,
    _ subsamp: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<UInt>?,
    _ jpegQual: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let jpegSize: UnsafeMutablePointer<UInt> = jpegSize else {
        return instance.fail("size pointer must not be NULL")
    }
    configure(handle, subsamp: subsamp, flags: flags)
    instance.parameters[TJPARAM_QUALITY.id] = jpegQual

    var size: Int = .init(jpegSize.pointee)
    let status: Int32 = tj3CompressFromYUVPlanes8(
        handle, srcPlanes, width, strides, height, jpegBuf, &size
    )
    jpegSize.pointee = .init(size)
    return status
}

@c @implementation
public func tjCompressFromYUV(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ align: Int32,
    _ height: Int32,
    _ subsamp: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<UInt>?,
    _ jpegQual: Int32,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let jpegSize: UnsafeMutablePointer<UInt> = jpegSize else {
        return instance.fail("size pointer must not be NULL")
    }
    configure(handle, subsamp: subsamp, flags: flags)
    instance.parameters[TJPARAM_QUALITY.id] = jpegQual

    var size: Int = .init(jpegSize.pointee)
    let status: Int32 = tj3CompressFromYUV8(handle, srcBuf, width, align, height, jpegBuf, &size)
    jpegSize.pointee = .init(size)
    return status
}
