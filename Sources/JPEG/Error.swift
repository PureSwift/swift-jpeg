extension JPEG {
    /// A error thrown while reading or writing a JPEG stream.
    ///
    /// Errors are split by pipeline stage rather than gathered into one
    /// enumeration, because the stage tells you where to look: a
    /// ``LexingError`` means the byte stream is not shaped like a JPEG at all,
    /// a ``ParsingError`` means a marker segment was found but its contents are
    /// not self-consistent, and a ``DecodingError`` means the segments are
    /// individually valid but do not agree with one another.
    public protocol Error: Swift.Error {
        /// A human-readable name for the stage that produced this error.
        static var namespace: String { get }
        /// A one-line summary of what went wrong.
        var message: String { get }
        /// The specifics, if there are any worth stating separately.
        var details: String? { get }
    }
}

extension JPEG {
    /// An error thrown while splitting a byte stream into marker segments.
    ///
    /// These are structural failures. Nothing has been interpreted yet, so the
    /// stream is either truncated or is not a JPEG.
    public enum LexingError: JPEG.Error {
        /// The stream ended in the middle of a marker prefix.
        case truncatedMarkerSegmentType
        /// The stream ended before the two-byte segment length could be read.
        case truncatedMarkerSegmentHeader
        /// The stream ended before the segment body could be read.
        ///
        /// -   Parameter expected:
        ///     The body length the segment header declared.
        case truncatedMarkerSegmentBody(expected: Int)
        /// The stream ended inside entropy coded data, with no terminating
        /// marker.
        case truncatedEntropyCodedSegment

        /// A segment declared a length shorter than the length field itself.
        ///
        /// The field counts its own two bytes, so any value below 2 is
        /// nonsense and would make the lexer seek backwards.
        case invalidMarkerSegmentLength(Int)
        /// A byte that cannot introduce a marker was found where one was
        /// expected.
        case invalidMarkerSegmentPrefix(UInt8)
        /// The stream did not begin with a start-of-image marker.
        case invalidStartOfImage(JPEG.Marker)
    }
}

extension JPEG.LexingError {
    public static var namespace: String {
        "lexing error"
    }

    public var message: String {
        switch self {
        case .truncatedMarkerSegmentType:
            return "truncated marker segment type"
        case .truncatedMarkerSegmentHeader:
            return "truncated marker segment header"
        case .truncatedMarkerSegmentBody:
            return "truncated marker segment body"
        case .truncatedEntropyCodedSegment:
            return "truncated entropy coded segment"
        case .invalidMarkerSegmentLength:
            return "invalid marker segment length"
        case .invalidMarkerSegmentPrefix:
            return "invalid marker segment prefix"
        case .invalidStartOfImage:
            return "invalid start of image"
        }
    }

    public var details: String? {
        switch self {
        case .truncatedMarkerSegmentType:
            return "stream ended before a marker type byte could be read"
        case .truncatedMarkerSegmentHeader:
            return "stream ended before a segment length could be read"
        case .truncatedMarkerSegmentBody(expected: let expected):
            return "stream ended before \(expected) byte(s) of segment body could be read"
        case .truncatedEntropyCodedSegment:
            return "stream ended without a marker terminating the entropy coded segment"
        case .invalidMarkerSegmentLength(let length):
            return "segment length (\(length)) must be at least 2, since the field counts itself"
        case .invalidMarkerSegmentPrefix(let byte):
            return "byte 0x\(String(byte, radix: 16)) cannot introduce a marker segment"
        case .invalidStartOfImage(let marker):
            return "expected a start-of-image marker, found \(marker)"
        }
    }
}

extension JPEG {
    /// An error thrown while interpreting the contents of a marker segment.
    ///
    /// The segment was located and is the length it claimed to be; its payload
    /// is what does not make sense.
    public enum ParsingError: JPEG.Error {
        /// A segment body was a different size than its contents require.
        ///
        /// -   Parameters:
        ///     -   marker: The segment being parsed.
        ///     -   count: The body length that was present.
        ///     -   expected: The length the contents imply.
        case truncatedMarkerSegmentBody(JPEG.Marker, count: Int, expected: ClosedRange<Int>)

        /// A frame header declared a sample precision the coding process
        /// forbids.
        case invalidFramePrecision(Int, JPEG.Process)
        /// A frame header declared a component count the coding process
        /// forbids.
        case invalidFrameComponentCount(Int, JPEG.Process)
        /// A frame header declared a zero width.
        ///
        /// A zero *height* is legal — it means the height arrives later in a
        /// `DNL` segment — but a zero width is not.
        case invalidFrameWidth(Int)
        /// A frame header declared a sampling factor outside 1 ... 4.
        case invalidFrameSamplingFactor(x: Int, y: Int, JPEG.Component.Key)
        /// A frame header used the same component identifier twice.
        case duplicateFrameComponentIndex(JPEG.Component.Key)

        /// A scan header declared a component count outside 1 ... 4.
        case invalidScanComponentCount(Int)
        /// A scan header declared a spectral band that is not a valid subset of
        /// the 64 coefficients, or that is invalid for the coding process.
        case invalidScanBandRange(Range<Int>, JPEG.Process)
        /// A scan header declared a successive approximation split that does
        /// not refine the previous one by exactly one bit.
        case invalidScanSuccessiveApproximation(high: Int, low: Int)
        /// A `DAC` segment declared conditioning that cannot be satisfied.
        case invalidArithmeticConditioning(lower: Int, upper: Int)
        /// A lossless scan named a predictor outside 1 ... 7.
        ///
        /// T.81 Table H.1 defines seven; zero means "no prediction" and is
        /// reserved for differential frames in a hierarchical sequence.
        case invalidPredictor(Int)

        /// A table definition selected a slot outside the permitted range.
        case invalidHuffmanTargetCode(UInt8)
        /// A table definition declared a class other than DC or AC.
        case invalidHuffmanTypeCode(UInt8)
        /// A Huffman table's code lengths do not describe a prefix-free code.
        ///
        /// Either the code space is overfull, or the table declares more
        /// symbols than 16-bit codes can address.
        case invalidHuffmanTable
        /// A quantization table selected a slot outside the permitted range.
        case invalidQuantizationTargetCode(UInt8)
        /// A quantization table declared a precision other than 8 or 16 bits.
        case invalidQuantizationPrecisionCode(UInt8)
    }
}

extension JPEG.ParsingError {
    public static var namespace: String {
        "parsing error"
    }

    public var message: String {
        switch self {
        case .truncatedMarkerSegmentBody:
            return "truncated marker segment body"
        case .invalidFramePrecision:
            return "invalid frame precision"
        case .invalidFrameComponentCount:
            return "invalid frame component count"
        case .invalidFrameWidth:
            return "invalid frame width"
        case .invalidFrameSamplingFactor:
            return "invalid frame sampling factor"
        case .duplicateFrameComponentIndex:
            return "duplicate frame component index"
        case .invalidScanComponentCount:
            return "invalid scan component count"
        case .invalidScanBandRange:
            return "invalid scan band range"
        case .invalidScanSuccessiveApproximation:
            return "invalid scan successive approximation"
        case .invalidArithmeticConditioning:
            return "invalid arithmetic conditioning"
        case .invalidPredictor:
            return "invalid predictor"
        case .invalidHuffmanTargetCode:
            return "invalid huffman table destination"
        case .invalidHuffmanTypeCode:
            return "invalid huffman table class"
        case .invalidHuffmanTable:
            return "invalid huffman table"
        case .invalidQuantizationTargetCode:
            return "invalid quantization table destination"
        case .invalidQuantizationPrecisionCode:
            return "invalid quantization table precision"
        }
    }

    public var details: String? {
        switch self {
        case .truncatedMarkerSegmentBody(let marker, count: let count, expected: let expected):
            if expected.count == 1 {
                return "\(marker) segment body is \(count) byte(s), expected \(expected.lowerBound)"
            } else {
                return """
                    \(marker) segment body is \(count) byte(s), expected \
                    \(expected.lowerBound) ... \(expected.upperBound)
                    """
            }
        case .invalidFramePrecision(let precision, let process):
            return "\(precision)-bit precision is not valid for the \(process) process"
        case .invalidFrameComponentCount(let count, let process):
            return "\(count) component(s) is not valid for the \(process) process"
        case .invalidFrameWidth(let width):
            return "frame width (\(width)) must be positive"
        case .invalidFrameSamplingFactor(x: let x, y: let y, let component):
            return "sampling factor (\(x), \(y)) for component \(component) must lie in 1 ... 4"
        case .duplicateFrameComponentIndex(let component):
            return "component \(component) appears more than once in the frame header"
        case .invalidScanComponentCount(let count):
            return "scan component count (\(count)) must lie in 1 ... 4"
        case .invalidScanBandRange(let band, let process):
            return "spectral band \(band) is not valid for the \(process) process"
        case .invalidScanSuccessiveApproximation(high: let high, low: let low):
            return "successive approximation (high: \(high), low: \(low)) must refine by one bit"
        case .invalidArithmeticConditioning(lower: let lower, upper: let upper):
            return "conditioning bounds (\(lower), \(upper)) are not a valid range"
        case .invalidPredictor(let value):
            return "predictor selection value (\(value)) must lie in 1 ... 7"
        case .invalidHuffmanTargetCode(let code):
            return "huffman table destination (\(code)) must lie in 0 ... 3"
        case .invalidHuffmanTypeCode(let code):
            return "huffman table class (\(code)) must be 0 (DC) or 1 (AC)"
        case .invalidHuffmanTable:
            return "huffman code lengths do not describe a prefix-free code"
        case .invalidQuantizationTargetCode(let code):
            return "quantization table destination (\(code)) must lie in 0 ... 3"
        case .invalidQuantizationPrecisionCode(let code):
            return "quantization table precision (\(code)) must be 0 (8-bit) or 1 (16-bit)"
        }
    }
}

extension JPEG {
    /// An error thrown while decoding, when individually valid segments
    /// contradict one another.
    public enum DecodingError: JPEG.Error {
        /// A segment that requires a preceding frame header appeared without
        /// one.
        case missingFrameHeader
        /// A scan header appeared without a preceding frame header, or a second
        /// frame header appeared in a non-hierarchical stream.
        case duplicateFrameHeader
        /// A scan referenced a component the frame header did not declare.
        case undefinedScanComponentReference(JPEG.Component.Key, Set<JPEG.Component.Key>)
        /// The color format did not recognize the frame's component set.
        ///
        /// Only reachable with a custom ``JPEG/Format``. The built-in format
        /// falls back to a nonconforming case rather than failing.
        case unrecognizedColorFormat(Set<JPEG.Component.Key>, precision: Int)
        /// A scan referenced a Huffman table slot that had not been defined.
        case undefinedScanHuffmanTableReference(JPEG.Table.Huffman.Key)
        /// A scan referenced a quantization table slot that had not been
        /// defined.
        case undefinedScanQuantizationTableReference(JPEG.Table.Quantization.Key)

        /// Entropy coded data contained a Huffman code that is not in the
        /// referenced table.
        case invalidEntropyCodedSymbol
        /// A restart marker appeared with the wrong phase, or failed to appear
        /// where the restart interval required one.
        case invalidRestartPhase(Int, expected: Int)
        /// The scan ended before every MCU had been decoded.
        case truncatedEntropyCodedSegment(decoded: Int, expected: Int)

        /// The coding process is recognized but not implemented.
        ///
        /// Distinguished from a malformed stream so that callers can tell "this
        /// file is broken" from "this file is fine, but this library cannot
        /// read it yet".
        case unsupportedProcess(JPEG.Process)
    }
}

extension JPEG.DecodingError {
    public static var namespace: String {
        "decoding error"
    }

    public var message: String {
        switch self {
        case .missingFrameHeader:
            return "missing frame header"
        case .duplicateFrameHeader:
            return "duplicate frame header"
        case .undefinedScanComponentReference:
            return "undefined scan component reference"
        case .unrecognizedColorFormat:
            return "unrecognized color format"
        case .undefinedScanHuffmanTableReference:
            return "undefined huffman table reference"
        case .undefinedScanQuantizationTableReference:
            return "undefined quantization table reference"
        case .invalidEntropyCodedSymbol:
            return "invalid entropy coded symbol"
        case .invalidRestartPhase:
            return "invalid restart phase"
        case .truncatedEntropyCodedSegment:
            return "truncated entropy coded segment"
        case .unsupportedProcess:
            return "unsupported coding process"
        }
    }

    public var details: String? {
        switch self {
        case .missingFrameHeader:
            return "encountered a scan or table segment before any frame header"
        case .duplicateFrameHeader:
            return "encountered a second frame header in a non-hierarchical stream"
        case .undefinedScanComponentReference(let component, let defined):
            return """
                scan references component \(component), which the frame header did not \
                declare (declared: \(defined.sorted(by: { $0.value < $1.value })))
                """
        case .unrecognizedColorFormat(let components, precision: let precision):
            return """
                the color format does not recognize \(components.count) component(s) \
                (\(components.sorted(by: { $0.value < $1.value }))) at \(precision)-bit precision
                """
        case .undefinedScanHuffmanTableReference(let key):
            return "scan references huffman table \(key), which has not been defined"
        case .undefinedScanQuantizationTableReference(let key):
            return "scan references quantization table \(key), which has not been defined"
        case .invalidEntropyCodedSymbol:
            return "entropy coded data contains a code absent from the referenced table"
        case .invalidRestartPhase(let phase, expected: let expected):
            return "restart marker has phase \(phase), expected \(expected)"
        case .truncatedEntropyCodedSegment(decoded: let decoded, expected: let expected):
            return "decoded \(decoded) of \(expected) minimum coded unit(s) before the scan ended"
        case .unsupportedProcess(let process):
            return "the \(process) process is not implemented"
        }
    }
}

extension JPEG {
    /// An error thrown while encoding.
    ///
    /// Encoding fails on what the caller asked for, not on what a file
    /// contained, so these describe an unsatisfiable request rather than
    /// malformed input.
    public enum EncodingError: JPEG.Error {
        /// The image is larger than a frame header can describe.
        ///
        /// Both dimensions are 16-bit fields, so 65535 is the hard ceiling.
        case imageTooLarge(width: Int, height: Int)
        /// The requested coding process has no encoder.
        case unsupportedProcess(JPEG.Process)
        /// The requested sample precision has no encoder.
        case unsupportedPrecision(Int)
        /// A component named a quantization table that was never supplied.
        case undefinedQuantizationTable(JPEG.Table.Quantization.Key)
        /// A scan named a Huffman table that was never supplied.
        case undefinedHuffmanTable(JPEG.Table.Huffman.Key, JPEG.Table.Huffman.Class)
        /// A Huffman table assigns no code to a symbol the data requires.
        ///
        /// The sample tables of T.81 Annex K cover the magnitude categories
        /// 8-bit samples produce and no more, so 12-bit data needs tables built
        /// from its own statistics.
        case unencodableSymbol(UInt8)
        /// A coefficient did not fit in the 16 magnitude categories T.81
        /// defines.
        ///
        /// Reachable only from a hand-built spectral image, since anything this
        /// library quantizes is in range by construction.
        case coefficientOutOfRange(Int)
    }
}

extension JPEG.EncodingError {
    public static var namespace: String {
        "encoding error"
    }

    public var message: String {
        switch self {
        case .imageTooLarge:
            return "image too large"
        case .unsupportedProcess:
            return "unsupported coding process"
        case .unsupportedPrecision:
            return "unsupported sample precision"
        case .undefinedQuantizationTable:
            return "undefined quantization table"
        case .undefinedHuffmanTable:
            return "undefined huffman table"
        case .unencodableSymbol:
            return "unencodable symbol"
        case .coefficientOutOfRange:
            return "coefficient out of range"
        }
    }

    public var details: String? {
        switch self {
        case .imageTooLarge(width: let width, height: let height):
            return "\(width) x \(height) exceeds the 65535 a frame header can encode"
        case .unsupportedProcess(let process):
            return "no encoder for the \(process) process"
        case .unsupportedPrecision(let precision):
            return "no encoder for \(precision)-bit samples"
        case .undefinedQuantizationTable(let key):
            return "a component references quantization table \(key), which was not supplied"
        case .undefinedHuffmanTable(let key, let `class`):
            return "a scan references \(`class`) huffman table \(key), which was not supplied"
        case .unencodableSymbol(let symbol):
            return "the huffman table assigns no code to symbol \(symbol)"
        case .coefficientOutOfRange(let value):
            return "coefficient \(value) exceeds the largest magnitude category T.81 defines"
        }
    }
}
