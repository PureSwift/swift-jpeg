extension JPEG {
    /// A marker code, identifying the segment that follows it in a JPEG stream.
    ///
    /// Markers are two bytes: an `0xFF` prefix followed by a non-zero code
    /// byte. This type models the code byte. `0x00` never appears as a code —
    /// the sequence `FF 00` is a stuffed literal `0xFF` inside entropy coded
    /// data — and `0xFF` itself is a fill byte, so a run of `0xFF` before a
    /// marker is legal padding rather than a malformed marker.
    ///
    /// The cases here cover T.81 Table B.1. Codes this library has no use for
    /// still round-trip through ``reserved(_:)`` so that a lexer can skip their
    /// segments without losing the ability to report what it skipped.
    public enum Marker: Sendable, Hashable {
        /// Start of image — `SOI`, `0xD8`.
        case start
        /// End of image — `EOI`, `0xD9`.
        case end
        /// Start of frame — one of the `SOF` codes.
        ///
        /// Carries the coding process, which is encoded in the marker itself
        /// rather than in the segment payload.
        case frame(Process)
        /// Start of scan — `SOS`, `0xDA`.
        case scan
        /// Define Huffman tables — `DHT`, `0xC4`.
        case huffman
        /// Define quantization tables — `DQT`, `0xDB`.
        case quantization
        /// Define restart interval — `DRI`, `0xDD`.
        case restartInterval
        /// Restart — `RST`*n*, `0xD0` through `0xD7`.
        ///
        /// The payload is the restart phase, 0 through 7, which cycles so a
        /// decoder can detect a dropped interval.
        case restart(Int)
        /// Define number of lines — `DNL`, `0xDC`.
        ///
        /// Supplies the image height for streams written before the height was
        /// known.
        case height
        /// Application segment — `APP`*n*, `0xE0` through `0xEF`.
        ///
        /// `APP0` carries JFIF and `APP1` carries EXIF, but the standard
        /// reserves no meaning for any of them, so the payload is left to the
        /// caller to interpret.
        case application(Int)
        /// Comment — `COM`, `0xFE`.
        case comment
        /// Define arithmetic coding conditioning — `DAC`, `0xCC`.
        case arithmeticCodingCondition
        /// Define hierarchical progression — `DHP`, `0xDE`.
        case hierarchical
        /// Expand reference components — `EXP`, `0xDF`.
        case expandReference
        /// A marker this library does not interpret.
        ///
        /// Covers `TEM`, the `JPG` codes, and the codes T.81 leaves reserved.
        case reserved(UInt8)
    }
}

extension JPEG.Marker {
    /// Creates a marker from its code byte, or returns `nil` if the byte is not
    /// a valid marker code.
    ///
    /// -   Parameter code:
    ///     The byte following the `0xFF` prefix. `0x00` and `0xFF` are rejected
    ///     because neither introduces a marker.
    public init?(code: UInt8) {
        switch code {
        case 0x00, 0xFF:
            return nil

        case 0xC4:
            self = .huffman
        case 0xCC:
            self = .arithmeticCodingCondition
        case 0xC0 ... 0xCF:
            // Everything else in this range is a frame header. The two
            // non-frame codes in it are handled above, so the failable
            // initializer cannot fail here.
            guard let process: JPEG.Process = .init(markerCode: code) else {
                self = .reserved(code)
                return
            }
            self = .frame(process)

        case 0xD0 ... 0xD7:
            self = .restart(.init(code - 0xD0))
        case 0xD8:
            self = .start
        case 0xD9:
            self = .end
        case 0xDA:
            self = .scan
        case 0xDB:
            self = .quantization
        case 0xDC:
            self = .height
        case 0xDD:
            self = .restartInterval
        case 0xDE:
            self = .hierarchical
        case 0xDF:
            self = .expandReference

        case 0xE0 ... 0xEF:
            self = .application(.init(code - 0xE0))
        case 0xFE:
            self = .comment

        default:
            self = .reserved(code)
        }
    }

    /// The code byte that encodes this marker.
    ///
    /// The inverse of ``init(code:)`` for every case a writer can produce. A
    /// frame marker's code comes back from the process, which is where it was
    /// carried in the first place.
    public var code: UInt8 {
        switch self {
        case .start:                        return 0xD8
        case .end:                          return 0xD9
        case .scan:                         return 0xDA
        case .quantization:                 return 0xDB
        case .height:                       return 0xDC
        case .restartInterval:              return 0xDD
        case .hierarchical:                 return 0xDE
        case .expandReference:              return 0xDF
        case .huffman:                      return 0xC4
        case .arithmeticCodingCondition:    return 0xCC
        case .comment:                      return 0xFE
        case .restart(let phase):           return 0xD0 + .init(truncatingIfNeeded: phase & 7)
        case .application(let n):           return 0xE0 + .init(truncatingIfNeeded: n & 15)
        case .reserved(let code):           return code
        case .frame(let process):           return process.markerCode
        }
    }

    /// Whether a length field and payload follow this marker.
    ///
    /// The standalone markers carry no segment: a lexer must not try to read a
    /// length after them. ``scan`` is the awkward one — it *does* have a
    /// payload, but entropy coded data follows the payload rather than another
    /// marker, so the lexer has to switch modes after reading it.
    public var hasPayload: Bool {
        switch self {
        case .start, .end, .restart:
            return false
        case .reserved(let code):
            // TEM is standalone; the reserved JPG codes are not.
            return code != 0x01
        default:
            return true
        }
    }
}
