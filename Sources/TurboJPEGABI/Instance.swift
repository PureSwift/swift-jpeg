import CTurboJPEG
import JPEG

/// What a `tjhandle` actually points at.
///
/// TurboJPEG's handle is `void *`, which is the property that makes this whole
/// substitution possible: the caller never sees inside, so the engine is free
/// to own its own data instead of reproducing a C struct layout. Contrast
/// `jpeglib.h`, where callers read `cinfo.output_width` directly and there is no
/// seam at all.
///
/// A handle is a retained reference to one of these. It is deliberately *not*
/// thread safe, matching TurboJPEG: the documented contract is one handle per
/// thread, and adding locking here would be slower and still not make the
/// caller's usage correct.
final class Instance {
    /// What the handle was created for.
    let initType: Int32

    /// The TurboJPEG API version the client was compiled against.
    ///
    /// Not a formality. libjpeg-turbo uses it to *withhold* features a client
    /// could not have known about — `TJSAMP_410` and `TJSAMP_24` were added in
    /// 3.2, and the `tjMCUWidth`/`tjMCUHeight` arrays a pre-3.2 client compiled
    /// against are too short to describe them. Handing such a client one of
    /// those values would make it index past the end of its own table.
    let apiVersion: Int32

    /// How many subsampling values this client may use.
    var subsamplingLimit: Int32 {
        self.apiVersion >= 3002000 ? 9 : 7
    }

    /// Parameter values set through `tj3Set`, keyed by `TJPARAM`.
    ///
    /// A dictionary rather than stored properties because the parameter space
    /// is sparse, open-ended, and mostly untouched by any given caller —
    /// `tj3Set` is a generic setter and modelling it generically keeps the
    /// unimplemented parameters from silently reading as zero.
    var parameters: [Int32: Int32]

    /// The most recent error, as `tj3GetErrorCode` and `tj3GetErrorStr` report
    /// it.
    ///
    /// Null-terminated, because `tj3GetErrorStr` hands the caller a `char *`
    /// that must remain valid until the next call on the same handle. Storing
    /// it here rather than building it on demand is what gives it that
    /// lifetime.
    var errorCode: Int32
    var errorMessage: [CChar]

    /// The ICC profile to embed in the next compressed image, if any.
    var iccProfile: [UInt8]?

    /// The ICC profile found in the most recently decompressed image.
    ///
    /// Separate from ``iccProfile`` on purpose: one is a request and the other
    /// is a finding, and a handle used for both compression and decompression
    /// would otherwise conflate them.
    var decodedProfile: [UInt8]?

    /// The scaling factor decompression should apply, as a fraction.
    ///
    /// Stored rather than applied immediately because it takes effect at the
    /// next decompression, and a caller may set it once and decode many images.
    var scalingFactor: (numerator: Int, denominator: Int)

    /// The region decompression should crop to, or `nil` for the whole image.
    var croppingRegion: (x: Int, y: Int, width: Int, height: Int)?

    /// The buffer most recently returned to the caller, when this library
    /// allocated it.
    ///
    /// Kept so that `tj3Free` can be pointed at memory Swift allocated. The
    /// caller is entitled to free it themselves, which is why the allocation
    /// goes through the same path `tj3Alloc` uses rather than through an
    /// `Array`.
    var owned: Set<UInt>

    init(initType: Int32, apiVersion: Int32) {
        self.initType = initType
        self.apiVersion = apiVersion
        self.parameters = [:]
        self.iccProfile = nil
        self.decodedProfile = nil
        self.scalingFactor = (numerator: 1, denominator: 1)
        self.croppingRegion = nil
        self.errorCode = TJERR_WARNING.id
        self.errorMessage = Instance.terminated("No error")
        self.owned = []
        self.clearError()
    }

    /// Converts a Swift string into the null-terminated form the C API returns.
    static func terminated(_ message: String) -> [CChar] {
        var bytes: [CChar] = message.utf8.map { CChar(bitPattern: $0) }
        bytes.append(0)
        return bytes
    }

    func clearError() {
        self.errorCode = 0
        self.errorMessage = Instance.terminated("No error")
    }

    /// Records a fatal error and returns the API's failure value.
    ///
    /// Every entry point funnels failures through here so that a caller who
    /// checks only the return code and a caller who reads `tj3GetErrorStr` see
    /// the same thing.
    @discardableResult
    func fail(_ message: String) -> Int32 {
        self.errorCode = TJERR_FATAL.id
        self.errorMessage = Instance.terminated(message)
        return -1
    }

    /// Records a fatal error from a thrown engine error.
    @discardableResult
    func fail(_ error: any Error) -> Int32 {
        if let error: any JPEG.Error = error as? any JPEG.Error {
            return self.fail("\(type(of: error).namespace): \(error.message)")
        } else {
            return self.fail("\(error)")
        }
    }

    /// Reads a parameter, falling back to the documented default.
    func parameter(_ param: TJPARAM, default fallback: Int32 = 0) -> Int32 {
        self.parameters[param.id] ?? fallback
    }
}

/// An error raised inside the boundary rather than by the engine.
enum Failure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):    return text
        }
    }
}

extension Instance {
    /// Recovers the instance a handle refers to, without changing its retain
    /// count.
    ///
    /// Returns `nil` for a null handle, which every entry point must tolerate:
    /// the C API's own error path hands back `NULL` from `tj3Init`, and callers
    /// routinely pass it straight into the next call.
    static func borrow(_ handle: tjhandle?) -> Instance? {
        guard let handle: tjhandle = handle else {
            return nil
        }
        return Unmanaged<Instance>.fromOpaque(handle).takeUnretainedValue()
    }

    /// Produces a handle owning one reference to this instance.
    func handle() -> tjhandle {
        Unmanaged.passRetained(self).toOpaque()
    }
}
