import CTurboJPEG
import JPEG

@c @implementation
public func tj3JPEGBufSize(_ width: Int32, _ height: Int32, _ jpegSubsamp: Int32) -> Int {
    guard width >= 1, height >= 1, let sampling: Subsampling = .init(jpegSubsamp) else {
        return 0
    }

    // The worst case libjpeg-turbo computes, and it has to stay at least as
    // large: a caller that sets TJPARAM_NOREALLOC allocates exactly this much
    // and a smaller answer here becomes a buffer overrun there.
    //
    // An MCU is 8 samples per luma sampling factor. The chroma term is the
    // number of blocks per MCU beyond the luma ones, so it falls as
    // subsampling gets more aggressive and vanishes for grayscale.
    let mcu: (x: Int, y: Int) = (x: 8 * sampling.luma.x, y: 8 * sampling.luma.y)
    let chroma: Int = sampling.isGray ? 0 : 4 * 64 / (mcu.x * mcu.y)

    let padded: Int = pad(.init(width), to: mcu.x) * pad(.init(height), to: mcu.y)
    return padded * (2 + chroma / 2) + 2048
}

@c @implementation
public func tj3Compress8(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ jpegSize: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let srcBuf: UnsafePointer<UInt8> = srcBuf, let jpegSize: UnsafeMutablePointer<Int> = jpegSize
    else {
        return instance.fail("source buffer and size pointer must not be NULL")
    }
    guard let jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = jpegBuf else {
        return instance.fail("destination buffer pointer must not be NULL")
    }
    guard width >= 1, height >= 1 else {
        return instance.fail("width and height must be positive")
    }
    guard let format: PixelFormat = .init(pixelFormat) else {
        return instance.fail("unsupported pixel format \(pixelFormat)")
    }

    // A pitch of zero means the rows are contiguous. Anything else lets the
    // caller hand us a view into a larger image without copying it first.
    let stride: Int = pitch == 0 ? .init(width) * format.size : .init(pitch)
    guard stride >= .init(width) * format.size else {
        return instance.fail("pitch \(pitch) is smaller than one row")
    }


    let quality: Int32 = instance.parameter(TJPARAM_QUALITY, default: 95)
    let requested: Int32 = instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue)
    guard let sampling: Subsampling = .init(requested) else {
        return instance.fail("unsupported subsampling \(requested)")
    }

    // Grayscale output from color input is legitimate and common — it is how a
    // caller asks us to throw the chroma away.
    let gray: Bool = sampling.isGray || format.isGray
    // Lossless keeps the caller's channels exactly as given; any colour
    // transform would cost the exactness it exists to provide.
    let lossless: Bool = instance.parameter(TJPARAM_LOSSLESS) != 0

    do {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: gray
                ? .y(1, precision: 8)
                : .ycc(1, 2, 3, precision: 8),
            process: .baseline,
            width: .init(width),
            height: .init(height),
            sampling: gray
                ? [.init(x: 1, y: 1)]
                : [sampling.luma, .init(x: 1, y: 1), .init(x: 1, y: 1)],
            selectors: gray ? [0] : [0, 1, 1]
        )

        let planes: Int = gray ? 1 : 3
        var values: [UInt16] = .init(
            repeating: 0,
            count: .init(width) * .init(height) * planes
        )

        for y: Int in 0 ..< Int(height) {
            let row: UnsafePointer<UInt8> = srcBuf + y * stride
            for x: Int in 0 ..< Int(width) {
                let pixel: UnsafePointer<UInt8> = row + x * format.size
                let base: Int = (y * .init(width) + x) * planes
                if gray {
                    values[base] = format.isGray
                        ? .init(pixel[0])
                        : .init(JPEG.YCbCr(
                            .init(pixel[format.red], pixel[format.green], pixel[format.blue])
                        ).y)
                } else if lossless {
                    values[base] = .init(pixel[format.red])
                    values[base + 1] = .init(pixel[format.green])
                    values[base + 2] = .init(pixel[format.blue])
                } else {
                    let color: JPEG.YCbCr = .init(
                        .init(pixel[format.red], pixel[format.green], pixel[format.blue])
                    )
                    values[base] = .init(color.y)
                    values[base + 1] = .init(color.cb)
                    values[base + 2] = .init(color.cr)
                }
            }
        }

        let image: JPEG.Data.Rectangular<JPEG.Common> = .init(layout: layout, values: values)

        // Restart intervals are expressed either in MCU blocks or in MCU rows;
        // rows win when both are set, matching TurboJPEG.
        let rows: Int32 = instance.parameter(TJPARAM_RESTARTROWS)
        let blocks: Int32 = instance.parameter(TJPARAM_RESTARTBLOCKS)
        let mcus: (x: Int, y: Int) = layout.mcus
        let restartInterval: Int = rows > 0 ? .init(rows) * mcus.x : .init(blocks)

        var encoded: [UInt8] = []
        if instance.parameter(TJPARAM_LOSSLESS) != 0 {
            encoded = try instance.compressLossless(
                values: values, width: .init(width), height: .init(height),
                precision: 8, gray: gray
            )
        } else {
        try image.compress(
            stream: &encoded,
            quality: .init(quality),
            restartInterval: restartInterval,
            progressive: instance.parameter(TJPARAM_PROGRESSIVE) != 0,
            arithmetic: instance.parameter(TJPARAM_ARITHMETIC) != 0,
            metadata: instance.iccProfile.map(ICCProfile.segments(of:)) ?? []
        )
        }

        // With NOREALLOC the caller owns the buffer and it must not be
        // replaced; without it we allocate one they will free with tj3Free.
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
