import Foundation
import Testing

@testable import JPEG

/// Covers progressive encoding.
///
/// The central claim is that progressive and sequential coding are two
/// packings of the *same* quantized coefficients, so an image written either
/// way must decode to exactly the same samples. That is checked directly, and
/// it is a much sharper test than comparing against the original: it fails on
/// any bit-level mistake rather than only on ones large enough to move a pixel.
struct ProgressiveEncodeTests {
    private static func source(_ name: String) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/\(name)", withExtension: "jpg")
        )
        return try .decompress(.init(try Data(contentsOf: url)))
    }

    private static func scans(in jpeg: [UInt8]) -> Int {
        (0 ..< jpeg.count - 1).count { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA }
    }

    private static func startOfFrame(in jpeg: [UInt8]) -> UInt8? {
        for i: Int in 0 ..< jpeg.count - 1
        where jpeg[i] == 0xFF && 0xC0 ... 0xCF ~= jpeg[i + 1]
            && ![0xC4, 0xC8, 0xCC].contains(jpeg[i + 1])
        {
            return jpeg[i + 1]
        }
        return nil
    }

    @Test(arguments: ["aligned", "full", "gray", "subsampled", "wide"])
    func decodesIdenticallyToSequential(_ name: String) throws {
        let image: JPEG.Data.Rectangular<JPEG.Common> = try Self.source(name)

        var sequential: [UInt8] = []
        try image.compress(stream: &sequential, quality: 90)
        var progressive: [UInt8] = []
        try image.compress(stream: &progressive, quality: 90, progressive: true)

        #expect(Self.startOfFrame(in: progressive) == 0xC2, "\(name) must be SOF2")
        #expect(Self.startOfFrame(in: sequential) == 0xC0)

        let a: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(sequential)
        let b: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(progressive)

        #expect(a.width == b.width && a.height == b.height)
        // Exactly equal, not close. The two encodings carry the same
        // coefficients, so any difference at all is a coding fault.
        #expect(a.values == b.values, "\(name): progressive and sequential decodes differ")
    }

    @Test
    func usesTheExpectedScanCounts() throws {
        // Ten scans for three-component colour and six for grayscale, matching
        // libjpeg's default script. The count is worth pinning: a script that
        // silently lost a scan would still decode, just worse.
        var colour: [UInt8] = []
        try Self.source("subsampled").compress(stream: &colour, quality: 90, progressive: true)
        #expect(Self.scans(in: colour) == 10)

        var gray: [UInt8] = []
        try Self.source("gray").compress(stream: &gray, quality: 90, progressive: true)
        #expect(Self.scans(in: gray) == 6)
    }

    @Test(arguments: ["full", "subsampled", "wide"])
    func isSmallerThanSequential(_ name: String) throws {
        let image: JPEG.Data.Rectangular<JPEG.Common> = try Self.source(name)

        var sequential: [UInt8] = []
        try image.compress(stream: &sequential, quality: 90)
        var progressive: [UInt8] = []
        try image.compress(stream: &progressive, quality: 90, progressive: true)

        // Smaller output is the reason to prefer progressive at all, so a
        // regression that made it larger would defeat the point even while
        // decoding correctly.
        #expect(
            progressive.count < sequential.count,
            "\(name): progressive \(progressive.count) vs sequential \(sequential.count)"
        )
    }

    /// The four progressive procedures, isolated.
    ///
    /// Each script exercises one of them against a baseline the others cannot
    /// mask: with no successive approximation only the first passes run, and
    /// the refinement scripts add exactly one refining stage. Coefficients are
    /// compared rather than pixels, so the check is exact.
    @Test
    func eachProcedureReproducesTheCoefficients() throws {
        let url: URL = try #require(
            Bundle.module.url(forResource: "Images/aligned", withExtension: "jpg")
        )
        let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(
            .init(try Data(contentsOf: url))
        )
        let keys: [JPEG.Component.Key] = spectral.layout.keys

        func dc(_ high: Int, _ low: Int) -> JPEG.Header.Scan {
            .init(
                band: 0 ..< 1,
                bits: low ..< (high == 0 ? Int.max : high),
                components: keys.enumerated().map {
                    let slot: JPEG.Table.Huffman.Key = .init($0.offset == 0 ? 0 : 1)
                    return .init(component: $0.element, dc: slot, ac: slot)
                }
            )
        }
        func ac(_ plane: Int, _ high: Int, _ low: Int) -> JPEG.Header.Scan {
            let slot: JPEG.Table.Huffman.Key = .init(plane == 0 ? 0 : 1)
            return .init(
                band: 1 ..< 64,
                bits: low ..< (high == 0 ? Int.max : high),
                components: [.init(component: keys[plane], dc: slot, ac: slot)]
            )
        }

        let scripts: [(String, [JPEG.Header.Scan])] = [
            ("first passes only", [dc(0, 0)] + keys.indices.map { ac($0, 0, 0) }),
            ("DC refinement", [dc(0, 1), dc(1, 0)] + keys.indices.map { ac($0, 0, 0) }),
            (
                "AC refinement",
                [dc(0, 0)] + keys.indices.map { ac($0, 0, 1) }
                    + keys.indices.map { ac($0, 1, 0) }
            ),
        ]

        for (label, script): (String, [JPEG.Header.Scan]) in scripts {
            let progressive: JPEG.Data.Spectral<JPEG.Common> = try #require(
                spectral.reprocessed(as: .progressive(coding: .huffman, differential: false))
            )

            var stream: [UInt8] = []
            try stream.format(marker: .start)
            for key: JPEG.Table.Quantization.Key in progressive.quanta.keys.sorted() {
                try stream.format(
                    marker: .quantization, body: progressive.quanta[key]!.serialized()
                )
            }
            try stream.format(
                marker: .frame(progressive.layout.process),
                body: try progressive.frame().serialized()
            )
            try progressive.compress(progressive: &stream, restartInterval: 0, script: script)
            try stream.format(marker: .end)

            let decoded: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream)
            var deviation: Int = 0
            for plane: Int in spectral.planes.indices {
                for y: Int in 0 ..< spectral.planes[plane].blocks.y {
                    for x: Int in 0 ..< spectral.planes[plane].blocks.x {
                        let a: [Int16] = spectral.planes[plane].block(x: x, y: y)
                        let b: [Int16] = decoded.planes[plane].block(x: x, y: y)
                        for z: Int in 0 ..< 64 {
                            deviation = max(deviation, abs(.init(a[z]) - .init(b[z])))
                        }
                    }
                }
            }
            #expect(deviation == 0, "\(label): coefficients differ by \(deviation)")
        }
    }
}
