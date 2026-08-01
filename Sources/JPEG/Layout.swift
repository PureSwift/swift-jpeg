extension JPEG {
    /// The geometry and component structure of an image.
    ///
    /// Where a ``Header/Frame`` is one segment parsed in isolation, a layout is
    /// that header reconciled with a color format: components mapped to planes,
    /// sampling factors resolved into actual block counts, and scans checked
    /// against what the frame declared.
    public struct Layout<Format> where Format: JPEG.Format {
        /// The color format.
        public let format: Format
        /// The coding process.
        public let process: JPEG.Process
        /// The image width, in samples.
        public let width: Int
        /// The image height, in samples.
        ///
        /// Settable within the module because a stream may declare zero here
        /// and supply the real height later in a `DNL` segment.
        public internal(set) var height: Int

        /// The component descriptors, in plane order.
        public let planes: [JPEG.Component]
        /// The component identifiers, in plane order.
        public let keys: [JPEG.Component.Key]
        /// Maps a component identifier to its plane index.
        public let residents: [JPEG.Component.Key: Int]

        /// The largest sampling factors in the frame.
        ///
        /// Sampling is relative, so these are the denominators every component's
        /// resolution is expressed against, and they set the size of a minimum
        /// coded unit.
        public let scale: JPEG.Component.Sampling
    }
}

extension JPEG.Layout {
    /// Rounds `numerator / denominator` up. Both must be positive.
    private static func ceil(_ numerator: Int, _ denominator: Int) -> Int {
        (numerator + denominator - 1) / denominator
    }

    /// Builds a layout from a frame header.
    ///
    /// Components the format omits are dropped rather than decoded, which is
    /// how a caller asks for luminance only from a color image.
    public init(frame: JPEG.Header.Frame) throws {
        guard
        let format: Format = Format.recognize(
            .init(frame.components.keys),
            precision: frame.precision
        )
        else {
            throw JPEG.DecodingError.unrecognizedColorFormat(
                .init(frame.components.keys),
                precision: frame.precision
            )
        }

        let keys: [JPEG.Component.Key] = format.components
        var planes: [JPEG.Component] = []
        var residents: [JPEG.Component.Key: Int] = [:]
        planes.reserveCapacity(keys.count)

        for (plane, key): (Int, JPEG.Component.Key) in keys.enumerated() {
            guard let component: JPEG.Component = frame.components[key] else {
                throw JPEG.DecodingError.undefinedScanComponentReference(
                    key,
                    .init(frame.components.keys)
                )
            }
            planes.append(component)
            residents[key] = plane
        }

        // The maximum is taken over *every* component in the frame, including
        // ones the format dropped. Sampling is relative to the frame, so
        // ignoring a dropped component would silently rescale the rest.
        let scale: JPEG.Component.Sampling = .init(
            x: frame.components.values.map(\.sampling.x).max() ?? 1,
            y: frame.components.values.map(\.sampling.y).max() ?? 1
        )

        self.format = format
        self.process = frame.process
        self.width = frame.width
        self.height = frame.height
        self.planes = planes
        self.keys = keys
        self.residents = residents
        self.scale = scale
    }
}

extension JPEG.Layout {
    /// The number of minimum coded units spanning the image.
    ///
    /// An MCU is `8 * scale.x` by `8 * scale.y` samples, and the image is
    /// padded up to a whole number of them. The padding is real data in the
    /// stream — it must be decoded and then discarded, not skipped.
    public var mcus: (x: Int, y: Int) {
        (
            x: Self.ceil(self.width, 8 * self.scale.x),
            y: Self.ceil(self.height, 8 * self.scale.y)
        )
    }

    /// The resolution of the given plane, in samples.
    ///
    /// A component sampled at `(1, 1)` against a maximum of `(2, 2)` occupies a
    /// quarter of the frame's samples, rounded up.
    public func samples(plane: Int) -> (x: Int, y: Int) {
        let sampling: JPEG.Component.Sampling = self.planes[plane].sampling
        return (
            x: Self.ceil(self.width * sampling.x, self.scale.x),
            y: Self.ceil(self.height * sampling.y, self.scale.y)
        )
    }

    /// The number of 8×8 blocks allocated for the given plane.
    ///
    /// Sized for an interleaved scan, which pads each plane out to a whole
    /// number of MCUs. This is the larger of the two possible block counts — a
    /// non-interleaved scan of the same plane covers ``blocks(plane:scan:)``,
    /// which can be smaller — so allocating this much means either scan type
    /// fits without reallocation.
    public func blocks(plane: Int) -> (x: Int, y: Int) {
        let sampling: JPEG.Component.Sampling = self.planes[plane].sampling
        let mcus: (x: Int, y: Int) = self.mcus
        return (x: mcus.x * sampling.x, y: mcus.y * sampling.y)
    }

    /// The number of 8×8 blocks a scan actually codes for the given plane.
    ///
    /// The two cases differ, and conflating them is a classic source of
    /// misdecoded edges. An interleaved scan codes whole MCUs, so it covers the
    /// padded ``blocks(plane:)`` count. A scan with a single component has no
    /// MCU interleaving to respect — its MCU *is* one block — so it codes only
    /// the blocks the component's own resolution requires, which for a
    /// subsampled component is often fewer.
    ///
    /// -   Parameter scan:
    ///     The scan header, used only for its component count.
    public func blocks(plane: Int, scan: JPEG.Header.Scan) -> (x: Int, y: Int) {
        guard scan.components.count > 1 else {
            let samples: (x: Int, y: Int) = self.samples(plane: plane)
            return (x: Self.ceil(samples.x, 8), y: Self.ceil(samples.y, 8))
        }
        return self.blocks(plane: plane)
    }

    /// Resolves a scan's component references to plane indices.
    ///
    /// -   Returns:
    ///     One plane index per scan component, in the scan's interleave order.
    public func validate(scan: JPEG.Header.Scan) throws -> [Int] {
        try scan.components.map {
            guard let plane: Int = self.residents[$0.component] else {
                throw JPEG.DecodingError.undefinedScanComponentReference(
                    $0.component,
                    .init(self.residents.keys)
                )
            }
            return plane
        }
    }
}
