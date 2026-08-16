import CTurboJPEG
import JPEG

/// The lossless process, at the C boundary.
///
/// TurboJPEG exposes it through three parameters rather than a separate entry
/// point: `TJPARAM_LOSSLESS` selects it, `TJPARAM_LOSSLESSPSV` picks one of the
/// seven predictors, and `TJPARAM_LOSSLESSPT` sets the point transform.
///
/// It is also the only route to 16-bit samples, since T.81 caps the DCT-based
/// processes at 12 bits and reserves everything wider for this one.

extension Instance {
    /// The coding process a JPEG uses, read from its start-of-frame marker.
    ///
    /// Needed before decoding can begin, because a lossless image takes an
    /// entirely different path — there are no coefficients to produce.
    static func process(of jpeg: [UInt8]) throws -> JPEG.Process? {
        var stream: JPEG.Bytestream.Cursor = .init(jpeg)
        try stream.start()
        while true {
            let (marker, _): (JPEG.Marker, [UInt8]) = try stream.segment()
            switch marker {
            case .frame(let process):   return process
            case .end, .scan:           return nil
            default:                    continue
            }
        }
    }

    /// The predictor the handle selects, defaulting to the one most encoders
    /// use.
    var predictor: JPEG.Predictor {
        .init(rawValue: .init(self.parameter(TJPARAM_LOSSLESSPSV, default: 1))) ?? .horizontal
    }

    /// Decodes a lossless JPEG into the interleaved form the API returns.
    func decodeLossless(
        _ jpegBuf: UnsafePointer<UInt8>,
        _ jpegSize: Int
    ) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        let bytes: [UInt8] = .init(UnsafeBufferPointer(start: jpegBuf, count: jpegSize))
        self.decodedProfile = try? ICCProfile.profile(in: bytes)

        let image: JPEG.Data.Lossless<JPEG.Common> = try .decompress(bytes)

        self.parameters[TJPARAM_JPEGWIDTH.id] = .init(image.layout.width)
        self.parameters[TJPARAM_JPEGHEIGHT.id] = .init(image.layout.height)
        self.parameters[TJPARAM_PRECISION.id] = .init(image.layout.format.precision)
        self.parameters[TJPARAM_SUBSAMP.id] = Subsampling.value(of: image.layout)
        self.parameters[TJPARAM_COLORSPACE.id] = image.layout.planes.count == 1
            ? TJCS_GRAY.rawValue
            : TJCS_RGB.rawValue
        self.parameters[TJPARAM_PROGRESSIVE.id] = 0
        self.parameters[TJPARAM_LOSSLESS.id] = 1
        self.record(density: Instance.jfif(of: image.metadata))

        // Scaling and cropping are meaningless here: a scaled inverse transform
        // needs coefficients, and this process produces none. libjpeg-turbo
        // refuses the combination for the same reason.
        guard self.scalingFactor == (numerator: 1, denominator: 1) else {
            throw Failure.message("cannot scale a lossless image")
        }
        return try self.cropped(image.rectangular())
    }

    /// Encodes samples as a lossless JPEG.
    func compressLossless(
        values: [UInt16],
        width: Int,
        height: Int,
        precision: Int,
        gray: Bool
    ) throws -> [UInt8] {
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            // 'R', 'G', 'B' rather than 1, 2, 3: the components are stored
            // without a colour transform, and those identifiers are how a
            // stream says so. Converting to YCbCr and back costs about one
            // count, which is exactly what this process exists to avoid.
            format: gray
                ? .y(1, precision: precision)
                : .rgb(82, 71, 66, precision: precision),
            process: .lossless(coding: .huffman, differential: false),
            width: width,
            height: height,
            // Subsampling a lossless image throws samples away, which defeats
            // the point, so every component stays at full resolution.
            sampling: .init(repeating: .init(x: 1, y: 1), count: gray ? 1 : 3),
            selectors: .init(repeating: 0, count: gray ? 1 : 3)
        )

        let image: JPEG.Data.Lossless<JPEG.Common> = .init(layout: layout, values: values)
        var encoded: [UInt8] = []
        try image.compress(
            stream: &encoded,
            predictor: self.predictor,
            transform: .init(self.parameter(TJPARAM_LOSSLESSPT, default: 0)),
            metadata: self.iccProfile.map(ICCProfile.segments(of:)) ?? []
        )
        return encoded
    }
}
