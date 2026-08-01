extension JPEG {
    /// A color format.
    ///
    /// JPEG does not record what its components *mean*. A frame header lists
    /// component identifiers and sampling factors and stops there; whether
    /// three components are YCbCr or RGB is a convention carried by an
    /// application segment, or simply assumed. This protocol is where that
    /// assumption is made explicit and replaceable, so a caller with an unusual
    /// stream can supply their own interpretation instead of being told the
    /// file is invalid.
    public protocol Format: Sendable, Equatable {
        /// Identifies this format from the component set and sample precision a
        /// frame header declared, or returns `nil` if it does not recognize
        /// them.
        static func recognize(_ components: Set<JPEG.Component.Key>, precision: Int) -> Self?

        /// The component identifiers, in plane order.
        ///
        /// The order fixes which plane each component decodes into, so it must
        /// be stable. It may list fewer components than ``recognize(_:precision:)``
        /// was given, which drops the omitted ones.
        var components: [JPEG.Component.Key] { get }

        /// The sample precision, in bits.
        var precision: Int { get }
    }

    /// A color target that interleaved samples can be unpacked into.
    public protocol Color: Sendable {
        /// The color format this target reads from.
        associatedtype Format: JPEG.Format

        /// Converts interleaved samples into an array of colors.
        ///
        /// -   Parameters:
        ///     -   interleaved: Samples in plane order, one group per pixel.
        ///     -   format: The format the samples were decoded as.
        static func unpack(_ interleaved: [UInt16], of format: Format) -> [Self]
    }
}

extension JPEG {
    /// The color formats this library recognizes without help.
    ///
    /// Deliberately small. Anything outside it is reported as
    /// ``nonconforming(_:precision:)`` rather than rejected, so an unusual
    /// stream still decodes to planes and only the color interpretation is left
    /// to the caller.
    public enum Common: Sendable, Equatable {
        /// A single component, interpreted as luminance.
        case y(JPEG.Component.Key, precision: Int)
        /// Three components, interpreted as YCbCr in declaration order.
        case ycc(JPEG.Component.Key, JPEG.Component.Key, JPEG.Component.Key, precision: Int)
        /// A component set this library assigns no color meaning to.
        case nonconforming([JPEG.Component.Key], precision: Int)
    }
}

extension JPEG.Common: JPEG.Format {
    public static func recognize(
        _ components: Set<JPEG.Component.Key>,
        precision: Int
    ) -> Self? {
        // Sorting by identifier is the only ordering available here — a set
        // carries none — and it matches the JFIF convention of numbering the
        // components 1, 2, 3 in Y, Cb, Cr order.
        let sorted: [JPEG.Component.Key] = components.sorted()
        switch sorted.count {
        case 1:
            return .y(sorted[0], precision: precision)
        case 3:
            return .ycc(sorted[0], sorted[1], sorted[2], precision: precision)
        default:
            return .nonconforming(sorted, precision: precision)
        }
    }

    public var components: [JPEG.Component.Key] {
        switch self {
        case .y(let y, precision: _):
            return [y]
        case .ycc(let y, let cb, let cr, precision: _):
            return [y, cb, cr]
        case .nonconforming(let keys, precision: _):
            return keys
        }
    }

    public var precision: Int {
        switch self {
        case .y(_, precision: let precision),
             .ycc(_, _, _, precision: let precision),
             .nonconforming(_, precision: let precision):
            return precision
        }
    }
}

extension JPEG {
    /// A luminance-chrominance color, as JFIF defines it.
    public struct YCbCr: Sendable, Hashable {
        public var y: UInt8
        public var cb: UInt8
        public var cr: UInt8

        public init(y: UInt8, cb: UInt8 = 128, cr: UInt8 = 128) {
            self.y = y
            self.cb = cb
            self.cr = cr
        }
    }

    /// An 8-bit RGB color.
    public struct RGB: Sendable, Hashable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8

        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        public init(_ gray: UInt8) {
            self.init(gray, gray, gray)
        }
    }
}

extension JPEG.YCbCr {
    /// The conversion coefficients of JFIF §7, in 16-bit fixed point.
    ///
    /// Integer arithmetic rather than floating point, so the result is exactly
    /// reproducible on every platform and the module stays usable where a
    /// floating point unit may not be. The scale is 2^16; the rounding term
    /// added before shifting is half of that.
    private enum Fixed {
        static let half: Int32 = 1 << 15
        /// 1.402
        static let crToR: Int32 = 91881
        /// -0.344136
        static let cbToG: Int32 = -22554
        /// -0.714136
        static let crToG: Int32 = -46802
        /// 1.772
        static let cbToB: Int32 = 116130
    }

    /// Converts to RGB, clamping out-of-gamut results.
    ///
    /// Clamping is required, not defensive: the YCbCr cube is larger than the
    /// RGB one, so lossy coefficients routinely produce values a few counts
    /// outside 0 ... 255 even for images that were in gamut when encoded.
    public var rgb: JPEG.RGB {
        let y: Int32 = .init(self.y) << 16 | Fixed.half
        let cb: Int32 = .init(Int(self.cb) - 128)
        let cr: Int32 = .init(Int(self.cr) - 128)

        let r: Int32 = y + Fixed.crToR * cr
        let g: Int32 = y + Fixed.cbToG * cb + Fixed.crToG * cr
        let b: Int32 = y + Fixed.cbToB * cb

        return .init(
            JPEG.YCbCr.clamp(r >> 16),
            JPEG.YCbCr.clamp(g >> 16),
            JPEG.YCbCr.clamp(b >> 16)
        )
    }

    private static func clamp(_ value: Int32) -> UInt8 {
        if value < 0 {
            return 0
        } else if value > 255 {
            return 255
        } else {
            return .init(value)
        }
    }
}

extension JPEG.YCbCr: JPEG.Color {
    public static func unpack(_ interleaved: [UInt16], of format: JPEG.Common) -> [Self] {
        let scale: Int = format.precision - 8

        switch format {
        case .y:
            return interleaved.map {
                .init(y: JPEG.YCbCr.narrow($0, by: scale))
            }
        case .ycc:
            return stride(from: 0, to: interleaved.count - 2, by: 3).map {
                .init(
                    y: JPEG.YCbCr.narrow(interleaved[$0], by: scale),
                    cb: JPEG.YCbCr.narrow(interleaved[$0 + 1], by: scale),
                    cr: JPEG.YCbCr.narrow(interleaved[$0 + 2], by: scale)
                )
            }
        case .nonconforming(let keys, precision: _):
            // No color meaning is defined, so the first component stands in for
            // luminance and the rest are dropped. Callers who care should reach
            // for the planar representation instead of unpacking.
            let count: Int = Swift.max(1, keys.count)
            return stride(from: 0, to: interleaved.count, by: count).map {
                .init(y: JPEG.YCbCr.narrow(interleaved[$0], by: scale))
            }
        }
    }

    /// Reduces a sample of arbitrary precision to 8 bits.
    private static func narrow(_ sample: UInt16, by scale: Int) -> UInt8 {
        if scale > 0 {
            return .init(truncatingIfNeeded: sample >> UInt16(scale))
        } else if scale < 0 {
            return .init(truncatingIfNeeded: sample << UInt16(-scale))
        } else {
            return .init(truncatingIfNeeded: sample)
        }
    }
}

extension JPEG.RGB: JPEG.Color {
    public static func unpack(_ interleaved: [UInt16], of format: JPEG.Common) -> [Self] {
        JPEG.YCbCr.unpack(interleaved, of: format).map(\.rgb)
    }
}
