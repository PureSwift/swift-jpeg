/// A namespace for JPEG functionality.
///
/// Everything this module vends lives under this namespace. The module itself
/// is named `JPEG`, so `import JPEG` brings the namespace into scope and member
/// types are spelled `JPEG.Process`, `JPEG.Marker`, and so on.
public enum JPEG {
}

extension JPEG {
    /// The entropy coding method used by a frame.
    ///
    /// Both methods are described by ITU-T T.81. Arithmetic coding was patent
    /// encumbered when the standard was published and is consequently almost
    /// never seen in the wild; this library recognizes it so that it can report
    /// an accurate error rather than misinterpret the scan data.
    public enum Coding: Sendable, Hashable {
        /// Huffman coding, as defined in T.81 Annex C.
        case huffman
        /// Arithmetic coding, as defined in T.81 Annex D.
        case arithmetic
    }

    /// The coding process used by a frame.
    ///
    /// A JPEG file declares its coding process through the choice of
    /// start-of-frame marker rather than through a field, so this type is
    /// derived from the marker code. T.81 Table B.1 enumerates the sixteen
    /// `SOF` codes; the four reserved ones (`0xC4`, `0xC8`, `0xCC`, and the
    /// hierarchical marker) are not frame headers and are excluded here.
    ///
    /// The distinction that matters most to a decoder is ``baseline`` versus
    /// everything else: a baseline frame is 8-bit, Huffman coded, has at most
    /// two DC and two AC tables, and codes every coefficient in a single scan.
    public enum Process: Sendable, Hashable {
        /// Baseline sequential DCT, Huffman coded — `SOF0`.
        ///
        /// The only process every conforming JPEG decoder is required to
        /// support, and the one the overwhelming majority of files in
        /// circulation use.
        case baseline
        /// Extended sequential DCT — `SOF1`, `SOF5`, `SOF9`, `SOF13`.
        ///
        /// Sequential like ``baseline``, but permits 12-bit samples, four DC
        /// and four AC tables, and arithmetic coding.
        case extended(coding: Coding, differential: Bool)
        /// Progressive DCT — `SOF2`, `SOF6`, `SOF10`, `SOF14`.
        ///
        /// Coefficients are split across multiple scans by spectral band and by
        /// bit position, so that a partially transferred image can be rendered
        /// at reduced quality.
        case progressive(coding: Coding, differential: Bool)
        /// Lossless (sequential) — `SOF3`, `SOF7`, `SOF11`, `SOF15`.
        ///
        /// Predictive rather than transform based: there is no DCT and no
        /// quantization, so this shares almost nothing with the other processes
        /// beyond the marker structure.
        case lossless(coding: Coding, differential: Bool)
    }
}

extension JPEG.Process {
    /// Creates a coding process from the low byte of a start-of-frame marker,
    /// or returns `nil` if the byte does not identify a frame header.
    ///
    /// The encoding in T.81 Table B.1 is regular once the sixteen codes are
    /// laid out as a 4×4 grid. Writing `n` for `code - 0xC0`, the low two bits
    /// of `n` select the process, bit 2 is the differential flag, and bit 3
    /// selects arithmetic coding. The column where the low two bits are zero
    /// holds `SOF0`, `DHT`, `JPG`, and `DAC`, so only the first entry of that
    /// column is a frame header.
    ///
    /// -   Parameter code:
    ///     A marker code byte, such as `0xC2` for progressive.
    init?(markerCode code: UInt8) {
        guard case 0xC0 ... 0xCF = code else {
            return nil
        }

        let n: UInt8 = code - 0xC0
        guard n & 0x03 != 0 else {
            // 0xC4 is DHT, 0xC8 is JPG, 0xCC is DAC — none of them frames.
            guard n == 0 else {
                return nil
            }
            self = .baseline
            return
        }

        let coding: JPEG.Coding = n & 0x08 != 0 ? .arithmetic : .huffman
        let differential: Bool = n & 0x04 != 0

        switch n & 0x03 {
        case 1:     self = .extended(coding: coding, differential: differential)
        case 2:     self = .progressive(coding: coding, differential: differential)
        default:    self = .lossless(coding: coding, differential: differential)
        }
    }

    /// The start-of-frame marker code that identifies this process.
    ///
    /// The inverse of ``init(markerCode:)``, reassembling the same 4×4 grid:
    /// the process in the low two bits, the differential flag in bit 2, and
    /// arithmetic coding in bit 3.
    var markerCode: UInt8 {
        switch self {
        case .baseline:
            return 0xC0
        case .extended(coding: let coding, differential: let differential):
            return 0xC1 | Self.flags(coding, differential)
        case .progressive(coding: let coding, differential: let differential):
            return 0xC2 | Self.flags(coding, differential)
        case .lossless(coding: let coding, differential: let differential):
            return 0xC3 | Self.flags(coding, differential)
        }
    }

    private static func flags(_ coding: JPEG.Coding, _ differential: Bool) -> UInt8 {
        (coding == .arithmetic ? 0x08 : 0) | (differential ? 0x04 : 0)
    }

    /// Whether this process codes its coefficients across multiple scans.
    public var isProgressive: Bool {
        if case .progressive = self {
            return true
        } else {
            return false
        }
    }

    /// The entropy coding method this process uses.
    public var coding: JPEG.Coding {
        switch self {
        case .baseline:
            return .huffman
        case .extended(coding: let coding, differential: _),
             .progressive(coding: let coding, differential: _),
             .lossless(coding: let coding, differential: _):
            return coding
        }
    }

    /// The sample bit depths this process permits.
    ///
    /// A frame header declaring a precision outside this range is malformed.
    /// Lossless frames are the widest, accepting anything from 2 to 16 bits.
    public var precisions: ClosedRange<Int> {
        switch self {
        case .baseline:
            return 8 ... 8
        case .extended, .progressive:
            return 8 ... 12
        case .lossless:
            return 2 ... 16
        }
    }
}
