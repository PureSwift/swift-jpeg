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
        let bytes: [UInt8] = .init(UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        self.decodedProfile = try? ICCProfile.profile(in: bytes)

        let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(bytes)

        // The scaling factor is applied by transforming fewer coefficients per
        // block rather than by resampling afterwards, which is the whole reason
        // a decoder offers scaling at all.
        let image: JPEG.Data.Rectangular<JPEG.Common> = spectral.rectangular(
            scale: 8 * self.scalingFactor.numerator / self.scalingFactor.denominator
        )

        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(image.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(image.height)
        self.parameters[TJPARAM_PRECISION.id] = .init(image.layout.format.precision)
        self.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: image.layout)
        self.parameters[TJPARAM_COLORSPACE.id] = image.stride == 1
            ? TJCS_GRAY.rawValue
            : TJCS_YCbCr.rawValue
        self.parameters[TJPARAM_PROGRESSIVE.id] = image.layout.process.isProgressive ? 1 : 0
        self.parameters[TJPARAM_LOSSLESS.id] = 0

        // The reported dimensions are the JPEG's own, not the scaled output's:
        // a caller computes the latter with TJSCALED. Recorded before cropping
        // for the same reason.
        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(spectral.layout.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(spectral.layout.height)

        return try self.cropped(image)
    }

    /// Applies the cropping region, if one is set.
    ///
    /// Cropped after decoding rather than during it. libjpeg can skip whole
    /// MCU rows above the region, which is faster; doing it here is correct at
    /// every offset instead of only block-aligned ones, and the difference does
    /// not show in the result.
    func cropped(
        _ image: JPEG.Data.Rectangular<JPEG.Common>
    ) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        guard let region: (x: Int, y: Int, width: Int, height: Int) = self.croppingRegion else {
            return image
        }
        guard
        let cropped: JPEG.Data.Rectangular<JPEG.Common> = image.cropped(to: region)
        else {
            throw Failure.message(
                "cropping region \(region.width)x\(region.height)+\(region.x)+\(region.y) "
                    + "does not fit in the \(image.width)x\(image.height) image"
            )
        }
        return cropped
    }

    /// Decodes a JPEG to component planes, stopping one tier above the
    /// interleaved image.
    ///
    /// Shares the header bookkeeping with ``decode(_:_:)`` so the two report
    /// the same geometry.
    func decodePlanar(
        _ jpegBuf: UnsafePointer<UInt8>,
        _ jpegSize: Int
    ) throws -> JPEG.Data.Planar<JPEG.Common> {
        let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(
            [UInt8](UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        )

        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(spectral.layout.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(spectral.layout.height)
        self.parameters[TJPARAM_PRECISION.id] = .init(spectral.layout.format.precision)
        self.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: spectral.layout)
        self.parameters[TJPARAM_COLORSPACE.id] = spectral.layout.planes.count == 1
            ? TJCS_GRAY.rawValue
            : TJCS_YCbCr.rawValue
        self.parameters[TJPARAM_PROGRESSIVE.id] =
            spectral.layout.process.isProgressive ? 1 : 0
        self.parameters[TJPARAM_LOSSLESS.id] = 0

        return spectral.decomposed()
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
        let planes: Int = image.stride
        let width: Int = image.width

        // Reading through the image's subscript costs a bounds check and an
        // index computation per component, a million times over on a megapixel
        // image. Taking the buffer once and walking it linearly is the
        // difference between this loop dominating the decode and disappearing
        // into it.
        image.values.withUnsafeBufferPointer { samples in
            for y: Int in 0 ..< image.height {
                let row: UnsafeMutablePointer<UInt8> =
                    dstBuf + (flip ? image.height - 1 - y : y) * stride
                var source: Int = y * width * planes

                for x: Int in 0 ..< width {
                    let pixel: UnsafeMutablePointer<UInt8> = row + x * format.size
                    defer {
                        source += planes
                    }

                    if format.isGray {
                        // Taking the luminance plane is exact for a grayscale
                        // JPEG and is the right answer for a color one too,
                        // since Y is already the luma being asked for.
                        pixel[0] = .init(truncatingIfNeeded: samples[source])
                        continue
                    }

                    let color: JPEG.RGB = planes == 1
                        ? .init(.init(truncatingIfNeeded: samples[source]))
                        : JPEG.YCbCr(
                            y: .init(truncatingIfNeeded: samples[source]),
                            cb: .init(truncatingIfNeeded: samples[source + 1]),
                            cr: .init(truncatingIfNeeded: samples[source + 2])
                        ).rgb

                    pixel[format.red] = color.r
                    pixel[format.green] = color.g
                    pixel[format.blue] = color.b
                    // Only a real alpha channel is written. The X formats have
                    // a padding byte in the same position that must be left
                    // alone.
                    if let alpha: Int = format.alpha {
                        pixel[alpha] = 0xFF
                    }
                }
            }
        }

        return 0
    } catch {
        return instance.fail(error)
    }
}
