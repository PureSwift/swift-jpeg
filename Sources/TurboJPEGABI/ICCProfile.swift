import CTurboJPEG
import JPEG

/// ICC colour profile embedding and extraction.
///
/// A profile travels in `APP2` segments prefixed with `ICC_PROFILE\0`, a
/// one-based chunk number, and a chunk count. The chunking exists because a
/// marker segment cannot exceed 65535 bytes including its own length field,
/// while profiles routinely run to hundreds of kilobytes.
///
/// The codec neither reads nor validates any of this — a profile is opaque
/// bytes that happen to describe how the samples should be interpreted, which
/// is a question about colour management rather than about JPEG.
enum ICCProfile {
    /// The signature every chunk carries, `ICC_PROFILE` and a terminator.
    static let signature: [UInt8] = [
        0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00,
    ]

    /// The signature plus the chunk number and count.
    static let headerCount: Int = signature.count + 2

    /// The most profile bytes one segment can carry.
    ///
    /// A segment's length field counts itself, so the body is at most 65533,
    /// of which the signature and chunk numbering take fourteen.
    static let chunkCapacity: Int = 65533 - headerCount

    /// Splits a profile into `APP2` segment bodies.
    static func segments(of profile: [UInt8]) -> [(marker: JPEG.Marker, body: [UInt8])] {
        guard !profile.isEmpty else {
            return []
        }

        let count: Int = (profile.count + chunkCapacity - 1) / chunkCapacity
        return (0 ..< count).map { index in
            var body: [UInt8] = signature
            // One-based, and the count is repeated in every chunk so a reader
            // can size its buffer from the first one it sees.
            body.append(.init(truncatingIfNeeded: index + 1))
            body.append(.init(truncatingIfNeeded: count))

            let start: Int = index * chunkCapacity
            let end: Int = Swift.min(start + chunkCapacity, profile.count)
            body.append(contentsOf: profile[start ..< end])

            return (marker: .application(2), body: body)
        }
    }

    /// Reassembles a profile from a JPEG stream, or returns `nil` if it carries
    /// none.
    ///
    /// Chunks are placed by their stated index rather than by arrival order, so
    /// a stream that writes them out of order still reassembles correctly.
    static func profile(in jpeg: [UInt8]) throws -> [UInt8]? {
        var stream: [UInt8] = jpeg
        try stream.start()

        var chunks: [Int: [UInt8]] = [:]
        var total: Int = 0

        reading:
        while true {
            let (marker, body): (JPEG.Marker, [UInt8]) = try stream.segment()

            switch marker {
            case .end:
                break reading
            case .scan:
                // The profile always precedes the first scan, so there is no
                // reason to walk the entropy coded data looking for one.
                break reading
            case .application(2):
                guard body.count > headerCount,
                      Array(body[0 ..< signature.count]) == signature
                else {
                    continue reading
                }
                let index: Int = .init(body[signature.count])
                total = Swift.max(total, .init(body[signature.count + 1]))
                chunks[index] = .init(body[headerCount...])
            default:
                continue reading
            }
        }

        guard total > 0 else {
            return nil
        }

        var profile: [UInt8] = []
        for index: Int in 1 ... total {
            guard let chunk: [UInt8] = chunks[index] else {
                throw Failure.message("ICC profile is missing chunk \(index) of \(total)")
            }
            profile.append(contentsOf: chunk)
        }
        return profile
    }
}

@c @implementation
public func tj3SetICCProfile(
    _ handle: tjhandle?,
    _ iccBuf: UnsafeMutablePointer<UInt8>?,
    _ iccSize: Int
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    // A null buffer or zero size clears the profile, which is how a caller
    // stops embedding one after having set it.
    guard let iccBuf: UnsafeMutablePointer<UInt8> = iccBuf, iccSize > 0 else {
        instance.iccProfile = nil
        return 0
    }

    instance.iccProfile = .init(UnsafeBufferPointer(start: iccBuf, count: iccSize))
    return 0
}

@c @implementation
public func tj3GetICCProfile(
    _ handle: tjhandle?,
    _ iccBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ iccSize: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    guard let iccBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = iccBuf,
          let iccSize: UnsafeMutablePointer<Int> = iccSize
    else {
        return instance.fail("buffer and size pointers must not be NULL")
    }
    guard let profile: [UInt8] = instance.decodedProfile, !profile.isEmpty else {
        iccBuf.pointee = nil
        iccSize.pointee = 0
        return instance.fail("the image carries no ICC profile")
    }

    // The caller owns this and frees it with tj3Free, matching every other
    // buffer this API hands back.
    guard let allocation: UnsafeMutableRawPointer = tj3Alloc(profile.count) else {
        return instance.fail("could not allocate \(profile.count) bytes")
    }
    let destination: UnsafeMutablePointer<UInt8> =
        allocation.bindMemory(to: UInt8.self, capacity: profile.count)
    destination.update(from: profile, count: profile.count)

    iccBuf.pointee = destination
    iccSize.pointee = profile.count
    return 0
}
