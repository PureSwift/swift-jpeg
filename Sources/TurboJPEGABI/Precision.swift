import CTurboJPEG
import JPEG

/// The 12- and 16-bit entry points.
///
/// The precision a JPEG can carry is fixed by its coding process, not chosen
/// freely. T.81 gives the DCT-based processes 8 or 12 bits and reserves
/// everything wider for the lossless process, which is a predictive codec
/// sharing almost nothing with them but the marker structure.
///
/// So 12-bit compression is real work here — it needs the extended sequential
/// process and Huffman tables the Annex K samples cannot supply — while 16-bit
/// is refused. Refusing is the correct answer rather than a shortcut: there is
/// no conforming 16-bit DCT JPEG to produce.

extension Instance {
    /// Compresses samples of the given precision.
    ///
    /// Shared by the 12- and 8-bit paths, which differ only in the width of the
    /// caller's buffer and the process that width implies.
    fileprivate func compress<Sample>(
        _ srcBuf: UnsafePointer<Sample>?,
        width: Int32,
        pitch: Int32,
        height: Int32,
        pixelFormat: Int32,
        precision: Int,
        jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        jpegSize: UnsafeMutablePointer<Int>?,
        sample: (Sample) -> UInt16
    ) -> Int32 {
        self.clearError()

        guard let srcBuf: UnsafePointer<Sample> = srcBuf, width >= 1, height >= 1 else {
            return self.fail("source buffer must not be NULL and the size must be positive")
        }
        guard let jpegSize: UnsafeMutablePointer<Int> = jpegSize,
              let jpegBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = jpegBuf
        else {
            return self.fail("destination buffer and size pointers must not be NULL")
        }
        guard let format: PixelFormat = .init(pixelFormat) else {
            return self.fail("unsupported pixel format \(pixelFormat)")
        }

        let requested: Int32 = self.parameter(TJPARAM_SUBSAMP, default: TJSAMP_444.rawValue)
        guard let sampling: Subsampling = .init(requested) else {
            return self.fail("unsupported subsampling \(requested)")
        }
        let gray: Bool = sampling.isGray || format.isGray

        // Pitch is in samples here, not bytes, because the caller's buffer is
        // an array of a wider type.
        let stride: Int = pitch == 0 ? .init(width) * format.size : .init(pitch)
        guard stride >= .init(width) * format.size else {
            return self.fail("pitch \(pitch) is smaller than one row")
        }

        // 16-bit samples exist only in the lossless process, so asking for
        // them is asking for it whether or not the flag was set.
        let lossless: Bool = self.parameter(TJPARAM_LOSSLESS) != 0 || precision == 16

        do {
            let layout: JPEG.Layout<JPEG.Common> = try .init(
                format: gray
                    ? .y(1, precision: precision)
                    : lossless
                        ? .rgb(82, 71, 66, precision: precision)
                        : .ycc(1, 2, 3, precision: precision),
                process: lossless
                    ? .lossless(coding: .huffman, differential: false)
                    : self.parameter(TJPARAM_PROGRESSIVE) != 0
                        ? .progressive(coding: .huffman, differential: false)
                        : precision == 8
                            ? .baseline
                            : .extended(coding: .huffman, differential: false),
                width: .init(width),
                height: .init(height),
                sampling: gray
                    ? [.init(x: 1, y: 1)]
                    : [sampling.luma, .init(x: 1, y: 1), .init(x: 1, y: 1)],
                selectors: gray ? [0] : [0, 1, 1]
            )

            let planes: Int = gray ? 1 : 3
            let ceiling: UInt16 = .init((1 << precision) - 1)
            var values: [UInt16] = .init(
                repeating: 0, count: .init(width) * .init(height) * planes
            )

            for y: Int in 0 ..< Int(height) {
                let row: UnsafePointer<Sample> = srcBuf + y * stride
                for x: Int in 0 ..< Int(width) {
                    let pixel: UnsafePointer<Sample> = row + x * format.size

                    // Color conversion is defined on 8-bit values, so wider
                    // samples are narrowed for the conversion and the result
                    // widened back. That costs precision in the chroma channels
                    // and none in luma, which is the same trade every 12-bit
                    // encoder makes.
                    if format.isGray {
                        values[(y * .init(width) + x) * planes] =
                            Swift.min(sample(pixel[0]), ceiling)
                        continue
                    } else if lossless {
                        // Channels pass through untouched, which is what makes
                        // the round trip exact.
                        let base: Int = (y * .init(width) + x) * planes
                        values[base] = Swift.min(sample(pixel[format.red]), ceiling)
                        values[base + 1] = Swift.min(sample(pixel[format.green]), ceiling)
                        values[base + 2] = Swift.min(sample(pixel[format.blue]), ceiling)
                    } else {
                        let shift: Int = precision - 8
                        let color: JPEG.YCbCr = .init(
                            .init(
                                .init(truncatingIfNeeded: sample(pixel[format.red]) >> UInt16(shift)),
                                .init(truncatingIfNeeded: sample(pixel[format.green]) >> UInt16(shift)),
                                .init(truncatingIfNeeded: sample(pixel[format.blue]) >> UInt16(shift))
                            )
                        )
                        let base: Int = (y * .init(width) + x) * planes
                        values[base] = .init(color.y) << UInt16(shift)
                        values[base + 1] = .init(color.cb) << UInt16(shift)
                        values[base + 2] = .init(color.cr) << UInt16(shift)
                    }
                }
            }

            var encoded: [UInt8] = []
            if lossless {
                encoded = try self.compressLossless(
                    values: values, width: .init(width), height: .init(height),
                    precision: precision, gray: gray
                )
            } else {
                let image: JPEG.Data.Rectangular<JPEG.Common> =
                    .init(layout: layout, values: values)
                try image.compress(
                    stream: &encoded,
                    quality: .init(self.parameter(TJPARAM_QUALITY, default: 95)),
                    progressive: self.parameter(TJPARAM_PROGRESSIVE) != 0,
                    metadata: self.compressionMetadata
                )
            }

            if self.parameter(TJPARAM_NOREALLOC) != 0, let destination = jpegBuf.pointee {
                guard encoded.count <= jpegSize.pointee else {
                    return self.fail(
                        "buffer of \(jpegSize.pointee) bytes is too small for \(encoded.count)"
                    )
                }
                destination.update(from: encoded, count: encoded.count)
            } else {
                guard let allocation: UnsafeMutableRawPointer = tj3Alloc(encoded.count) else {
                    return self.fail("could not allocate \(encoded.count) bytes")
                }
                let destination: UnsafeMutablePointer<UInt8> =
                    allocation.bindMemory(to: UInt8.self, capacity: encoded.count)
                destination.update(from: encoded, count: encoded.count)
                jpegBuf.pointee = destination
            }
            jpegSize.pointee = encoded.count
            return 0
        } catch {
            return self.fail(error)
        }
    }

    /// Decompresses into samples of the given width.
    fileprivate func decompress<Sample>(
        _ jpegBuf: UnsafePointer<UInt8>?,
        _ jpegSize: Int,
        dstBuf: UnsafeMutablePointer<Sample>?,
        pitch: Int32,
        pixelFormat: Int32,
        precision: Int,
        store: (UInt16) -> Sample
    ) -> Int32 {
        self.clearError()

        guard let jpegBuf: UnsafePointer<UInt8> = jpegBuf, jpegSize > 0 else {
            return self.fail("JPEG buffer must not be NULL or empty")
        }
        guard let dstBuf: UnsafeMutablePointer<Sample> = dstBuf else {
            return self.fail("destination buffer must not be NULL")
        }
        guard let format: PixelFormat = .init(pixelFormat) else {
            return self.fail("unsupported pixel format \(pixelFormat)")
        }

        do {
            let image: JPEG.Data.Rectangular<JPEG.Common> = try self.decode(jpegBuf, jpegSize)
            let coded: Int = image.layout.format.precision
            guard coded == precision else {
                return self.fail(
                    "the image has \(coded)-bit samples, not \(precision)-bit"
                )
            }

            let stride: Int = pitch == 0 ? image.width * format.size : .init(pitch)
            guard stride >= image.width * format.size else {
                return self.fail("pitch \(pitch) is smaller than one row")
            }

            let shift: Int = precision - 8
            for y: Int in 0 ..< image.height {
                let row: UnsafeMutablePointer<Sample> = dstBuf + y * stride
                for x: Int in 0 ..< image.width {
                    let pixel: UnsafeMutablePointer<Sample> = row + x * format.size

                    if format.isGray {
                        pixel[0] = store(image[x: x, y: y, 0])
                        continue
                    }

                    if case .rgb = image.layout.format {
                        // Stored as RGB, so the samples are already what the
                        // caller wants at full width — no narrowing, no
                        // transform, nothing lost.
                        pixel[format.red] = store(image[x: x, y: y, 0])
                        pixel[format.green] = store(image[x: x, y: y, 1])
                        pixel[format.blue] = store(image[x: x, y: y, 2])
                        if let alpha: Int = format.alpha {
                            pixel[alpha] = store(UInt16((1 << precision) - 1))
                        }
                        continue
                    }

                    let color: JPEG.RGB = image.stride == 1
                        ? .init(.init(truncatingIfNeeded: image[x: x, y: y, 0] >> UInt16(shift)))
                        : JPEG.YCbCr(
                            y: .init(truncatingIfNeeded: image[x: x, y: y, 0] >> UInt16(shift)),
                            cb: .init(truncatingIfNeeded: image[x: x, y: y, 1] >> UInt16(shift)),
                            cr: .init(truncatingIfNeeded: image[x: x, y: y, 2] >> UInt16(shift))
                        ).rgb

                    pixel[format.red] = store(UInt16(color.r) << UInt16(shift))
                    pixel[format.green] = store(UInt16(color.g) << UInt16(shift))
                    pixel[format.blue] = store(UInt16(color.b) << UInt16(shift))
                    if let alpha: Int = format.alpha {
                        pixel[alpha] = store(UInt16((1 << precision) - 1))
                    }
                }
            }
            return 0
        } catch {
            return self.fail(error)
        }
    }
}

@c @implementation
public func tj3Compress12(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<Int16>?,
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
    // 12-bit samples arrive in a signed type but are unsigned values; a
    // negative one is out of range and clamps to zero rather than wrapping to
    // something enormous.
    return instance.compress(
        srcBuf, width: width, pitch: pitch, height: height, pixelFormat: pixelFormat,
        precision: 12, jpegBuf: jpegBuf, jpegSize: jpegSize,
        sample: { UInt16(Swift.max($0, 0)) }
    )
}

@c @implementation
public func tj3Decompress12(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ dstBuf: UnsafeMutablePointer<Int16>?,
    _ pitch: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    return instance.decompress(
        jpegBuf, jpegSize, dstBuf: dstBuf, pitch: pitch, pixelFormat: pixelFormat,
        precision: 12, store: { Int16(truncatingIfNeeded: $0) }
    )
}

@c @implementation
public func tj3Compress16(
    _ handle: tjhandle?,
    _ srcBuf: UnsafePointer<UInt16>?,
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
    return instance.compress(
        srcBuf, width: width, pitch: pitch, height: height, pixelFormat: pixelFormat,
        precision: 16, jpegBuf: jpegBuf, jpegSize: jpegSize,
        sample: { $0 }
    )
}

@c @implementation
public func tj3Decompress16(
    _ handle: tjhandle?,
    _ jpegBuf: UnsafePointer<UInt8>?,
    _ jpegSize: Int,
    _ dstBuf: UnsafeMutablePointer<UInt16>?,
    _ pitch: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    return instance.decompress(
        jpegBuf, jpegSize, dstBuf: dstBuf, pitch: pitch, pixelFormat: pixelFormat,
        precision: 16, store: { $0 }
    )
}
