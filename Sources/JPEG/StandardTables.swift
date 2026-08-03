extension JPEG.Table.Quantization {
    /// Which of the two sample tables of T.81 Annex K a table is based on.
    public enum Standard: Sendable, Hashable {
        /// The luminance table, K.1.
        case luminance
        /// The chrominance table, K.2. Coarser at high frequencies, because the
        /// eye resolves color detail less finely than brightness.
        case chrominance
    }

    /// The sample quantization tables of T.81 Annex K, row-major.
    ///
    /// The standard presents these as producing "good" quality as given, and
    /// "very good" when halved. They are not normative — an encoder may use any
    /// table it likes — but they are what essentially every encoder starts
    /// from, so matching them is what makes output comparable.
    static func base(_ standard: Standard) -> [UInt16] {
        switch standard {
        case .luminance:
            return [
          16,   11,   10,   16,   24,   40,   51,   61,
          12,   12,   14,   19,   26,   58,   60,   55,
          14,   13,   16,   24,   40,   57,   69,   56,
          14,   17,   22,   29,   51,   87,   80,   62,
          18,   22,   37,   56,   68,  109,  103,   77,
          24,   35,   55,   64,   81,  104,  113,   92,
          49,   64,   78,   87,  103,  121,  120,  101,
          72,   92,   95,   98,  112,  100,  103,   99,
            ]
        case .chrominance:
            return [
          17,   18,   24,   47,   99,   99,   99,   99,
          18,   21,   26,   66,   99,   99,   99,   99,
          24,   26,   56,   99,   99,   99,   99,   99,
          47,   66,   99,   99,   99,   99,   99,   99,
          99,   99,   99,   99,   99,   99,   99,   99,
          99,   99,   99,   99,   99,   99,   99,   99,
          99,   99,   99,   99,   99,   99,   99,   99,
          99,   99,   99,   99,   99,   99,   99,   99,
            ]
        }
    }
}

extension JPEG.Table.Huffman {
    /// Which of the four sample Huffman tables of T.81 Annex K to use.
    public enum Standard: Sendable, Hashable {
        /// The luminance tables, K.3 and K.5.
        case luminance
        /// The chrominance tables, K.4 and K.6.
        case chrominance
    }

    /// The per-length code counts and symbol lists of T.81 Annex K.
    ///
    /// These leave the code space slightly underfull rather than exactly full,
    /// which is deliberate in the standard: the all-ones code is left
    /// unassigned so that a run of set bits cannot decode to a valid symbol.
    static func definition(
        _ standard: Standard,
        class: Class
    ) -> (counts: [Int], values: [UInt8]) {
        switch (standard, `class`) {
        case (.luminance, .dc):
            return (
                counts: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
                values: [
                      0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,
                ]
            )
        case (.luminance, .ac):
            return (
                counts: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125],
                values: [
                      1,   2,   3,   0,   4,  17,   5,  18,  33,  49,  65,   6,
                     19,  81,  97,   7,  34, 113,  20,  50, 129, 145, 161,   8,
                     35,  66, 177, 193,  21,  82, 209, 240,  36,  51,  98, 114,
                    130,   9,  10,  22,  23,  24,  25,  26,  37,  38,  39,  40,
                     41,  42,  52,  53,  54,  55,  56,  57,  58,  67,  68,  69,
                     70,  71,  72,  73,  74,  83,  84,  85,  86,  87,  88,  89,
                     90,  99, 100, 101, 102, 103, 104, 105, 106, 115, 116, 117,
                    118, 119, 120, 121, 122, 131, 132, 133, 134, 135, 136, 137,
                    138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163,
                    164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182,
                    183, 184, 185, 186, 194, 195, 196, 197, 198, 199, 200, 201,
                    202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 225, 226,
                    227, 228, 229, 230, 231, 232, 233, 234, 241, 242, 243, 244,
                    245, 246, 247, 248, 249, 250,
                ]
            )
        case (.chrominance, .dc):
            return (
                counts: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
                values: [
                      0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,
                ]
            )
        case (.chrominance, .ac):
            return (
                counts: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119],
                values: [
                      0,   1,   2,   3,  17,   4,   5,  33,  49,   6,  18,  65,
                     81,   7,  97, 113,  19,  34,  50, 129,   8,  20,  66, 145,
                    161, 177, 193,   9,  35,  51,  82, 240,  21,  98, 114, 209,
                     10,  22,  36,  52, 225,  37, 241,  23,  24,  25,  26,  38,
                     39,  40,  41,  42,  53,  54,  55,  56,  57,  58,  67,  68,
                     69,  70,  71,  72,  73,  74,  83,  84,  85,  86,  87,  88,
                     89,  90,  99, 100, 101, 102, 103, 104, 105, 106, 115, 116,
                    117, 118, 119, 120, 121, 122, 130, 131, 132, 133, 134, 135,
                    136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154,
                    162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180,
                    181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198, 199,
                    200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218,
                    226, 227, 228, 229, 230, 231, 232, 233, 234, 242, 243, 244,
                    245, 246, 247, 248, 249, 250,
                ]
            )
        }
    }
}

extension JPEG.Table.Quantization {
    /// Converts a quality rating into a percentage scaling factor for the base
    /// tables.
    ///
    /// The IJG curve, which is what "quality 85" means in practice everywhere:
    /// 50 uses the base table unscaled, 50 through 100 scale linearly down to
    /// zero, and 1 through 49 scale as `5000 / quality`. The two halves meet at
    /// 50 but have very different slopes, which is why quality 30 is so much
    /// worse than quality 60 is better.
    ///
    /// -   Parameter quality:
    ///     A rating from 1 through 100. Values outside that range are clamped
    ///     rather than rejected, since every encoder in circulation does the
    ///     same and callers rely on it.
    public static func scaling(quality: Int) -> Int {
        let quality: Int = Swift.min(Swift.max(quality, 1), 100)
        return quality < 50 ? 5000 / quality : 200 - 2 * quality
    }

    /// Builds a quantization table from an Annex K base table at the given
    /// quality.
    ///
    /// -   Parameters:
    ///     -   standard: Which base table to scale.
    ///     -   quality: A rating from 1 through 100.
    ///     -   target: The slot to define the table in.
    ///     -   baseline: Whether the table must fit a baseline frame, which
    ///         cannot carry 16-bit factors. Clamping to 255 costs quality at
    ///         the very lowest settings and is required there; an extended
    ///         sequential frame can carry the full range.
    public static func standard(
        _ standard: Standard,
        quality: Int,
        target: Key,
        baseline: Bool = true
    ) -> Self {
        let scale: Int = Self.scaling(quality: quality)
        let ceiling: Int = baseline ? 255 : 32767

        var wide: Bool = false
        let factors: [UInt16] = Self.base(standard).map {
            // A factor of zero would be a divide by zero on the way back, so
            // the floor is 1 rather than 0.
            let scaled: Int = (.init($0) * scale + 50) / 100
            let clamped: Int = Swift.min(Swift.max(scaled, 1), ceiling)
            if clamped > 255 {
                wide = true
            }
            return .init(clamped)
        }
        return .init(
            factors: factors,
            target: target,
            precision: wide ? .uint16 : .uint8
        )
    }
}

extension JPEG.Table.Huffman {
    /// Builds one of the Annex K sample tables.
    public static func standard(
        _ standard: Standard,
        class: Class,
        target: Key
    ) throws(JPEG.Failure) -> Self {
        let definition: (counts: [Int], values: [UInt8]) = Self.definition(standard, class: `class`)
        return try .init(
            counts: definition.counts,
            values: definition.values,
            target: target,
            class: `class`
        )
    }
}
