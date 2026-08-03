import CTurboJPEG
import JPEG

extension Instance {
    /// Decodes a JPEG and records what its header said.
    ///
    /// Shared by the header call and the decompress call. TurboJPEG requires
    /// the header to be read first so the caller can size their output buffer,
    /// and then hands the same bytes back — so decoding twice is what the API
    /// shape asks for, not an oversight.
    func decode(
        _ jpegBuf: UnsafePointer<UInt8>,
        _ jpegSize: Int
    ) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        var stream: [UInt8] = .init(UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(image.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(image.height)
        self.parameters[TJPARAM_PRECISION.id] = .init(image.layout.format.precision)
        self.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: image.layout)
        self.parameters[TJPARAM_COLORSPACE.id] = image.stride == 1
            ? TJCS_GRAY.rawValue
            : TJCS_YCbCr.rawValue
        self.parameters[TJPARAM_PROGRESSIVE.id] = image.layout.process.isProgressive ? 1 : 0
        self.parameters[TJPARAM_LOSSLESS.id] = 0

        return image
    }
}

@c @implementation
public func tj3DecompressHeader(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let jpegBuf: UnsafePointer<UInt8> = jpegBuf, jpegSize > 0 else {
        return instance.fail("JPEG buffer must not be NULL or empty")
    }

    do {
        _ = try instance.decode(jpegBuf, jpegSize)
        return 0
    } catch {
        return instance.fail(error)
    }
}

@c @implementation
public func tj3Decompress8(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ dstBuf: UnsafeMutablePointer<UInt8>?,
    _ pitch: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let jpegBuf: UnsafePointer<UInt8> = jpegBuf, jpegSize > 0 else {
        return instance.fail("JPEG buffer must not be NULL or empty")
    }
    guard let dstBuf: UnsafeMutablePointer<UInt8> = dstBuf else {
        return instance.fail("destination buffer must not be NULL")
    }
    guard let format: PixelFormat = .init(pixelFormat) else {
        return instance.fail("unsupported pixel format \(pixelFormat)")
    }

    do {
        let image: JPEG.Data.Rectangular<JPEG.Common> = try instance.decode(jpegBuf, jpegSize)

        let stride: Int = pitch == 0 ? image.width * format.size : .init(pitch)
        guard stride >= image.width * format.size else {
            return instance.fail("pitch \(pitch) is smaller than one row")
        }

        // Rows are written bottom-up when the caller asks for it, which is what
        // a Windows bitmap wants and is why the option exists at all.
        let flip: Bool = instance.parameter(TJPARAM_BOTTOMUP) != 0

        for y: Int in 0 ..< image.height {
            let row: UnsafeMutablePointer<UInt8> =
                dstBuf + (flip ? image.height - 1 - y : y) * stride

            for x: Int in 0 ..< image.width {
                let pixel: UnsafeMutablePointer<UInt8> = row + x * format.size

                if format.isGray {
                    // Taking the luminance plane is exact for a grayscale JPEG
                    // and is the correct answer for a color one too, since Y is
                    // already the luma the caller is asking for.
                    pixel[0] = .init(truncatingIfNeeded: image[x: x, y: y, 0])
                    continue
                }

                let color: JPEG.RGB
                if image.stride == 1 {
                    color = .init(.init(truncatingIfNeeded: image[x: x, y: y, 0]))
                } else {
                    color = JPEG.YCbCr(
                        y: .init(truncatingIfNeeded: image[x: x, y: y, 0]),
                        cb: .init(truncatingIfNeeded: image[x: x, y: y, 1]),
                        cr: .init(truncatingIfNeeded: image[x: x, y: y, 2])
                    ).rgb
                }

                pixel[format.red] = color.r
                pixel[format.green] = color.g
                pixel[format.blue] = color.b
                // Only a real alpha channel is written. The X formats have a
                // padding byte in the same position that must be left alone.
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
