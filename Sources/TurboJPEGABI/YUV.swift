import CTurboJPEG
import JPEG

/// Resolves the subsampling a YUV operation should use, or records why it
/// cannot.
private func subsampling(of instance: Instance) -> Subsampling? {
    Subsampling(instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue))
}

// -- packed pixels to YUV planes ---------------------------------------------

@c @implementation
public func tj3EncodeYUVPlanes8(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ dstPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ strides: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let srcBuf: UnsafePointer<UInt8> = srcBuf, width >= 1, height >= 1 else {
        return instance.fail("source buffer must not be NULL and the size must be positive")
    }
    guard let format: PixelFormat = .init(pixelFormat) else {
        return instance.fail("unsupported pixel format \(pixelFormat)")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }
    guard
    let destination: YUVPlaneSet = .init(
        separate: dstPlanes, strides: strides,
        width: .init(width), height: .init(height), sampling: sampling
    )
    else {
        return instance.fail("destination planes must not be NULL")
    }

    let stride: Int = pitch == 0 ? .init(width) * format.size : .init(pitch)
    guard stride >= .init(width) * format.size else {
        return instance.fail("pitch \(pitch) is smaller than one row")
    }

    do {
        // Color conversion and subsampling, and nothing else — this produces
        // the planes a JPEG would be coded from without coding one.
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: sampling.isGray ? .y(1, precision: 8) : .ycc(1, 2, 3, precision: 8),
            process: .baseline,
            width: .init(width),
            height: .init(height),
            sampling: sampling.isGray
                ? [.init(x: 1, y: 1)]
                : [sampling.luma, .init(x: 1, y: 1), .init(x: 1, y: 1)],
            selectors: sampling.isGray ? [0] : [0, 1, 1]
        )

        let planes: Int = sampling.isGray ? 1 : 3
        var values: [UInt16] = .init(
            repeating: 0, count: .init(width) * .init(height) * planes
        )
        for y: Int in 0 ..< Int(height) {
            let row: UnsafePointer<UInt8> = srcBuf + y * stride
            for x: Int in 0 ..< Int(width) {
                let pixel: UnsafePointer<UInt8> = row + x * format.size
                let color: JPEG.YCbCr = format.isGray
                    ? .init(y: pixel[0])
                    : .init(.init(pixel[format.red], pixel[format.green], pixel[format.blue]))

                let base: Int = (y * .init(width) + x) * planes
                values[base] = .init(color.y)
                if planes > 1 {
                    values[base + 1] = .init(color.cb)
                    values[base + 2] = .init(color.cr)
                }
            }
        }

        let image: JPEG.Data.Rectangular<JPEG.Common> = .init(layout: layout, values: values)
        destination.fill(from: image.subsampled())
        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tj3EncodeYUV8(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ align: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let dstBuf: UnsafeMutablePointer<UInt8> = dstBuf, isPowerOfTwo(.init(align)) else {
        return instance.fail("destination must not be NULL and align must be a power of two")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }

    let set: YUVPlaneSet = .init(
        packed: dstBuf, width: .init(width), height: .init(height),
        align: .init(align), sampling: sampling
    )
    return withPlanePointers(set) { planes, strides in
        tj3EncodeYUVPlanes8(handle, srcBuf, width, pitch, height, pixelFormat, planes, strides)
    }
}

// -- YUV planes to packed pixels ---------------------------------------------

@c @implementation
public func tj3DecodeYUVPlanes8(
    _ handle: tjhandle?,
    _ srcPlanes: UnsafePointer<UnsafePointer<UInt8>?>?,
    _ strides: UnsafePointer<Int32>?,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let dstBuf: UnsafeMutablePointer<UInt8> = dstBuf, width >= 1, height >= 1 else {
        return instance.fail("destination must not be NULL and the size must be positive")
    }
    guard let format: PixelFormat = .init(pixelFormat) else {
        return instance.fail("unsupported pixel format \(pixelFormat)")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }
    guard
    let source: YUVPlaneSet = .init(
        separate: UnsafeMutableRawPointer(mutating: srcPlanes)?
            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self),
        strides: strides,
        width: .init(width), height: .init(height), sampling: sampling
    )
    else {
        return instance.fail("source planes must not be NULL")
    }

    let stride: Int = pitch == 0 ? .init(width) * format.size : .init(pitch)
    guard stride >= .init(width) * format.size else {
        return instance.fail("pitch \(pitch) is smaller than one row")
    }

    do {
        // Upsampling and color conversion, the mirror of the encode path.
        let image: JPEG.Data.Rectangular<JPEG.Common> =
            try source.planar(width: .init(width), height: .init(height)).interleaved()

        for y: Int in 0 ..< Int(height) {
            let row: UnsafeMutablePointer<UInt8> = dstBuf + y * stride
            for x: Int in 0 ..< Int(width) {
                let pixel: UnsafeMutablePointer<UInt8> = row + x * format.size

                if format.isGray {
                    pixel[0] = .init(truncatingIfNeeded: image[x: x, y: y, 0])
                    continue
                }

                let color: JPEG.RGB = image.stride == 1
                    ? .init(.init(truncatingIfNeeded: image[x: x, y: y, 0]))
                    : JPEG.YCbCr(
                        y: .init(truncatingIfNeeded: image[x: x, y: y, 0]),
                        cb: .init(truncatingIfNeeded: image[x: x, y: y, 1]),
                        cr: .init(truncatingIfNeeded: image[x: x, y: y, 2])
                    ).rgb

                pixel[format.red] = color.r
                pixel[format.green] = color.g
                pixel[format.blue] = color.b
                if let alpha: Int = format.alpha {
                    pixel[alpha] = 0xFF
                }
            }
        }
        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tj3DecodeYUV8(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ align: Int32,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let srcBuf: UnsafePointer<UInt8> = srcBuf, isPowerOfTwo(.init(align)) else {
        return instance.fail("source must not be NULL and align must be a power of two")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }

    let set: YUVPlaneSet = .init(
        packed: .init(mutating: srcBuf), width: .init(width), height: .init(height),
        align: .init(align), sampling: sampling
    )
    return withPlanePointers(set) { planes, strides in
        tj3DecodeYUVPlanes8(
            handle,
            UnsafeRawPointer(planes).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
            strides, dstBuf, width, pitch, height, pixelFormat
        )
    }
}

// -- JPEG to YUV planes ------------------------------------------------------

@c @implementation
public func tj3DecompressToYUVPlanes8(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ dstPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ strides: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let jpegBuf: UnsafePointer<UInt8> = jpegBuf, jpegSize > 0 else {
        return instance.fail("JPEG buffer must not be NULL or empty")
    }

    do {
        // This is the operation the planar tier exists for: stop one step
        // above the interleaved image and hand back the component planes as
        // they were coded, with no upsampling and no color conversion.
        let planar: JPEG.Data.Planar<JPEG.Common> = try instance.decodePlanar(jpegBuf, jpegSize)
        let value: Int32 = Subsampling.value(of: planar.layout)
        guard let sampling: Subsampling = .init(value) else {
            return instance.fail("the image uses a subsampling TurboJPEG cannot name")
        }
        guard
        let destination: YUVPlaneSet = .init(
            separate: dstPlanes, strides: strides,
            width: planar.layout.width, height: planar.layout.height, sampling: sampling
        )
        else {
            return instance.fail("destination planes must not be NULL")
        }

        destination.fill(from: planar)
        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tj3DecompressToYUV8(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ align: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let dstBuf: UnsafeMutablePointer<UInt8> = dstBuf, isPowerOfTwo(.init(align)) else {
        return instance.fail("destination must not be NULL and align must be a power of two")
    }

    // The packed layout depends on the image's own dimensions and subsampling,
    // so the header has to be read before the planes can be located.
    let status: Int32 = tj3DecompressHeader(handle, jpegBuf, jpegSize)
    guard status == 0 else {
        return status
    }
    guard let sampling: Subsampling = .init(tj3Get(handle, TJPARAM_SUBSAMP.id)) else {
        return instance.fail("the image uses a subsampling TurboJPEG cannot name")
    }

    let set: YUVPlaneSet = .init(
        packed: dstBuf,
        width: .init(tj3Get(handle, TJPARAM_JPEGWIDTH.id)),
        height: .init(tj3Get(handle, TJPARAM_JPEGHEIGHT.id)),
        align: .init(align),
        sampling: sampling
    )
    return withPlanePointers(set) { planes, strides in
        tj3DecompressToYUVPlanes8(handle, jpegBuf, jpegSize, planes, strides)
    }
}

// -- YUV planes to JPEG ------------------------------------------------------

@c @implementation
public func tj3CompressFromYUVPlanes8(
    _ handle: tjhandle?,
    _ srcPlanes: UnsafePointer<UnsafePointer<UInt8>?>?,
    _ width: Int32,
    _ strides: UnsafePointer<Int32>?,
    _ height: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard width >= 1, height >= 1 else {
        return instance.fail("width and height must be positive")
    }
    guard let jpegSize: UnsafeMutablePointer<Int> = jpegSize,
          let jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = jpegBuf
    else {
        return instance.fail("destination buffer and size pointers must not be NULL")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }
    guard
    let source: YUVPlaneSet = .init(
        separate: UnsafeMutableRawPointer(mutating: srcPlanes)?
            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self),
        strides: strides,
        width: .init(width), height: .init(height), sampling: sampling
    )
    else {
        return instance.fail("source planes must not be NULL")
    }

    if instance.parameter(TJPARAM_PROGRESSIVE) != 0 {
        return instance.fail("progressive compression is not implemented")
    }

    do {
        // No color conversion and no subsampling: the caller has already done
        // both, which is the entire reason to enter here rather than through
        // tj3Compress8.
        let planar: JPEG.Data.Planar<JPEG.Common> =
            try source.planar(width: .init(width), height: .init(height))

        var encoded: [UInt8] = []
        try planar.compress(
            stream: &encoded,
            quality: .init(instance.parameter(TJPARAM_QUALITY, default: 95))
        )

        if instance.parameter(TJPARAM_NOREALLOC) != 0, let destination = jpegBuf.pointee {
            guard encoded.count <= jpegSize.pointee else {
                return instance.fail(
                    "buffer of \(jpegSize.pointee) bytes is too small for \(encoded.count)"
                )
            }
            destination.update(from: encoded, count: encoded.count)
        } else {
            guard let allocation: UnsafeMutableRawPointer = tj3Alloc(encoded.count) else {
                return instance.fail("could not allocate \(encoded.count) bytes")
            }
            let destination: UnsafeMutablePointer<UInt8> =
                allocation.bindMemory(to: UInt8.self, capacity: encoded.count)
            destination.update(from: encoded, count: encoded.count)
            jpegBuf.pointee = destination
        }

        jpegSize.pointee = encoded.count
        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tj3CompressFromYUV8(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ align: Int32,
    _ height: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let srcBuf: UnsafePointer<UInt8> = srcBuf, isPowerOfTwo(.init(align)) else {
        return instance.fail("source must not be NULL and align must be a power of two")
    }
    guard let sampling: Subsampling = subsampling(of: instance) else {
        return instance.fail("unsupported subsampling")
    }

    let set: YUVPlaneSet = .init(
        packed: .init(mutating: srcBuf), width: .init(width), height: .init(height),
        align: .init(align), sampling: sampling
    )
    return withPlanePointers(set) { planes, strides in
        tj3CompressFromYUVPlanes8(
            handle,
            UnsafeRawPointer(planes).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
            width, strides, height, jpegBuf, jpegSize
        )
    }
}

/// Exposes a plane set as the pointer-and-stride arrays the `Planes` entry
/// points take.
///
/// The packed forms are defined as the separate forms applied to a buffer they
/// carve up themselves, so expressing them that way keeps one implementation of
/// each conversion instead of two that can disagree about padding.
private func withPlanePointers(
    _ set: YUVPlaneSet,
    _ body: (
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        UnsafeMutablePointer<Int32>
    ) -> Int32
) -> Int32 {
    var pointers: [UnsafeMutablePointer<UInt8>?] = set.planes.map(\.base)
    var strides: [Int32] = set.planes.map { .init($0.stride) }
    return pointers.withUnsafeMutableBufferPointer { pointers in
        strides.withUnsafeMutableBufferPointer { strides in
            body(pointers.baseAddress!, strides.baseAddress!)
        }
    }
}
