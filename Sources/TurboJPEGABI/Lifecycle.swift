#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

import CTurboJPEG
import JPEG

/// The message `tj3GetErrorStr` returns when there is no handle to read it
/// from.
///
/// A global, because the function accepts a null handle and still has to return
/// a pointer that stays valid. Allocated once and never freed, which is correct
/// for a string whose lifetime is the process.
private nonisolated(unsafe) let globalError: UnsafeMutablePointer<CChar> = {
    let message: [CChar] = Instance.terminated("No error")
    let buffer: UnsafeMutablePointer<CChar> = .allocate(capacity: message.count)
    buffer.update(from: message, count: message.count)
    return buffer
}()

/// Whether an init type is one of the three the header declares.
///
/// They read like flags but are not: `TJINIT` is a plain enumeration numbered
/// 0, 1, 2, and `TJINIT_TRANSFORM` means both rather than being the bitwise or
/// of the other two. Treating them as a mask both rejects `TJINIT_COMPRESS`,
/// which is zero, and accepts 3, which is not a value at all.
private func valid(initType: Int32) -> Bool {
    TJINIT_COMPRESS.id ... TJINIT_TRANSFORM.id ~= initType
}

/// The API version this library implements, matching the vendored header's
/// `TURBOJPEG_VERSION_NUMBER`.
private let apiVersion: Int32 = 3002000

@c @implementation
public func tj3InitVersion(_ initType: Int32, _ apiVersion: Int32) -> tjhandle! {
    // A client compiled against a newer header may call functions this library
    // does not have, so refusing here turns a would-be missing-symbol crash
    // into the documented NULL return.
    guard valid(initType: initType), apiVersion <= TurboJPEGABI.apiVersion else {
        return nil
    }
    return Instance(initType: initType).handle()
}

/// The pre-3.2 entry point.
///
/// From libjpeg-turbo 3.2 onward `tj3Init` is a *macro* in the header that
/// expands to `tj3InitVersion(initType, TURBOJPEG_VERSION_NUMBER)`, so no
/// modern client calls this symbol by name. It stays exported because binaries
/// compiled against an older header did bind to it, and dropping it would break
/// exactly the drop-in substitution this library exists to provide.
///
/// Declared with `@_cdecl` rather than `@c @implementation` because the macro
/// shadows the declaration: outside a Doxygen build there is no `tj3Init`
/// prototype for the compiler to check against.
@_cdecl("tj3Init")
public func tj3InitLegacy(_ initType: Int32) -> tjhandle! {
    guard valid(initType: initType) else {
        return nil
    }
    return Instance(initType: initType).handle()
}

@c @implementation
public func tj3Destroy(_ handle: tjhandle?) {
    guard let handle: tjhandle = handle else {
        return
    }
    Unmanaged<Instance>.fromOpaque(handle).release()
}

@c @implementation
public func tj3Alloc(_ bytes: Int) -> UnsafeMutableRawPointer? {
    guard bytes > 0 else {
        return nil
    }
    // malloc rather than Swift's allocator, because callers in the wild pass
    // these buffers to free() even though the documentation says to use
    // tj3Free. Matching libjpeg-turbo's allocator makes that work rather than
    // corrupt the heap.
    return malloc(bytes)
}

@c @implementation
public func tj3Free(_ buffer: UnsafeMutableRawPointer?) {
    free(buffer)
}

@c @implementation
public func tj3GetErrorStr(_ handle: tjhandle?) -> UnsafeMutablePointer<CChar>? {
    guard let instance: Instance = Instance.borrow(handle) else {
        return globalError
    }
    // The returned pointer must stay valid until the next call on this handle,
    // so it points into storage the instance owns rather than into a temporary.
    return instance.errorMessage.withUnsafeMutableBufferPointer { $0.baseAddress }
}

@c @implementation
public func tj3GetErrorCode(_ handle: tjhandle?) -> Int32 {
    Instance.borrow(handle)?.errorCode ?? 0
}

@c @implementation
public func tj3Set(_ handle: tjhandle?, _ param: Int32, _ value: Int32) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }
    instance.clearError()

    // Validate the parameters whose invalid values would otherwise surface much
    // later as a malformed file rather than as a failed call.
    switch param {
    case TJPARAM_QUALITY.id:
        guard 1 ... 100 ~= value else {
            return instance.fail("quality must lie in 1 ... 100")
        }
    case TJPARAM_SUBSAMP.id:
        guard Subsampling(value) != nil else {
            return instance.fail("unsupported subsampling \(value)")
        }
    case TJPARAM_PRECISION.id,
         TJPARAM_JPEGWIDTH.id,
         TJPARAM_JPEGHEIGHT.id,
         TJPARAM_COLORSPACE.id:
        // Read-only: these describe a JPEG that was read, not a request.
        return instance.fail("parameter \(param) is read-only")
    default:
        break
    }

    instance.parameters[param] = value
    return 0
}

@c @implementation
public func tj3Get(_ handle: tjhandle?, _ param: Int32) -> Int32 {
    guard let instance: Instance = Instance.borrow(handle) else {
        return -1
    }

    // Defaults matter here: a caller that never sets QUALITY still expects a
    // usable one, and TurboJPEG documents these values.
    switch param {
    case TJPARAM_QUALITY.id:
        return instance.parameter(TJPARAM_QUALITY, default: 95)
    case TJPARAM_SUBSAMP.id:
        return instance.parameter(TJPARAM_SUBSAMP, default: TJSAMP_UNKNOWN.rawValue)
    case TJPARAM_PRECISION.id:
        return instance.parameter(TJPARAM_PRECISION, default: 8)
    case TJPARAM_COLORSPACE.id:
        return instance.parameter(TJPARAM_COLORSPACE, default: TJCS_YCbCr.rawValue)
    case TJPARAM_MAXPIXELS.id, TJPARAM_MAXMEMORY.id:
        return instance.parameter(.init(rawValue: .init(bitPattern: param)), default: 0)
    default:
        return instance.parameters[param] ?? 0
    }
}
