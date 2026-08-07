import CTurboJPEG
import JPEG

extension Instance {
    /// Reads a JPEG's header and records what it said, without decoding it.
    ///
    /// Everything ``tj3DecompressHeader`` has to report comes out of the frame
    /// header: the geometry, the precision, the sampling factors, and the
    /// process. None of it needs the entropy coded data, which on a megapixel
    /// image is essentially the entire cost of a decode.
    ///
    /// This used to run a full decode and throw the image away, on the stated
    /// theory that decoding twice is what the API shape asks for. It is not.
    /// libjpeg-turbo's own `tj3DecompressHeader` reads markers and stops, and
    /// the documented calling pattern is header first, then decompress — so a
    /// caller who followed it paid for two decodes to get one image, which
    /// measured as 0.083 s where the engine needs 0.045 s.
    ///
    /// Reading the header no longer detects corruption in the scan data, and
    /// should not: libjpeg-turbo reports that from the decompress call, and a
    /// header call that failed on a file libjpeg-turbo accepts would be the
    /// worse divergence.
    func decodeHeader(
        _ jpegBuf: UnsafePointer<UInt8>,
        _ jpegSize: Int
    ) throws {
        let bytes: [UInt8] = .init(UnsafeBufferPointer(start: jpegBuf, count: jpegSize))

        var stream: JPEG.Bytestream.Cursor = .init(bytes)
        try stream.start()

        var found: JPEG.Header.Frame? = nil
        segments: while true {
            let (marker, data): (JPEG.Marker, [UInt8]) = try stream.segment()
            switch marker {
            case .frame(let process):
                found = try JPEG.Header.Frame.parse(data, process: process)
                break segments
            case .scan, .end:
                // A scan or an end of image before any frame header is a
                // malformed stream. There is nothing to report and nothing to
                // decode.
                throw Failure.message("no frame header before the first scan")
            default:
                continue
            }
        }
        guard let frame: JPEG.Header.Frame = found else {
            throw Failure.message("no frame header found")
        }

        // A height of zero means it arrives in a height redefinition after the
        // scan data, so the only way to learn it is to read the scan. Falling
        // back to the full decode is better than reporting zero, and rare
        // enough not to matter: it is what a streaming encoder emits.
        guard frame.height > 0 else {
            _ = try self.decode(jpegBuf, jpegSize)
            return
        }

        let layout: JPEG.Layout<JPEG.Common> = try .init(frame: frame)

        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(layout.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(layout.height)
        self.parameters[TJPARAM_PRECISION.id] = .init(layout.format.precision)
        self.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: layout)
        self.parameters[TJPARAM_PROGRESSIVE.id] = frame.process.isProgressive ? 1 : 0
        self.parameters[TJPARAM_ARITHMETIC.id] = frame.process.coding == .arithmetic ? 1 : 0

        // The lossless process reports a different colorspace for the same
        // component count, so the two branches have to match what the two decode
        // paths record or a caller sees one answer from the header call and
        // another from the decompress call.
        if case .lossless = frame.process {
            self.parameters[TJPARAM_LOSSLESS.id] = 1
            self.parameters[TJPARAM_COLORSPACE.id] = layout.planes.count == 1
                ? TJCS_GRAY.rawValue
                : TJCS_RGB.rawValue
        } else {
            self.parameters[TJPARAM_LOSSLESS.id] = 0
            self.parameters[TJPARAM_COLORSPACE.id] = layout.planes.count == 1
                ? TJCS_GRAY.rawValue
                : TJCS_YCbCr.rawValue
        }

        self.decodedProfile = try? ICCProfile.profile(in: bytes)
    }

    /// Decodes a JPEG and records what its header said.
    func decode(
        _ jpegBuf: UnsafePointer<UInt8>,
        _ jpegSize: Int
    ) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        let bytes: [UInt8] = .init(UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        // The lossless process shares the container and nothing else, so it is
        // detected from the frame marker and handled entirely separately.
        if case .lossless = try Instance.process(of: bytes) {
            return try self.decodeLossless(jpegBuf, jpegSize)
        }
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
        self.parameters[TJPARAM_ARITHMETIC.id] =
            spectral.layout.process.coding == .arithmetic ? 1 : 0

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
        self.parameters[TJPARAM_ARITHMETIC.id] =
            spectral.layout.process.coding == .arithmetic ? 1 : 0

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
        try instance.decodeHeader(jpegBuf, jpegSize)
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
        // An image stored as RGB needs no inverse transform; applying one would
        // corrupt it, and skipping it is what keeps a lossless decode exact.
        let direct: Bool
        if case .rgb = image.layout.format {
            direct = true
        } else {
            direct = false
        }

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

                    let color: JPEG.RGB
                    if planes == 1 {
                        color = .init(.init(truncatingIfNeeded: samples[source]))
                    } else if direct {
                        color = .init(
                            .init(truncatingIfNeeded: samples[source]),
                            .init(truncatingIfNeeded: samples[source + 1]),
                            .init(truncatingIfNeeded: samples[source + 2])
                        )
                    } else {
                        color = JPEG.YCbCr(
                            y: .init(truncatingIfNeeded: samples[source]),
                            cb: .init(truncatingIfNeeded: samples[source + 1]),
                            cr: .init(truncatingIfNeeded: samples[source + 2])
                        ).rgb
                    }

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
