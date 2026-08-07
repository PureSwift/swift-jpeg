import Testing

import JPEG

/// The resamplers, against independent transcriptions of what they are defined
/// to compute.
///
/// Both of them have a general path that handles any sampling ratio and a
/// specialized one for the ratios real images use, and the specialized one is
/// only an optimization if it agrees bit for bit — otherwise it is a different
/// filter, silently applied to the majority of images. Neither round-tripping an
/// image nor comparing against a reference decoder would catch a disagreement of
/// one count, which is exactly the size of mistake a hand-unrolled loop makes.
///
/// So these compare against the formulas as the source documents them, written
/// out again here rather than shared with the engine. A test that called into the
/// implementation to compute what the implementation should produce would agree
/// with any bug it contained.
@Suite("Resample")
struct ResampleTests {
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            self.state ^= self.state >> 12
            self.state ^= self.state << 25
            self.state ^= self.state >> 27
            return self.state &* 2685821657736338717
        }
    }

    /// The sampling arrangements worth covering.
    ///
    /// The first four are what encoders emit. `4:1:0` quarters rather than halves
    /// and `3x2` is not a whole ratio at all, so both miss the specialized paths
    /// and check that the general one is still reachable and still right. The
    /// mixed one has a plane at each of two different ratios in the same image,
    /// which is where a fast path keyed on the wrong plane's sampling would show.
    private static let samplings: [(name: String, factors: [JPEG.Component.Sampling])] = [
        ("4:4:4", [.init(x: 1, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("4:2:2", [.init(x: 2, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("4:2:0", [.init(x: 2, y: 2), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("4:4:0", [.init(x: 1, y: 2), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("4:1:0", [.init(x: 4, y: 4), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("3x2", [.init(x: 3, y: 2), .init(x: 1, y: 1), .init(x: 1, y: 1)]),
        ("mixed", [.init(x: 4, y: 2), .init(x: 2, y: 1), .init(x: 1, y: 1)]),
    ]

    /// Sizes chosen so that the specialized loops stop short in different places.
    ///
    /// Where they hand back to the general path depends on the size and the ratio
    /// together, so odd, even, prime and block-aligned widths all have to appear.
    /// A width of one is the degenerate case where there is no interior at all.
    private static let widths: [Int] = [1, 2, 3, 7, 8, 9, 17, 23, 32, 33]
    private static let heights: [Int] = [1, 2, 3, 8, 9, 17]

    private static func layout(
        _ factors: [JPEG.Component.Sampling], _ width: Int, _ height: Int
    ) throws -> JPEG.Layout<JPEG.Common> {
        try .init(
            format: .ycc(1, 2, 3, precision: 8),
            process: .baseline,
            width: width,
            height: height,
            sampling: factors,
            selectors: [0, 1, 1]
        )
    }

    /// The subsampler must be the box filter it documents.
    @Test("subsampling averages its box")
    func subsample() throws {
        var generator: Generator = .init(seed: 0xB0FFE)

        for (name, factors): (String, [JPEG.Component.Sampling]) in Self.samplings {
            for width: Int in Self.widths {
                for height: Int in Self.heights {
                    let layout: JPEG.Layout<JPEG.Common> = try Self.layout(
                        factors, width, height
                    )
                    let values: [UInt16] = (0 ..< width * height * 3).map { _ in
                        .init(truncatingIfNeeded: generator.next() >> 56)
                    }
                    let planar: JPEG.Data.Planar<JPEG.Common> = JPEG.Data.Rectangular(
                        layout: layout, values: values
                    ).subsampled()

                    let scale: JPEG.Component.Sampling = layout.scale
                    for plane: Int in 0 ..< 3 {
                        let sampling: JPEG.Component.Sampling =
                            layout.planes[plane].sampling
                        let blocks: (x: Int, y: Int) = layout.blocks(plane: plane)
                        let extent: (x: Int, y: Int) = layout.samples(plane: plane)

                        for y: Int in 0 ..< blocks.y * 8 {
                            // Samples past the component's own resolution repeat
                            // the edge, which is what the block padding is.
                            let row: Int = min(y, extent.y - 1)
                            let y0: Int = min(row * scale.y / sampling.y, height - 1)
                            let y1: Int = min(
                                max((row + 1) * scale.y / sampling.y, y0 + 1), height
                            )

                            for x: Int in 0 ..< blocks.x * 8 {
                                let column: Int = min(x, extent.x - 1)
                                let x0: Int = column * scale.x / sampling.x
                                let x1: Int = max(
                                    x0 + 1, (column + 1) * scale.x / sampling.x
                                )
                                let start: Int = min(x0, width - 1)
                                let end: Int = min(max(x1, x0 + 1), width)

                                var total: Int = 0
                                var count: Int = 0
                                for sy: Int in y0 ..< y1 {
                                    for sx: Int in start ..< end {
                                        total += .init(
                                            values[(sy * width + sx) * 3 + plane]
                                        )
                                        count += 1
                                    }
                                }

                                let want: UInt16 = .init(
                                    truncatingIfNeeded: (total + count / 2) / count
                                )
                                #expect(
                                    planar[plane][x: x, y: y] == want,
                                    "\(name) \(width)x\(height) plane \(plane) at (\(x), \(y))"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// The upsampler must be the bilinear interpolation it documents.
    @Test("upsampling interpolates bilinearly")
    func upsample() throws {
        var generator: Generator = .init(seed: 0xB111)

        for (name, factors): (String, [JPEG.Component.Sampling]) in Self.samplings {
            for width: Int in Self.widths {
                for height: Int in Self.heights {
                    let layout: JPEG.Layout<JPEG.Common> = try Self.layout(
                        factors, width, height
                    )
                    let values: [UInt16] = (0 ..< width * height * 3).map { _ in
                        .init(truncatingIfNeeded: generator.next() >> 56)
                    }
                    let planar: JPEG.Data.Planar<JPEG.Common> = JPEG.Data.Rectangular(
                        layout: layout, values: values
                    ).subsampled()
                    let interleaved: JPEG.Data.Rectangular<JPEG.Common> =
                        planar.interleaved()

                    let scale: JPEG.Component.Sampling = layout.scale
                    for plane: Int in 0 ..< 3 {
                        let sampling: JPEG.Component.Sampling =
                            layout.planes[plane].sampling

                        for y: Int in 0 ..< height {
                            for x: Int in 0 ..< width {
                                let want: UInt16
                                if sampling.x == scale.x, sampling.y == scale.y {
                                    // A component as dense as the frame is copied
                                    // rather than interpolated: in fixed point the
                                    // interpolation is not quite the identity, and
                                    // the samples are worth keeping exact.
                                    want = planar[plane][x: x, y: y]
                                } else {
                                    want = Self.interpolate(
                                        planar[plane], x, y, sampling, scale
                                    )
                                }
                                #expect(
                                    interleaved[x: x, y: y, plane] == want,
                                    "\(name) \(width)x\(height) plane \(plane) at (\(x), \(y))"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Maps an output coordinate into a plane, in Q16.
    ///
    /// The half-sample terms are what make this an interpolation rather than a
    /// stretch; dropping them shifts chroma by half a pixel.
    private static func position(_ x: Int, _ numerator: Int, _ denominator: Int) -> Int {
        (((2 * x + 1) * numerator) << 16) / (2 * denominator) - (1 << 15)
    }

    private static func interpolate(
        _ plane: JPEG.Data.Planar<JPEG.Common>.Plane,
        _ x: Int,
        _ y: Int,
        _ sampling: JPEG.Component.Sampling,
        _ scale: JPEG.Component.Sampling
    ) -> UInt16 {
        let u: Int = Self.position(x, sampling.x, scale.x)
        let v: Int = Self.position(y, sampling.y, scale.y)
        // Arithmetic shift floors, including for the negative coordinates the
        // half-sample offset produces at the top and left margins, so both
        // fractions stay in 0 ..< 1.
        let column: Int = u >> 16
        let row: Int = v >> 16
        let fx: Int32 = .init(u - (column << 16))
        let fy: Int32 = .init(v - (row << 16))

        // The plane's subscript clamps, which is the edge behaviour the
        // upsampler folds into its column tables.
        let a: Int32 = .init(plane[x: column, y: row])
        let b: Int32 = .init(plane[x: column + 1, y: row])
        let c: Int32 = .init(plane[x: column, y: row + 1])
        let d: Int32 = .init(plane[x: column + 1, y: row + 1])

        let top: Int32 = (a << 8) + (b - a) * (fx >> 8)
        let bottom: Int32 = (c << 8) + (d - c) * (fx >> 8)
        let value: Int64 = (.init(top) << 8)
            + .init(bottom - top) * .init(fy >> 8)
            + (1 << 15)
        return .init(value >> 16)
    }

    /// Resampling a 16-bit image must not trap.
    ///
    /// The vertical stage of the interpolation shifts its accumulator up by
    /// eight, and at 16 bits of precision that pushed bits off the end of a
    /// signed 32-bit value. A shift discards those silently, so the result
    /// wrapped negative and trapped one step later converting to `UInt16` — the
    /// crash pointed at a conversion rather than at the arithmetic that had
    /// already gone wrong. Nothing below 13 bits reaches it.
    ///
    /// The hard edge is the point: the overflow needs the largest possible
    /// difference between neighbouring samples, so a gradient would not do it.
    @Test("16-bit samples do not overflow the interpolation")
    func wide() throws {
        let side: Int = 16
        let layout: JPEG.Layout<JPEG.Common> = try .init(
            format: .ycc(1, 2, 3, precision: 16),
            process: .lossless(coding: .huffman, differential: false),
            width: side,
            height: side,
            sampling: [.init(x: 2, y: 2), .init(x: 1, y: 1), .init(x: 1, y: 1)],
            selectors: [0, 1, 1]
        )

        var values: [UInt16] = []
        for _: Int in 0 ..< side {
            for x: Int in 0 ..< side {
                let sample: UInt16 = (x / 2) & 1 == 0 ? 0 : 65535
                values.append(sample)
                values.append(sample)
                values.append(sample)
            }
        }

        let interleaved: JPEG.Data.Rectangular<JPEG.Common> = JPEG.Data.Rectangular(
            layout: layout, values: values
        ).subsampled().interleaved()

        // Every sample has to be inside the range a 16-bit sample can hold,
        // which is the whole claim: before the fix the arithmetic left the
        // range and the conversion trapped.
        for plane: Int in 0 ..< 3 {
            for y: Int in 0 ..< side {
                for x: Int in 0 ..< side {
                    let sample: UInt16 = interleaved[x: x, y: y, plane]
                    #expect(sample <= 65535, "plane \(plane) at (\(x), \(y))")
                }
            }
        }

        // And the interpolation has to have happened: a hard edge upsampled
        // through a halved plane lands between the two extremes, not on one of
        // them.
        let middle: UInt16 = interleaved[x: 3, y: 3, 1]
        #expect(0 < middle && middle < 65535, "edge did not interpolate: \(middle)")
    }
}
