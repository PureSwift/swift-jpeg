import Foundation
import Testing

@testable import JPEG

/// Decodes real baseline JPEGs and compares them against reference decodes.
///
/// The fixtures are all 133×101 — deliberately a multiple of neither 8 nor 16 —
/// so every case exercises MCU padding at the right and bottom edges, which is
/// where a decoder that confuses padded block counts with real ones goes wrong.
///
/// The three sampling modes isolate different parts of the pipeline. Grayscale
/// tests entropy decoding, dequantization and the inverse DCT alone. 4:4:4 adds
/// color conversion. 4:2:0 adds chroma upsampling on top of both, so comparing
/// its error against the other two localizes any regression.
struct DecodeTests {
    /// Reference decodes come from ImageMagick, which decodes through
    /// libjpeg-turbo — the library this one is meant to stand in for.
    ///
    /// The bound is on error, not on equality. T.83 specifies conformance that
    /// way for good reason: implementations round the inverse DCT differently
    /// and are allowed to. A real defect shows up as a large maximum or a
    /// biased mean, never as a scatter of off-by-ones.
    struct Fixture {
        let name: String
        let reference: String
        let channels: Int
        let deviation: Int
        let mean: Double
    }

    static let fixtures: [Fixture] = [
        .init(name: "gray", reference: "gray", channels: 1, deviation: 2, mean: 0.05),
        .init(name: "full", reference: "full", channels: 3, deviation: 4, mean: 0.10),
        // 4:2:0 is held to nearly the same bound as 4:4:4 because upsampling is
        // interpolated rather than replicated. Replication would put the mean
        // above 1.5 and the maximum near 40, so this threshold is what pins
        // that behavior down.
        .init(name: "subsampled", reference: "subsampled", channels: 3, deviation: 4, mean: 0.20),
        // 4:2:2 subsamples horizontally only, so it is the case where an
        // upsampler that confuses its two axes still passes 4:2:0.
        .init(name: "wide", reference: "wide", channels: 3, deviation: 4, mean: 0.20),
        // Restart markers every 3 MCUs. Exercises the DC predictor reset and
        // the phase counter wrapping past 7, which a scan without restarts
        // never touches.
        .init(name: "restarts", reference: "restarts", channels: 3, deviation: 4, mean: 0.20),
        // Progressive: 10 scans for color, 6 for grayscale, so between them
        // they cover DC first and refining and AC first and refining.
        .init(name: "progressive", reference: "progressive", channels: 3, deviation: 4, mean: 0.20),
        .init(
            name: "progressive-gray",
            reference: "progressive-gray",
            channels: 1,
            deviation: 2,
            mean: 0.05
        ),
    ]

    private static func resource(_ name: String, _ ext: String) throws -> [UInt8] {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: ext),
            "missing test resource \(name).\(ext)"
        )
        return .init(try Data(contentsOf: url))
    }

    @Test
    func parsesGeometry() throws {
        var stream: [UInt8] = try Self.resource("subsampled", "jpg")
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        #expect(image.width == 133)
        #expect(image.height == 101)
        #expect(image.layout.process == .baseline)
        #expect(image.layout.format == .ycc(1, 2, 3, precision: 8))
        #expect(image.layout.scale == .init(x: 2, y: 2))
        // 133 wide over 16-sample MCUs is 9 MCUs, covering 144 samples: the
        // last 11 columns are padding that must be decoded and then dropped.
        #expect(image.layout.mcus == (x: 9, y: 7))
    }

    /// Guards against the progressive fixtures silently being regenerated as
    /// baseline, which would leave the whole progressive path untested while
    /// every assertion still passed.
    @Test(arguments: ["progressive", "progressive-gray"])
    func progressiveFixturesAreProgressive(_ name: String) throws {
        var stream: [UInt8] = try Self.resource(name, "jpg")
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        #expect(image.layout.process == .progressive(coding: .huffman, differential: false))
    }

    @Test
    func decodesGrayscaleAsSinglePlane() throws {
        var stream: [UInt8] = try Self.resource("gray", "jpg")
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        #expect(image.stride == 1)
        #expect(image.layout.format == .y(1, precision: 8))
    }

    @Test(arguments: DecodeTests.fixtures)
    func matchesReferenceDecode(_ fixture: Fixture) throws {
        var stream: [UInt8] = try Self.resource(fixture.name, "jpg")
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        let reference: [UInt8] = try Self.resource(
            fixture.reference,
            fixture.channels == 1 ? "gray" : "rgb"
        )
        try #require(reference.count == image.width * image.height * fixture.channels)

        var deviation: Int = 0
        var total: Int = 0

        for y: Int in 0 ..< image.height {
            for x: Int in 0 ..< image.width {
                let samples: [UInt8]
                if fixture.channels == 1 {
                    samples = [.init(image[x: x, y: y, 0])]
                } else {
                    let color: JPEG.RGB = JPEG.YCbCr(
                        y: .init(image[x: x, y: y, 0]),
                        cb: .init(image[x: x, y: y, 1]),
                        cr: .init(image[x: x, y: y, 2])
                    ).rgb
                    samples = [color.r, color.g, color.b]
                }

                let base: Int = (y * image.width + x) * fixture.channels
                for (k, sample): (Int, UInt8) in samples.enumerated() {
                    let error: Int = abs(.init(sample) - .init(reference[base + k]))
                    deviation = max(deviation, error)
                    total += error
                }
            }
        }

        let mean: Double = .init(total) / .init(image.width * image.height * fixture.channels)
        #expect(
            deviation <= fixture.deviation,
            "\(fixture.name): worst-case sample deviation was \(deviation)"
        )
        #expect(mean < fixture.mean, "\(fixture.name): mean absolute deviation was \(mean)")
    }

    @Test
    func unpacksToRGB() throws {
        var stream: [UInt8] = try Self.resource("full", "jpg")
        let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

        #expect(image.unpack(as: JPEG.RGB.self).count == 133 * 101)
        #expect(image.unpack(as: JPEG.YCbCr.self).count == 133 * 101)
    }

    @Test
    func rejectsTruncatedStream() throws {
        let whole: [UInt8] = try Self.resource("gray", "jpg")
        var stream: [UInt8] = .init(whole.prefix(whole.count / 2))

        #expect(throws: (any Error).self) {
            _ = try JPEG.Data.Rectangular<JPEG.Common>.decompress(stream: &stream)
        }
    }

    @Test
    func rejectsNonJPEGInput() throws {
        var stream: [UInt8] = .init("not a jpeg, not even close".utf8)

        #expect(throws: (any Error).self) {
            _ = try JPEG.Data.Rectangular<JPEG.Common>.decompress(stream: &stream)
        }
    }

    /// A plane whose quantization table was never defined decodes to a flat
    /// midpoint rather than failing.
    ///
    /// The documented behavior, and previously unexercised: nothing in the
    /// fixtures omits a table. It matters now because the plane it fills is
    /// no longer zeroed first, so this is the test that proves the midpoint
    /// fill covers every sample — a partial fill would leave uninitialized
    /// memory where zeros used to be.
    @Test
    func undefinedTableDecodesToMidpoint() throws {
        let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(
            try Self.resource("subsampled", "jpg")
        )
        // Take the tables away after decoding the coefficients, so the
        // coefficients are real and only the dequantization has nothing to
        // work with.
        var stripped: JPEG.Data.Spectral<JPEG.Common> = spectral
        stripped.quanta = [:]

        let planar: JPEG.Data.Planar<JPEG.Common> = stripped.decomposed()
        let midpoint: UInt16 = 128
        for plane: Int in planar.planes.indices {
            var count: Int = 0
            planar.planes[plane].withSamples { samples in
                for i: Int in samples.indices where samples[i] != midpoint {
                    count += 1
                }
            }
            #expect(count == 0, "plane \(plane): \(count) samples are not the midpoint")
        }

        // And at a reduced scale, which changes the plane's size.
        let small: JPEG.Data.Planar<JPEG.Common> = stripped.decomposed(scale: 3)
        for plane: Int in small.planes.indices {
            var count: Int = 0
            small.planes[plane].withSamples { samples in
                for i: Int in samples.indices where samples[i] != midpoint {
                    count += 1
                }
            }
            #expect(count == 0, "plane \(plane) at scale 3: \(count) samples are not the midpoint")
        }
    }
}
