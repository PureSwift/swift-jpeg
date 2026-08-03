#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Reading and writing the uncompressed image files the API can load and save.
///
/// Two families, chosen by extension exactly as libjpeg-turbo chooses them:
/// Windows bitmaps for `.bmp`, and PBMPLUS — the PGM and PPM formats — for
/// everything else.
///
/// The split is not arbitrary. A bitmap stores 8 bits per channel and nothing
/// else, so it cannot represent the 12- and 16-bit images the wider entry
/// points exist for; PGM and PPM carry an explicit maximum value and switch to
/// two bytes per sample above 255. Loading a 12-bit image therefore means a
/// PGM or PPM, and saying so is better than writing a silently truncated
/// bitmap.
enum ImageFile {
    /// An uncompressed image, as read from or written to a file.
    struct Raw {
        let width: Int
        let height: Int
        /// 1 for grayscale, 3 for color.
        let channels: Int
        /// The largest value a sample may take, which fixes the precision.
        let maxValue: Int
        /// Samples, row-major, `channels` per pixel.
        var samples: [UInt16]
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case unsupported(String)

        var description: String {
            switch self {
            case .unreadable(let text):     return text
            case .malformed(let text):      return text
            case .unsupported(let text):    return text
            }
        }
    }
}

extension ImageFile {
    private static func read(path: String) throws -> [UInt8] {
        guard let file: UnsafeMutablePointer<FILE> = fopen(path, "rb") else {
            throw Failure.unreadable("could not open \(path)")
        }
        defer {
            fclose(file)
        }

        var bytes: [UInt8] = []
        var chunk: [UInt8] = .init(repeating: 0, count: 1 << 16)
        while true {
            let n: Int = chunk.withUnsafeMutableBytes {
                fread($0.baseAddress, 1, 1 << 16, file)
            }
            guard n > 0 else {
                break
            }
            bytes.append(contentsOf: chunk[0 ..< n])
        }
        return bytes
    }

    private static func write(path: String, bytes: [UInt8]) throws {
        guard let file: UnsafeMutablePointer<FILE> = fopen(path, "wb") else {
            throw Failure.unreadable("could not open \(path) for writing")
        }
        defer {
            fclose(file)
        }
        let written: Int = bytes.withUnsafeBytes {
            fwrite($0.baseAddress, 1, bytes.count, file)
        }
        guard written == bytes.count else {
            throw Failure.unreadable("wrote \(written) of \(bytes.count) bytes to \(path)")
        }
    }

    private static func isBitmap(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".bmp")
    }

    static func load(path: String) throws -> Raw {
        let bytes: [UInt8] = try read(path: path)
        guard !bytes.isEmpty else {
            throw Failure.malformed("\(path) is empty")
        }
        return isBitmap(path) ? try loadBitmap(bytes) : try loadNetpbm(bytes)
    }

    static func save(path: String, image: Raw) throws {
        try write(
            path: path,
            bytes: isBitmap(path) ? try saveBitmap(image) : saveNetpbm(image)
        )
    }
}

// -- PGM and PPM -------------------------------------------------------------

extension ImageFile {
    /// Reads one whitespace-delimited header token, skipping comments.
    ///
    /// Comments run from `#` to end of line and may appear *between* any two
    /// header fields, including in the middle of the dimensions, which is why
    /// this is a token reader rather than a line parser.
    private static func token(_ bytes: [UInt8], _ i: inout Int) throws -> String {
        while i < bytes.count {
            if bytes[i] == 0x23 {
                while i < bytes.count, bytes[i] != 0x0A {
                    i += 1
                }
            } else if bytes[i] == 0x20 || (0x09 ... 0x0D).contains(bytes[i]) {
                i += 1
            } else {
                break
            }
        }
        let start: Int = i
        while i < bytes.count,
              bytes[i] != 0x20, !(0x09 ... 0x0D).contains(bytes[i]), bytes[i] != 0x23
        {
            i += 1
        }
        guard i > start else {
            throw Failure.malformed("truncated PBMPLUS header")
        }
        return String(decoding: bytes[start ..< i], as: UTF8.self)
    }

    private static func loadNetpbm(_ bytes: [UInt8]) throws -> Raw {
        var i: Int = 0
        let magic: String = try token(bytes, &i)

        let channels: Int
        let binary: Bool
        switch magic {
        case "P2":  (channels, binary) = (1, false)
        case "P3":  (channels, binary) = (3, false)
        case "P5":  (channels, binary) = (1, true)
        case "P6":  (channels, binary) = (3, true)
        default:
            throw Failure.unsupported("\(magic) is not a PGM or PPM signature")
        }

        guard
        let width: Int = .init(try token(bytes, &i)),
        let height: Int = .init(try token(bytes, &i)),
        let maxValue: Int = .init(try token(bytes, &i)),
        width > 0, height > 0, 1 ... 65535 ~= maxValue
        else {
            throw Failure.malformed("invalid PBMPLUS header fields")
        }

        let count: Int = width * height * channels
        var samples: [UInt16] = .init(repeating: 0, count: count)

        if binary {
            // Exactly one whitespace byte separates the header from the data,
            // and it is part of the header — anything after it is a sample,
            // including a byte that happens to look like whitespace.
            i += 1
            let wide: Bool = maxValue > 255
            let needed: Int = count * (wide ? 2 : 1)
            guard bytes.count - i >= needed else {
                throw Failure.malformed(
                    "PBMPLUS data is \(bytes.count - i) bytes, needs \(needed)"
                )
            }
            for k: Int in 0 ..< count {
                if wide {
                    // Two-byte samples are big-endian, which is the one thing
                    // the format specifies about them.
                    samples[k] = .init(bytes[i + 2 * k]) << 8 | .init(bytes[i + 2 * k + 1])
                } else {
                    samples[k] = .init(bytes[i + k])
                }
            }
        } else {
            for k: Int in 0 ..< count {
                guard let value: Int = .init(try token(bytes, &i)) else {
                    throw Failure.malformed("non-numeric sample in PBMPLUS data")
                }
                samples[k] = .init(truncatingIfNeeded: value)
            }
        }

        return .init(
            width: width, height: height, channels: channels,
            maxValue: maxValue, samples: samples
        )
    }

    private static func saveNetpbm(_ image: Raw) -> [UInt8] {
        var bytes: [UInt8] = .init(
            "\(image.channels == 1 ? "P5" : "P6")\n\(image.width) \(image.height)\n"
                .utf8
        )
        bytes.append(contentsOf: "\(image.maxValue)\n".utf8)

        if image.maxValue > 255 {
            for sample: UInt16 in image.samples {
                bytes.append(.init(truncatingIfNeeded: sample >> 8))
                bytes.append(.init(truncatingIfNeeded: sample))
            }
        } else {
            for sample: UInt16 in image.samples {
                bytes.append(.init(truncatingIfNeeded: sample))
            }
        }
        return bytes
    }
}

// -- Windows bitmap ----------------------------------------------------------

extension ImageFile {
    private static func loadBitmap(_ bytes: [UInt8]) throws -> Raw {
        guard bytes.count >= 54, bytes[0] == 0x42, bytes[1] == 0x4D else {
            throw Failure.malformed("not a Windows bitmap")
        }

        func word(_ offset: Int) -> Int {
            .init(bytes[offset]) | .init(bytes[offset + 1]) << 8
        }
        func long(_ offset: Int) -> Int {
            word(offset) | word(offset + 2) << 16
        }

        let offset: Int = long(10)
        let width: Int = long(18)
        // A negative height means the rows are stored top-down, which is the
        // only way a bitmap expresses that.
        let signed: Int = long(22)
        let topDown: Bool = signed >= 0x8000_0000
        let height: Int = topDown ? 0x1_0000_0000 - signed : signed
        let depth: Int = word(28)
        let compression: Int = long(30)

        guard width > 0, height > 0 else {
            throw Failure.malformed("bitmap has a zero dimension")
        }
        guard compression == 0 else {
            throw Failure.unsupported("compressed bitmaps are not supported")
        }
        guard depth == 24 || depth == 32 else {
            throw Failure.unsupported("\(depth)-bit bitmaps are not supported")
        }

        let size: Int = depth / 8
        // Rows are padded to a multiple of four bytes.
        let stride: Int = (width * size + 3) & ~3
        guard bytes.count >= offset + stride * height else {
            throw Failure.malformed("bitmap pixel data is truncated")
        }

        var samples: [UInt16] = .init(repeating: 0, count: width * height * 3)
        for y: Int in 0 ..< height {
            let row: Int = offset + (topDown ? y : height - 1 - y) * stride
            for x: Int in 0 ..< width {
                let pixel: Int = row + x * size
                let base: Int = (y * width + x) * 3
                // Bitmaps store blue first.
                samples[base] = .init(bytes[pixel + 2])
                samples[base + 1] = .init(bytes[pixel + 1])
                samples[base + 2] = .init(bytes[pixel])
            }
        }

        return .init(
            width: width, height: height, channels: 3, maxValue: 255, samples: samples
        )
    }

    private static func saveBitmap(_ image: Raw) throws -> [UInt8] {
        guard image.maxValue <= 255 else {
            throw Failure.unsupported(
                "a Windows bitmap cannot carry \(image.maxValue > 255 ? "more than 8" : "")"
                    + " bits per channel; use a .ppm or .pgm file instead"
            )
        }

        let stride: Int = (image.width * 3 + 3) & ~3
        let pixels: Int = stride * image.height
        var bytes: [UInt8] = []
        bytes.reserveCapacity(54 + pixels)

        func append(word value: Int) {
            bytes.append(.init(truncatingIfNeeded: value))
            bytes.append(.init(truncatingIfNeeded: value >> 8))
        }
        func append(long value: Int) {
            append(word: value & 0xFFFF)
            append(word: value >> 16 & 0xFFFF)
        }

        bytes.append(contentsOf: [0x42, 0x4D])      // "BM"
        append(long: 54 + pixels)
        append(long: 0)
        append(long: 54)                            // pixel data offset
        append(long: 40)                            // info header size
        append(long: image.width)
        append(long: image.height)                  // positive: bottom-up
        append(word: 1)                             // planes
        append(word: 24)
        append(long: 0)                             // no compression
        append(long: pixels)
        append(long: 2835)                          // 72 dpi, in pixels/metre
        append(long: 2835)
        append(long: 0)                             // palette entries
        append(long: 0)

        for y: Int in 0 ..< image.height {
            let source: Int = image.height - 1 - y
            for x: Int in 0 ..< image.width {
                let base: Int = (source * image.width + x) * image.channels
                let r: UInt16 = image.samples[base]
                let g: UInt16 = image.channels == 1 ? r : image.samples[base + 1]
                let b: UInt16 = image.channels == 1 ? r : image.samples[base + 2]
                bytes.append(.init(truncatingIfNeeded: b))
                bytes.append(.init(truncatingIfNeeded: g))
                bytes.append(.init(truncatingIfNeeded: r))
            }
            for _: Int in image.width * 3 ..< stride {
                bytes.append(0)
            }
        }

        return bytes
    }
}
