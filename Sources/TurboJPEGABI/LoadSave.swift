import CTurboJPEG

/// The image loading and saving entry points.
///
/// These are a convenience the API offers so a caller need not carry a second
/// image library to get pixels in and out. They touch the filesystem, which is
/// why they live here and not in the engine — the engine reads and writes
/// through protocols precisely so it never has to know what a file is.

extension Instance {
    /// Loads a file and converts it to the requested packed pixel format.
    ///
    /// -   Parameter pixelFormat:
    ///     In and out. `TJPF_UNKNOWN` asks the file to choose, and the choice
    ///     is written back.
    fileprivate func load<Sample>(
        path: UnsafePointer<CChar>?,
        width: UnsafeMutablePointer<Int32>?,
        align: Int32,
        height: UnsafeMutablePointer<Int32>?,
        pixelFormat: UnsafeMutablePointer<Int32>?,
        precision: Int,
        store: (UInt16) -> Sample
    ) -> UnsafeMutablePointer<Sample>? {
        self.clearError()

        guard let path: UnsafePointer<CChar> = path,
              let width: UnsafeMutablePointer<Int32> = width,
              let height: UnsafeMutablePointer<Int32> = height,
              let pixelFormat: UnsafeMutablePointer<Int32> = pixelFormat
        else {
            self.fail("filename and the size and format pointers must not be NULL")
            return nil
        }
        guard isPowerOfTwo(.init(align)) else {
            self.fail("align must be a power of two")
            return nil
        }

        let image: ImageFile.Raw
        do {
            image = try ImageFile.load(path: String(cString: path))
        } catch {
            self.fail("\(error)")
            return nil
        }

        // A file with one channel loads as grayscale unless the caller insists
        // otherwise, which matches what the format itself says about the data.
        var requested: Int32 = pixelFormat.pointee
        if requested == TJPF_UNKNOWN.rawValue {
            requested = image.channels == 1 ? TJPF_GRAY.rawValue : TJPF_RGB.rawValue
        }
        guard let format: PixelFormat = .init(requested) else {
            self.fail("unsupported pixel format \(requested)")
            return nil
        }

        // The file's own maximum value fixes its precision; rescaling to the
        // requested one is a shift, not a stretch, so a 255-max file loaded at
        // 12 bits becomes 0 ... 4080 rather than 0 ... 4095.
        let from: Int = image.maxValue > 255 ? 16 : 8
        let shift: Int = precision - from

        let stride: Int = pad(image.width * format.size, to: .init(align))
        let count: Int = stride * image.height
        guard
        let allocation: UnsafeMutableRawPointer = tj3Alloc(count * MemoryLayout<Sample>.size)
        else {
            self.fail("could not allocate \(count) samples")
            return nil
        }
        let buffer: UnsafeMutablePointer<Sample> =
            allocation.bindMemory(to: Sample.self, capacity: count)

        func rescale(_ value: UInt16) -> UInt16 {
            if shift > 0 {
                return value << UInt16(shift)
            } else if shift < 0 {
                return value >> UInt16(-shift)
            } else {
                return value
            }
        }

        for y: Int in 0 ..< image.height {
            let row: UnsafeMutablePointer<Sample> = buffer + y * stride
            for x: Int in 0 ..< image.width {
                let base: Int = (y * image.width + x) * image.channels
                let pixel: UnsafeMutablePointer<Sample> = row + x * format.size

                let r: UInt16 = rescale(image.samples[base])
                let g: UInt16 = rescale(image.samples[image.channels == 1 ? base : base + 1])
                let b: UInt16 = rescale(image.samples[image.channels == 1 ? base : base + 2])

                if format.isGray {
                    pixel[0] = store(r)
                    continue
                }
                pixel[format.red] = store(r)
                pixel[format.green] = store(g)
                pixel[format.blue] = store(b)
                if let alpha: Int = format.alpha {
                    pixel[alpha] = store(.init((1 << precision) - 1))
                }
            }
        }

        width.pointee = .init(image.width)
        height.pointee = .init(image.height)
        pixelFormat.pointee = requested
        return buffer
    }

    /// Converts packed pixels and writes them to a file.
    fileprivate func save<Sample>(
        path: UnsafePointer<CChar>?,
        buffer: UnsafePointer<Sample>?,
        width: Int32,
        pitch: Int32,
        height: Int32,
        pixelFormat: Int32,
        precision: Int,
        sample: (Sample) -> UInt16
    ) -> Int32 {
        self.clearError()

        guard let path: UnsafePointer<CChar> = path, let buffer: UnsafePointer<Sample> = buffer
        else {
            return self.fail("filename and buffer must not be NULL")
        }
        guard width >= 1, height >= 1 else {
            return self.fail("width and height must be positive")
        }
        guard let format: PixelFormat = .init(pixelFormat) else {
            return self.fail("unsupported pixel format \(pixelFormat)")
        }

        let stride: Int = pitch == 0 ? .init(width) * format.size : .init(pitch)
        let channels: Int = format.isGray ? 1 : 3
        var samples: [UInt16] = .init(
            repeating: 0, count: .init(width) * .init(height) * channels
        )

        for y: Int in 0 ..< Int(height) {
            let row: UnsafePointer<Sample> = buffer + y * stride
            for x: Int in 0 ..< Int(width) {
                let pixel: UnsafePointer<Sample> = row + x * format.size
                let base: Int = (y * .init(width) + x) * channels
                if format.isGray {
                    samples[base] = sample(pixel[0])
                } else {
                    samples[base] = sample(pixel[format.red])
                    samples[base + 1] = sample(pixel[format.green])
                    samples[base + 2] = sample(pixel[format.blue])
                }
            }
        }

        do {
            try ImageFile.save(
                path: String(cString: path),
                image: .init(
                    width: .init(width),
                    height: .init(height),
                    channels: channels,
                    maxValue: (1 << precision) - 1,
                    samples: samples
                )
            )
            return 0
        } catch {
            return self.fail("\(error)")
        }
    }
}

@c @implementation
public func tj3LoadImage8(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ width: UnsafeMutablePointer<Int32>?,
    _ align: Int32,
    _ height: UnsafeMutablePointer<Int32>?,
    _ pixelFormat: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
    Instance.borrow(handle)?.load(
        path: filename, width: width, align: align, height: height,
        pixelFormat: pixelFormat, precision: 8,
        store: { UInt8(truncatingIfNeeded: $0) }
    )
}

@c @implementation
public func tj3LoadImage12(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ width: UnsafeMutablePointer<Int32>?,
    _ align: Int32,
    _ height: UnsafeMutablePointer<Int32>?,
    _ pixelFormat: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<Int16>? {
    Instance.borrow(handle)?.load(
        path: filename, width: width, align: align, height: height,
        pixelFormat: pixelFormat, precision: 12,
        store: { Int16(truncatingIfNeeded: $0) }
    )
}

@c @implementation
public func tj3LoadImage16(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ width: UnsafeMutablePointer<Int32>?,
    _ align: Int32,
    _ height: UnsafeMutablePointer<Int32>?,
    _ pixelFormat: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt16>? {
    // Loading 16-bit samples is fine even though compressing them is not: a
    // PGM or PPM carries them, and the caller may want them for something
    // other than a JPEG.
    Instance.borrow(handle)?.load(
        path: filename, width: width, align: align, height: height,
        pixelFormat: pixelFormat, precision: 16,
        store: { $0 }
    )
}

@c @implementation
public func tj3SaveImage8(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ buffer: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    return instance.save(
        path: filename, buffer: buffer, width: width, pitch: pitch, height: height,
        pixelFormat: pixelFormat, precision: 8, sample: { UInt16($0) }
    )
}

@c @implementation
public func tj3SaveImage12(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ buffer: UnsafePointer<Int16>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    return instance.save(
        path: filename, buffer: buffer, width: width, pitch: pitch, height: height,
        pixelFormat: pixelFormat, precision: 12,
        sample: { UInt16(Swift.max($0, 0)) }
    )
}

@c @implementation
public func tj3SaveImage16(
    _ handle: tjhandle?,
    _ filename: UnsafePointer<CChar>?,
    _ buffer: UnsafePointer<UInt16>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    return instance.save(
        path: filename, buffer: buffer, width: width, pitch: pitch, height: height,
        pixelFormat: pixelFormat, precision: 16, sample: { $0 }
    )
}

// -- the 2.x spellings -------------------------------------------------------

@c @implementation
public func tjLoadImage(
    _ filename: UnsafePointer<CChar>?,
    _ width: UnsafeMutablePointer<Int32>?,
    _ align: Int32,
    _ height: UnsafeMutablePointer<Int32>?,
    _ pixelFormat: UnsafeMutablePointer<Int32>?,
    _ flags: Int32
) -> UnsafeMutablePointer<UInt8>? {
    // No handle, so errors have nowhere per-instance to go and a temporary one
    // carries them to the global slot instead.
    let handle: tjhandle? = tj3InitLegacy(TJINIT_DECOMPRESS.id)
    defer {
        tj3Destroy(handle)
    }
    return tj3LoadImage8(handle, filename, width, align, height, pixelFormat)
}

@c @implementation
public func tjSaveImage(
    _ filename: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ width: Int32,
    _ pitch: Int32,
    _ height: Int32,
    _ pixelFormat: Int32,
    _ flags: Int32
) -> Int32 {
    let handle: tjhandle? = tj3InitLegacy(TJINIT_COMPRESS.id)
    defer {
        tj3Destroy(handle)
    }
    return tj3SaveImage8(handle, filename, buffer, width, pitch, height, pixelFormat)
}
