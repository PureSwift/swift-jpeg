import CTurboJPEG
import JPEG

/// The component layout of one of TurboJPEG's packed pixel formats.
///
/// TurboJPEG names twelve formats that differ only in component order, padding,
/// and whether an alpha channel is present. Rather than twelve conversion
/// paths, each one is described by where its components sit in a pixel, and one
/// loop reads any of them.
struct PixelFormat {
    /// Bytes per pixel.
    let size: Int
    /// Byte offsets of red, green and blue within a pixel.
    let red: Int
    let green: Int
    let blue: Int
    /// The alpha offset, or `nil` if the format has no alpha.
    ///
    /// The `X` formats have a padding byte where an alpha channel would be. It
    /// is deliberately *not* reported here: a decoder must leave that byte
    /// untouched, whereas alpha is set to opaque.
    let alpha: Int?
    /// Whether this format carries a single luminance channel.
    let isGray: Bool

    /// Describes a `TJPF` value, or returns `nil` if this library cannot
    /// convert it.
    ///
    /// The offsets match libjpeg-turbo's own tables, since they are what
    /// callers' buffers are laid out to.
    init?(_ format: Int32) {
        switch format {
        case TJPF_RGB.rawValue:
            self.init(size: 3, red: 0, green: 1, blue: 2, alpha: nil, isGray: false)
        case TJPF_BGR.rawValue:
            self.init(size: 3, red: 2, green: 1, blue: 0, alpha: nil, isGray: false)
        case TJPF_RGBX.rawValue:
            self.init(size: 4, red: 0, green: 1, blue: 2, alpha: nil, isGray: false)
        case TJPF_BGRX.rawValue:
            self.init(size: 4, red: 2, green: 1, blue: 0, alpha: nil, isGray: false)
        case TJPF_XBGR.rawValue:
            self.init(size: 4, red: 3, green: 2, blue: 1, alpha: nil, isGray: false)
        case TJPF_XRGB.rawValue:
            self.init(size: 4, red: 1, green: 2, blue: 3, alpha: nil, isGray: false)
        case TJPF_GRAY.rawValue:
            self.init(size: 1, red: 0, green: 0, blue: 0, alpha: nil, isGray: true)
        case TJPF_RGBA.rawValue:
            self.init(size: 4, red: 0, green: 1, blue: 2, alpha: 3, isGray: false)
        case TJPF_BGRA.rawValue:
            self.init(size: 4, red: 2, green: 1, blue: 0, alpha: 3, isGray: false)
        case TJPF_ABGR.rawValue:
            self.init(size: 4, red: 3, green: 2, blue: 1, alpha: 0, isGray: false)
        case TJPF_ARGB.rawValue:
            self.init(size: 4, red: 1, green: 2, blue: 3, alpha: 0, isGray: false)
        default:
            // TJPF_CMYK and anything unrecognized. CMYK is not a packed RGB
            // layout at all and needs a separate path through a four-component
            // JPEG, which this library does not encode yet.
            return nil
        }
    }

    private init(size: Int, red: Int, green: Int, blue: Int, alpha: Int?, isGray: Bool) {
        self.size = size
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.isGray = isGray
    }
}

/// A chroma subsampling arrangement, as `TJSAMP` names it.
struct Subsampling {
    /// The luminance sampling factors. Chrominance is always `(1, 1)`, which is
    /// what makes the ratio come out as stated.
    let luma: JPEG.Component.Sampling
    /// Whether this arrangement has no chrominance components at all.
    let isGray: Bool

    init?(_ value: Int32) {
        switch value {
        case TJSAMP_444.rawValue:   self.init(x: 1, y: 1, gray: false)
        case TJSAMP_422.rawValue:   self.init(x: 2, y: 1, gray: false)
        case TJSAMP_420.rawValue:   self.init(x: 2, y: 2, gray: false)
        case TJSAMP_GRAY.rawValue:  self.init(x: 1, y: 1, gray: true)
        case TJSAMP_440.rawValue:   self.init(x: 1, y: 2, gray: false)
        case TJSAMP_411.rawValue:   self.init(x: 4, y: 1, gray: false)
        case TJSAMP_441.rawValue:   self.init(x: 1, y: 4, gray: false)
        case TJSAMP_410.rawValue:   self.init(x: 4, y: 2, gray: false)
        case TJSAMP_24.rawValue:    self.init(x: 2, y: 4, gray: false)
        default:                    return nil
        }
    }

    /// The iMCU dimensions this arrangement implies, in samples.
    ///
    /// Equal to libjpeg-turbo's `tjMCUWidth` and `tjMCUHeight` tables, which
    /// are just eight times the luma sampling factors. Derived rather than
    /// transcribed so the two cannot disagree.
    var mcu: (width: Int, height: Int) {
        (width: 8 * self.luma.x, height: 8 * self.luma.y)
    }

    /// How many planes an image in this arrangement has.
    var planes: Int {
        self.isGray ? 1 : 3
    }

    private init(x: Int, y: Int, gray: Bool) {
        self.luma = .init(x: x, y: y)
        self.isGray = gray
    }

    /// The `TJSAMP` value describing a decoded image's layout.
    ///
    /// Reports `TJSAMP_UNKNOWN` for anything outside the named set, which is
    /// what TurboJPEG itself does — an unusual arrangement still decodes, it
    /// just has no name.
    static func value<Format>(of layout: JPEG.Layout<Format>) -> Int32 {
        guard layout.planes.count > 1 else {
            return TJSAMP_GRAY.rawValue
        }
        switch (layout.scale.x, layout.scale.y) {
        case (1, 1):    return TJSAMP_444.rawValue
        case (2, 1):    return TJSAMP_422.rawValue
        case (2, 2):    return TJSAMP_420.rawValue
        case (1, 2):    return TJSAMP_440.rawValue
        case (4, 1):    return TJSAMP_411.rawValue
        case (1, 4):    return TJSAMP_441.rawValue
        case (4, 2):    return TJSAMP_410.rawValue
        case (2, 4):    return TJSAMP_24.rawValue
        default:        return TJSAMP_UNKNOWN.rawValue
        }
    }
}
