import CTurboJPEG
import JPEG

extension JPEG.Transform {
    /// Translates a `TJXOP` value.
    init?(operation: Int32) {
        switch operation {
        case TJXOP_NONE.id:       self = .none
        case TJXOP_HFLIP.id:      self = .horizontalFlip
        case TJXOP_VFLIP.id:      self = .verticalFlip
        case TJXOP_TRANSPOSE.id:  self = .transpose
        case TJXOP_TRANSVERSE.id: self = .transverse
        case TJXOP_ROT90.id:      self = .rotate90
        case TJXOP_ROT180.id:     self = .rotate180
        case TJXOP_ROT270.id:     self = .rotate270
        default:                        return nil
        }
    }
}

@c @implementation
public func tj3TransformBufSize(
    _ handle: tjhandle?,
    _ transform: UnsafePointer<tjtransform>?
) -> Int {
    guard let instance: Instance = Instance.borrow(handle) else {
        return 0
    }

    // Sized from whatever the last header read reported, since a transform
    // operates on the image already identified rather than on one supplied
    // here.
    let width: Int32 = instance.parameter(TJPARAM_JPEGWIDTH, default: 0)
    let height: Int32 = instance.parameter(TJPARAM_JPEGHEIGHT, default: 0)
    guard width > 0, height > 0 else {
        return 0
    }

    let operation: Int32 = transform?.pointee.op ?? TJXOP_NONE.id
    let options: Int32 = transform?.pointee.options ?? 0
    guard let rotation: JPEG.Transform = .init(operation: operation) else {
        return 0
    }

    let subsamp: Int32 = options & TJXOPT_GRAY != 0
        ? TJSAMP_GRAY.rawValue
        : instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue)

    // A quarter turn exchanges the dimensions, and with them the worst case.
    return rotation.swapsAxes
        ? tj3JPEGBufSize(height, width, subsamp)
        : tj3JPEGBufSize(width, height, subsamp)
}

@c @implementation
public func tj3Transform(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ n: Int32,
    _ dstBufs: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ dstSizes: UnsafeMutablePointer<Int>?,
    _ transforms: UnsafePointer<tjtransform>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let jpegBuf: UnsafePointer<UInt8> = jpegBuf, jpegSize > 0 else {
        return instance.fail("JPEG buffer must not be NULL or empty")
    }
    guard n >= 1, let transforms: UnsafePointer<tjtransform> = transforms else {
        return instance.fail("at least one transform must be supplied")
    }
    guard let dstBufs: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = dstBufs,
          let dstSizes: UnsafeMutablePointer<Int> = dstSizes
    else {
        return instance.fail("destination buffer and size arrays must not be NULL")
    }

    do {
        // Decoded once and reused: every output transforms the same
        // coefficients, and re-reading the source per transform would be the
        // expensive half of the work repeated.
        let source: JPEG.Data.Spectral<JPEG.Common> = try .decompress(
            [UInt8](UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        )

        instance.parameters[TJPARAM_JPEGWIDTH.id] = .init(source.layout.width)
        instance.parameters[TJPARAM_JPEGHEIGHT.id] = .init(source.layout.height)
        instance.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: source.layout)

        for index: Int in 0 ..< Int(n) {
            let transform: tjtransform = transforms[index]

            guard let rotation: JPEG.Transform = .init(operation: transform.op) else {
                return instance.fail("unknown transform operation \(transform.op)")
            }
            if transform.options & TJXOPT_CROP != 0 {
                return instance.fail("cropping is not implemented")
            }
            if transform.customFilter != nil {
                return instance.fail("custom coefficient filters are not implemented")
            }
            if transform.options & TJXOPT_GRAY != 0 {
                return instance.fail("discarding chrominance is not implemented")
            }
            if transform.options & TJXOPT_PROGRESSIVE != 0 {
                return instance.fail("progressive output is not implemented")
            }
            // PERFECT asks us to refuse rather than lose the partial edge. That
            // is the whole point of the option, so it is honored exactly.
            if transform.options & TJXOPT_PERFECT != 0, !source.isPerfect(for: rotation) {
                return instance.fail(
                    "transform is not perfect: the image is not a whole number of MCUs"
                )
            }
            if transform.options & TJXOPT_NOOUTPUT != 0 {
                dstSizes[index] = 0
                continue
            }

            let transformed: JPEG.Data.Spectral<JPEG.Common> = source.transformed(rotation)

            // The tables come from the transformed image, not from a fresh set:
            // its coefficients were never dequantized, so they are only
            // meaningful against the quantization tables that travelled with
            // them.
            var tables: JPEG.Tables = .init()
            tables.push(try .standard(.luminance, class: .dc, target: 0))
            tables.push(try .standard(.luminance, class: .ac, target: 0))
            if transformed.layout.planes.count > 1 {
                tables.push(try .standard(.chrominance, class: .dc, target: 1))
                tables.push(try .standard(.chrominance, class: .ac, target: 1))
            }

            var encoded: [UInt8] = []
            try transformed.compress(stream: &encoded, tables: tables)

            if instance.parameter(TJPARAM_NOREALLOC) != 0, let destination = dstBufs[index] {
                guard encoded.count <= dstSizes[index] else {
                    return instance.fail(
                        "buffer \(index) holds \(dstSizes[index]) bytes, needs \(encoded.count)"
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
                dstBufs[index] = destination
            }
            dstSizes[index] = encoded.count
        }

        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tjTransform(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: UInt,
    _ n: Int32,
    _ dstBufs: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ dstSizes: UnsafeMutablePointer<UInt>?,
    _ transforms: UnsafeMutablePointer<tjtransform>?,
    _ flags: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    guard let dstSizes: UnsafeMutablePointer<UInt> = dstSizes else {
        return instance.fail("size array must not be NULL")
    }
    instance.parameters[TJPARAM_NOREALLOC.id] = flags & TJFLAG_NOREALLOC != 0 ? 1 : 0

    var sizes: [Int] = (0 ..< Int(n)).map { .init(dstSizes[$0]) }
    let status: Int32 = sizes.withUnsafeMutableBufferPointer {
        tj3Transform(handle, jpegBuf, .init(jpegSize), n, dstBufs, $0.baseAddress, transforms)
    }
    for index: Int in 0 ..< Int(n) {
        dstSizes[index] = .init(sizes[index])
    }
    return status
}
