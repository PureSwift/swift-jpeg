import Foundation
import Testing

@testable import JPEG

/// Covers lossless rotation and reflection at the spectral tier.
///
/// The fixture is 128×96 — a whole number of MCUs at 4:2:0 — so every transform
/// is exact and nothing is trimmed. That matters: on an image that is not MCU
/// aligned, mirroring necessarily drops the partial edge, and a test that did
/// not control for it would be measuring the trim rather than the transform.
struct TransformTests {
    private static func spectral(_ name: String) throws -> JPEG.Data.Spectral<JPEG.Common> {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: "jpg")
        )
        var stream: [UInt8] = .init(try Data(contentsOf: url))
        return try .decompress(stream: &stream)
    }

    /// Compares two images coefficient by coefficient. Transforms are lossless,
    /// so identities among them must hold exactly, not approximately.
    private static func identical(
        _ a: JPEG.Data.Spectral<JPEG.Common>,
        _ b: JPEG.Data.Spectral<JPEG.Common>
    ) -> Bool {
        guard a.layout.width == b.layout.width, a.layout.height == b.layout.height else {
            return false
        }
        for plane: Int in a.planes.indices {
            guard a.planes[plane].blocks == b.planes[plane].blocks else {
                return false
            }
            for y: Int in 0 ..< a.planes[plane].blocks.y {
                for x: Int in 0 ..< a.planes[plane].blocks.x {
                    if a.planes[plane].block(x: x, y: y) != b.planes[plane].block(x: x, y: y) {
                        return false
                    }
                }
            }
        }
        return true
    }

    @Test(arguments: [
        JPEG.Transform.horizontalFlip, .verticalFlip, .rotate180, .transpose, .transverse,
    ])
    func reflectionsAreInvolutions(_ transform: JPEG.Transform) throws {
        let image: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("aligned")
        #expect(Self.identical(image, image.transformed(transform).transformed(transform)))
    }

    @Test
    func rotationsComposeAsAGroup() throws {
        let image: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("aligned")

        var quarter: JPEG.Data.Spectral<JPEG.Common> = image
        for _ in 0 ..< 4 {
            quarter = quarter.transformed(.rotate90)
        }
        #expect(Self.identical(image, quarter), "four quarter turns is the identity")

        #expect(
            Self.identical(image, image.transformed(.rotate90).transformed(.rotate270)),
            "opposite quarter turns cancel"
        )
        #expect(
            Self.identical(
                image.transformed(.rotate90).transformed(.rotate90),
                image.transformed(.rotate180)
            ),
            "two quarter turns is a half turn"
        )
        #expect(
            Self.identical(
                image.transformed(.transpose).transformed(.horizontalFlip),
                image.transformed(.rotate90)
            ),
            "transpose then mirror is a quarter turn"
        )
    }

    /// The pixel-level meaning of each transform.
    ///
    /// Coefficient-level identities alone would not catch a transform that is a
    /// self-consistent but wrong involution, which is exactly the shape the
    /// quantization-table bug had.
    @Test
    func transformsMoveThePixelsTheyClaimTo() throws {
        let image: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("aligned")
        let base: JPEG.Data.Rectangular<JPEG.Common> = image.rectangular()

        let cases: [(JPEG.Transform, (Int, Int) -> (Int, Int), String)] = [
            (.horizontalFlip, { (base.width - 1 - $0, $1) }, "horizontal flip"),
            (.verticalFlip, { ($0, base.height - 1 - $1) }, "vertical flip"),
            (.rotate180, { (base.width - 1 - $0, base.height - 1 - $1) }, "half turn"),
            (.transpose, { ($1, $0) }, "transpose"),
            (.rotate90, { (base.height - 1 - $1, $0) }, "quarter turn clockwise"),
            (.rotate270, { ($1, base.width - 1 - $0) }, "quarter turn anticlockwise"),
            (.transverse, { (base.height - 1 - $1, base.width - 1 - $0) }, "transverse"),
        ]

        for (transform, map, label): (JPEG.Transform, (Int, Int) -> (Int, Int), String) in cases {
            let result: JPEG.Data.Rectangular<JPEG.Common> = image.transformed(transform)
                .rectangular()

            if transform.swapsAxes {
                #expect(result.width == base.height && result.height == base.width, "\(label) size")
            } else {
                #expect(result.width == base.width && result.height == base.height, "\(label) size")
            }

            var deviation: Int = 0
            for y: Int in 0 ..< base.height {
                for x: Int in 0 ..< base.width {
                    let (dx, dy): (Int, Int) = map(x, y)
                    for plane: Int in 0 ..< base.stride {
                        deviation = max(
                            deviation,
                            abs(.init(base[x: x, y: y, plane]) - .init(result[x: dx, y: dy, plane]))
                        )
                    }
                }
            }
            // The transform itself is exact; the only loss is the inverse DCT
            // rounding differently for a rearranged block.
            #expect(deviation <= 2, "\(label): worst-case pixel deviation \(deviation)")
        }
    }

    @Test
    func trimsWhenTheImageIsNotWholeMCUs() throws {
        // 133×101 at 4:4:4 has 8×8 MCUs, so both axes have a partial edge.
        let image: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("full")
        #expect(!image.isPerfect(for: .horizontalFlip))

        let flipped: JPEG.Data.Spectral<JPEG.Common> = image.transformed(.horizontalFlip)
        #expect(flipped.layout.width == 128, "the partial column is dropped, not mirrored")
        #expect(flipped.layout.height == 101, "the untouched axis is left alone")

        // An aligned image loses nothing.
        let aligned: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("aligned")
        #expect(aligned.isPerfect(for: .rotate90))
        #expect(aligned.transformed(.rotate90).layout.width == 96)
    }

    @Test
    func transposingSwapsSamplingFactors() throws {
        // 4:2:2 is luma (2,1); transposed it must become (1,2), which is 4:4:0.
        let image: JPEG.Data.Spectral<JPEG.Common> = try Self.spectral("wide")
        #expect(image.layout.scale == .init(x: 2, y: 1))
        #expect(image.transformed(.transpose).layout.scale == .init(x: 1, y: 2))
    }
}
