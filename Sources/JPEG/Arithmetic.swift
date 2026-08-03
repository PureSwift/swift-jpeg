extension JPEG {
    /// The arithmetic entropy coder of T.81 Annex D.
    ///
    /// The standard's other option, and the one nobody uses. It compresses
    /// about 5 to 10 percent better than Huffman coding for the same image, and
    /// was encumbered by patents for long enough that essentially no encoder
    /// emits it and many decoders never learned to read it.
    ///
    /// It is a *binary* arithmetic coder: every decision — is this coefficient
    /// zero, is it negative, is its magnitude larger than one — is coded as a
    /// single bit against an adaptive probability estimate. There are no
    /// symbols and no code table. Instead each decision has a context, and each
    /// context carries a state index into the estimation machine below, which
    /// walks toward whatever that particular decision actually turns out to do.
    public enum Arithmetic {
        /// A state of the probability estimation machine, T.81 Table D.2.
        ///
        /// `qe` is the estimated probability of the less probable symbol, in
        /// 16-bit fixed point. The two indices say where to move after coding
        /// each kind of symbol, and `exchange` marks the states where observing
        /// the less probable symbol is evidence that the two have swapped
        /// roles — which is how the estimator recovers when its guess about
        /// which symbol is more likely was simply wrong.
        typealias State = (qe: Int32, lps: Int, mps: Int, exchange: Bool)

        /// Transcribed rather than derived: the values come from a
        /// Bayesian estimation procedure the standard does not publish, so this
        /// table *is* the specification.
        static let states: [State] = [
        (qe: 0x5A1D, lps:   1, mps:   1, exchange: true ),
        (qe: 0x2586, lps:  14, mps:   2, exchange: false),
        (qe: 0x1114, lps:  16, mps:   3, exchange: false),
        (qe: 0x080B, lps:  18, mps:   4, exchange: false),
        (qe: 0x03D8, lps:  20, mps:   5, exchange: false),
        (qe: 0x01DA, lps:  23, mps:   6, exchange: false),
        (qe: 0x00E5, lps:  25, mps:   7, exchange: false),
        (qe: 0x006F, lps:  28, mps:   8, exchange: false),
        (qe: 0x0036, lps:  30, mps:   9, exchange: false),
        (qe: 0x001A, lps:  33, mps:  10, exchange: false),
        (qe: 0x000D, lps:  35, mps:  11, exchange: false),
        (qe: 0x0006, lps:   9, mps:  12, exchange: false),
        (qe: 0x0003, lps:  10, mps:  13, exchange: false),
        (qe: 0x0001, lps:  12, mps:  13, exchange: false),
        (qe: 0x5A7F, lps:  15, mps:  15, exchange: true ),
        (qe: 0x3F25, lps:  36, mps:  16, exchange: false),
        (qe: 0x2CF2, lps:  38, mps:  17, exchange: false),
        (qe: 0x207C, lps:  39, mps:  18, exchange: false),
        (qe: 0x17B9, lps:  40, mps:  19, exchange: false),
        (qe: 0x1182, lps:  42, mps:  20, exchange: false),
        (qe: 0x0CEF, lps:  43, mps:  21, exchange: false),
        (qe: 0x09A1, lps:  45, mps:  22, exchange: false),
        (qe: 0x072F, lps:  46, mps:  23, exchange: false),
        (qe: 0x055C, lps:  48, mps:  24, exchange: false),
        (qe: 0x0406, lps:  49, mps:  25, exchange: false),
        (qe: 0x0303, lps:  51, mps:  26, exchange: false),
        (qe: 0x0240, lps:  52, mps:  27, exchange: false),
        (qe: 0x01B1, lps:  54, mps:  28, exchange: false),
        (qe: 0x0144, lps:  56, mps:  29, exchange: false),
        (qe: 0x00F5, lps:  57, mps:  30, exchange: false),
        (qe: 0x00B7, lps:  59, mps:  31, exchange: false),
        (qe: 0x008A, lps:  60, mps:  32, exchange: false),
        (qe: 0x0068, lps:  62, mps:  33, exchange: false),
        (qe: 0x004E, lps:  63, mps:  34, exchange: false),
        (qe: 0x003B, lps:  32, mps:  35, exchange: false),
        (qe: 0x002C, lps:  33, mps:   9, exchange: false),
        (qe: 0x5AE1, lps:  37, mps:  37, exchange: true ),
        (qe: 0x484C, lps:  64, mps:  38, exchange: false),
        (qe: 0x3A0D, lps:  65, mps:  39, exchange: false),
        (qe: 0x2EF1, lps:  67, mps:  40, exchange: false),
        (qe: 0x261F, lps:  68, mps:  41, exchange: false),
        (qe: 0x1F33, lps:  69, mps:  42, exchange: false),
        (qe: 0x19A8, lps:  70, mps:  43, exchange: false),
        (qe: 0x1518, lps:  72, mps:  44, exchange: false),
        (qe: 0x1177, lps:  73, mps:  45, exchange: false),
        (qe: 0x0E74, lps:  74, mps:  46, exchange: false),
        (qe: 0x0BFB, lps:  75, mps:  47, exchange: false),
        (qe: 0x09F8, lps:  77, mps:  48, exchange: false),
        (qe: 0x0861, lps:  78, mps:  49, exchange: false),
        (qe: 0x0706, lps:  79, mps:  50, exchange: false),
        (qe: 0x05CD, lps:  48, mps:  51, exchange: false),
        (qe: 0x04DE, lps:  50, mps:  52, exchange: false),
        (qe: 0x040F, lps:  50, mps:  53, exchange: false),
        (qe: 0x0363, lps:  51, mps:  54, exchange: false),
        (qe: 0x02D4, lps:  52, mps:  55, exchange: false),
        (qe: 0x025C, lps:  53, mps:  56, exchange: false),
        (qe: 0x01F8, lps:  54, mps:  57, exchange: false),
        (qe: 0x01A4, lps:  55, mps:  58, exchange: false),
        (qe: 0x0160, lps:  56, mps:  59, exchange: false),
        (qe: 0x0125, lps:  57, mps:  60, exchange: false),
        (qe: 0x00F6, lps:  58, mps:  61, exchange: false),
        (qe: 0x00CB, lps:  59, mps:  62, exchange: false),
        (qe: 0x00AB, lps:  61, mps:  63, exchange: false),
        (qe: 0x008F, lps:  61, mps:  32, exchange: false),
        (qe: 0x5B12, lps:  65, mps:  65, exchange: true ),
        (qe: 0x4D04, lps:  80, mps:  66, exchange: false),
        (qe: 0x412C, lps:  81, mps:  67, exchange: false),
        (qe: 0x37D8, lps:  82, mps:  68, exchange: false),
        (qe: 0x2FE8, lps:  83, mps:  69, exchange: false),
        (qe: 0x293C, lps:  84, mps:  70, exchange: false),
        (qe: 0x2379, lps:  86, mps:  71, exchange: false),
        (qe: 0x1EDF, lps:  87, mps:  72, exchange: false),
        (qe: 0x1AA9, lps:  87, mps:  73, exchange: false),
        (qe: 0x174E, lps:  72, mps:  74, exchange: false),
        (qe: 0x1424, lps:  72, mps:  75, exchange: false),
        (qe: 0x119C, lps:  74, mps:  76, exchange: false),
        (qe: 0x0F6B, lps:  74, mps:  77, exchange: false),
        (qe: 0x0D51, lps:  75, mps:  78, exchange: false),
        (qe: 0x0BB6, lps:  77, mps:  79, exchange: false),
        (qe: 0x0A40, lps:  77, mps:  48, exchange: false),
        (qe: 0x5832, lps:  80, mps:  81, exchange: true ),
        (qe: 0x4D1C, lps:  88, mps:  82, exchange: false),
        (qe: 0x438E, lps:  89, mps:  83, exchange: false),
        (qe: 0x3BDD, lps:  90, mps:  84, exchange: false),
        (qe: 0x34EE, lps:  91, mps:  85, exchange: false),
        (qe: 0x2EAE, lps:  92, mps:  86, exchange: false),
        (qe: 0x299A, lps:  93, mps:  87, exchange: false),
        (qe: 0x2516, lps:  86, mps:  71, exchange: false),
        (qe: 0x5570, lps:  88, mps:  89, exchange: true ),
        (qe: 0x4CA9, lps:  95, mps:  90, exchange: false),
        (qe: 0x44D9, lps:  96, mps:  91, exchange: false),
        (qe: 0x3E22, lps:  97, mps:  92, exchange: false),
        (qe: 0x3824, lps:  99, mps:  93, exchange: false),
        (qe: 0x32B4, lps:  99, mps:  94, exchange: false),
        (qe: 0x2E17, lps:  93, mps:  86, exchange: false),
        (qe: 0x56A8, lps:  95, mps:  96, exchange: true ),
        (qe: 0x4F46, lps: 101, mps:  97, exchange: false),
        (qe: 0x47E5, lps: 102, mps:  98, exchange: false),
        (qe: 0x41CF, lps: 103, mps:  99, exchange: false),
        (qe: 0x3C3D, lps: 104, mps: 100, exchange: false),
        (qe: 0x375E, lps:  99, mps:  93, exchange: false),
        (qe: 0x5231, lps: 105, mps: 102, exchange: false),
        (qe: 0x4C0F, lps: 106, mps: 103, exchange: false),
        (qe: 0x4639, lps: 107, mps: 104, exchange: false),
        (qe: 0x415E, lps: 103, mps:  99, exchange: false),
        (qe: 0x5627, lps: 105, mps: 106, exchange: true ),
        (qe: 0x50E7, lps: 108, mps: 107, exchange: false),
        (qe: 0x4B85, lps: 109, mps: 103, exchange: false),
        (qe: 0x5597, lps: 110, mps: 109, exchange: false),
        (qe: 0x504F, lps: 111, mps: 107, exchange: false),
        (qe: 0x5A10, lps: 110, mps: 111, exchange: true ),
        (qe: 0x5522, lps: 112, mps: 109, exchange: false),
        (qe: 0x59EB, lps: 112, mps: 111, exchange: true ),
        (qe: 0x5A1D, lps: 113, mps: 113, exchange: false),
        ]
    }
}

extension JPEG.Arithmetic {
    /// One adaptive decision context.
    ///
    /// The index into ``states`` and which symbol is currently the more
    /// probable, packed as the standard packs them: the high bit is the sense,
    /// the low seven the state.
    public typealias Context = UInt8
}

extension JPEG.Arithmetic {
    /// The conditioning parameters a `DAC` segment supplies.
    ///
    /// Arithmetic coding has no code tables, but it does have these: three
    /// small numbers that tell the coder how to bucket its decisions. They are
    /// the reason a `DAC` segment exists at all, and their defaults are what
    /// almost every arithmetic-coded JPEG uses.
    public struct Conditioning: Sendable, Hashable {
        /// The lower magnitude bound for DC context selection.
        public var lower: Int
        /// The upper magnitude bound for DC context selection.
        public var upper: Int
        /// The coefficient index above which AC magnitudes use a second
        /// context block.
        public var kx: Int

        /// T.81's defaults, used when no `DAC` segment says otherwise.
        public init(lower: Int = 0, upper: Int = 1, kx: Int = 5) {
            self.lower = lower
            self.upper = upper
            self.kx = kx
        }
    }

    /// The conditioning in effect, by table slot.
    public struct Conditioners: Sendable {
        public var dc: [JPEG.Table.Huffman.Key: Conditioning]
        public var ac: [JPEG.Table.Huffman.Key: Conditioning]

        public init() {
            self.dc = [:]
            self.ac = [:]
        }

        public func dc(_ key: JPEG.Table.Huffman.Key) -> Conditioning {
            self.dc[key] ?? .init()
        }

        public func ac(_ key: JPEG.Table.Huffman.Key) -> Conditioning {
            self.ac[key] ?? .init()
        }

        /// Parses the body of a `DAC` segment.
        ///
        /// Each entry is a class-and-slot byte followed by one value byte. For
        /// a DC table that value packs both bounds, four bits each; for an AC
        /// table it is the single index.
        public static func parse(_ data: [UInt8]) throws -> [(
            class: JPEG.Table.Huffman.Class,
            target: JPEG.Table.Huffman.Key,
            conditioning: Conditioning
        )] {
            guard data.count % 2 == 0 else {
                throw JPEG.ParsingError.truncatedMarkerSegmentBody(
                    .arithmeticCodingCondition,
                    count: data.count,
                    expected: (data.count + 1) ... (data.count + 1)
                )
            }

            var entries: [(
                class: JPEG.Table.Huffman.Class,
                target: JPEG.Table.Huffman.Key,
                conditioning: Conditioning
            )] = []

            for base: Int in stride(from: 0, to: data.count, by: 2) {
                let `class`: JPEG.Table.Huffman.Class
                switch data[base] >> 4 {
                case 0:     `class` = .dc
                case 1:     `class` = .ac
                default:    throw JPEG.ParsingError.invalidHuffmanTypeCode(data[base] >> 4)
                }
                let slot: UInt8 = data[base] & 0x0F
                guard slot < 4 else {
                    throw JPEG.ParsingError.invalidHuffmanTargetCode(slot)
                }

                let value: UInt8 = data[base + 1]
                let conditioning: Conditioning
                switch `class` {
                case .dc:
                    let lower: Int = .init(value & 0x0F)
                    let upper: Int = .init(value >> 4)
                    guard lower <= upper else {
                        throw JPEG.ParsingError.invalidArithmeticConditioning(
                            lower: lower, upper: upper
                        )
                    }
                    conditioning = .init(lower: lower, upper: upper)
                case .ac:
                    guard 1 ... 63 ~= Int(value) else {
                        throw JPEG.ParsingError.invalidArithmeticConditioning(
                            lower: .init(value), upper: .init(value)
                        )
                    }
                    conditioning = .init(kx: .init(value))
                }

                entries.append((class: `class`, target: .init(.init(slot)), conditioning: conditioning))
            }

            return entries
        }
    }
}
