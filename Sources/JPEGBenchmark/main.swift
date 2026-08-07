import Foundation
import JPEG
import JPEGAccelerate

// A benchmark that is meant to run on continuous integration, where the machine
// is shared, the load is unknown and the clock is not to be trusted.
//
// Two things follow from that. Timings are minimums over many runs rather than
// means, because background load can only ever make a run slower, so the
// fastest one is the closest estimate of what the code costs. And the check
// that can fail is a *ratio* between two kernels measured in the same process
// moments apart, not an absolute time: a loaded runner slows both of them, so
// the ratio survives what an absolute threshold would not.

// MARK: - timing

func best(_ reps: Int, _ body: () throws -> Void) rethrows -> Double {
    var best: Double = .infinity
    for _ in 0 ..< reps {
        let t0: UInt64 = DispatchTime.now().uptimeNanoseconds
        try body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
    }
    return best
}

func seconds(_ x: Double) -> String {
    String(format: "%.4f s", x)
}

// MARK: - test image

/// Builds a deterministic test image.
///
/// Synthesized rather than read from a fixture so the benchmark is
/// self-contained and the same everywhere. Smooth gradients with some structure
/// and a little noise: a flat image would quantize to almost nothing and
/// measure an entropy coder that never has to work, and pure noise would be
/// nothing like a photograph.
func testImage(side: Int) -> [JPEG.RGB] {
    var state: UInt64 = 0x243F6A8885A308D3
    func noise() -> Int {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Int(truncatingIfNeeded: (state &* 2685821657736338717) >> 56) & 0x1F
    }

    var pixels: [JPEG.RGB] = []
    pixels.reserveCapacity(side * side)
    for y: Int in 0 ..< side {
        for x: Int in 0 ..< side {
            let ring: Int = ((x - side / 2) * (x - side / 2)
                + (y - side / 2) * (y - side / 2)) >> 9
            let r: Int = (x * 255 / side + ring + noise()) & 0xFF
            let g: Int = (y * 255 / side + (ring >> 1) + noise()) & 0xFF
            let b: Int = ((x + y) * 127 / side + noise()) & 0xFF
            pixels.append(.init(UInt8(r), UInt8(g), UInt8(b)))
        }
    }
    return pixels
}

// MARK: - run

let arguments: [String] = CommandLine.arguments
let checking: Bool = arguments.contains("--check")
let side: Int = 1024
let reps: Int = arguments.contains("--quick") ? 5 : 20

let installed: String = JPEG.Accelerate.install()
print("kernels:  \(installed)")
print("cpu:      \(JPEG.Accelerate.features.joined(separator: " "))")
print("image:    \(side)x\(side) 4:2:0")
print("")

let pixels: [JPEG.RGB] = testImage(side: side)
let layout: JPEG.Layout<JPEG.Common> = try .init(
    format: .ycc(1, 2, 3, precision: 8),
    process: .baseline,
    width: side,
    height: side,
    sampling: [.init(x: 2, y: 2), .init(x: 1, y: 1), .init(x: 1, y: 1)],
    selectors: [0, 1, 1]
)

var values: [UInt16] = []
values.reserveCapacity(pixels.count * 3)
for pixel: JPEG.RGB in pixels {
    let color: JPEG.YCbCr = .init(pixel)
    values.append(.init(color.y))
    values.append(.init(color.cb))
    values.append(.init(color.cr))
}
let image: JPEG.Data.Rectangular<JPEG.Common> = .init(layout: layout, values: values)

var encoded: [UInt8] = []
try image.compress(stream: &encoded, quality: 85)
print("encoded:  \(encoded.count) bytes")
print("")

let megapixels: Double = Double(side * side) / 1e6

let encodeTime: Double = try best(reps) {
    var stream: [UInt8] = []
    try image.compress(stream: &stream, quality: 85)
}
let decodeTime: Double = try best(reps) {
    _ = try JPEG.Data.Rectangular<JPEG.Common>.decompress(encoded).unpack(as: JPEG.RGB.self)
}

print("end to end")
print(String(format: "  decode  %@  %6.2f Mpixel/s", seconds(decodeTime), megapixels / decodeTime))
print(String(format: "  encode  %@  %6.2f Mpixel/s", seconds(encodeTime), megapixels / encodeTime))
print("")

// MARK: - kernels

// Measured back to back in one process so a loaded runner affects both alike
// and the ratio between them stays meaningful.

// Distinct blocks streamed from an array, not one block transformed over and
// over. Repeating a single block keeps it in L1 and lets the compiler hoist
// work out of the loop, which flatters the vector kernels by about three times
// — it reports a speedup the real decoder never sees, because the real decoder
// walks a coefficient plane it has never touched.
let blocks: Int = 16384

let coefficients: [Int32] = {
    var all: [Int32] = .init(repeating: 0, count: blocks * 64)
    var state: UInt64 = 0x13198A2E03707344
    for i: Int in 0 ..< blocks {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        let seed: UInt64 = state &* 2685821657736338717
        all[i * 64] = Int32(truncatingIfNeeded: seed % 2048) - 1024
        // A handful of low-frequency coefficients, which is what survives
        // quantization at a normal quality.
        for k: Int in 1 ..< 12 {
            all[i * 64 + ((Int(seed >> UInt64(k * 3)) & 0x1F) | 1)] =
                Int32(truncatingIfNeeded: (seed >> UInt64(k)) % 512) - 256
        }
    }
    return all
}()

let samples: [UInt16] = (0 ..< blocks * 64).map {
    .init(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 6))
}

func timeInverse() -> Double {
    var out: [UInt16] = .init(repeating: 0, count: blocks * 64)
    return out.withUnsafeMutableBufferPointer { out in
        coefficients.withUnsafeBufferPointer { input in
            best(reps) {
                for i: Int in 0 ..< blocks {
                    JPEG.Kernel.inverseTransform(
                        input.baseAddress! + i * 64, 8, out.baseAddress! + i * 64
                    )
                }
            }
        }
    }
}

func timeForward() -> Double {
    var out: [Int32] = .init(repeating: 0, count: blocks * 64)
    return out.withUnsafeMutableBufferPointer { out in
        samples.withUnsafeBufferPointer { input in
            best(reps) {
                for i: Int in 0 ..< blocks {
                    JPEG.Kernel.forwardTransform(
                        input.baseAddress! + i * 64, 8, out.baseAddress! + i * 64
                    )
                }
            }
        }
    }
}

// Colour conversion runs over the whole image rather than a block, and over the
// image's own samples rather than synthesized ones — the arithmetic is
// data-independent, so real samples cost nothing extra to use and rule out a
// synthetic buffer that happened to be friendlier than a photograph.
//
// `values` is a mutable global, and a mutable global is main-actor isolated in a
// script while a top-level function is not, so the samples are rebound to a
// constant. Copy-on-write means that is a retain, not a megapixel.
let ycc: [UInt16] = values
let pixelCount: Int = side * side

func timeColor() -> Double {
    var out: [UInt8] = .init(repeating: 0, count: pixelCount * 3)
    return out.withUnsafeMutableBufferPointer { out in
        ycc.withUnsafeBufferPointer { input in
            best(reps) {
                JPEG.Kernel.colorTransform(
                    input.baseAddress!, pixelCount, 0, out.baseAddress!
                )
            }
        }
    }
}

JPEG.Kernel.reset()
let portableInverse: Double = timeInverse()
let portableForward: Double = timeForward()
let portableColor: Double = timeColor()

JPEG.Accelerate.install()
let accelInverse: Double = timeInverse()
let accelForward: Double = timeForward()
let accelColor: Double = timeColor()

let inverseRatio: Double = portableInverse / accelInverse
let forwardRatio: Double = portableForward / accelForward
let colorRatio: Double = portableColor / accelColor

print("kernels, \(blocks) blocks each")
print(String(format: "  inverse  portable %@  %@ %@  %.2fx",
             seconds(portableInverse), installed, seconds(accelInverse), inverseRatio))
print(String(format: "  forward  portable %@  %@ %@  %.2fx",
             seconds(portableForward), installed, seconds(accelForward), forwardRatio))
print(String(format: "  color    portable %@  %@ %@  %.2fx  (%d pixels)",
             seconds(portableColor), installed, seconds(accelColor), colorRatio, pixelCount))

// MARK: - the check

guard checking else {
    exit(0)
}

var failures: [String] = []

// Correctness first. A fast kernel that computes the wrong thing is worse than
// no kernel, and the ratio above says nothing about that.
var accelerated: [UInt16] = .init(repeating: 0, count: 64)
var portable: [UInt16] = .init(repeating: 0, count: 64)
coefficients.withUnsafeBufferPointer { input in
    // The first block is enough; the kernels are checked exhaustively by the
    // test suite, and this is here to catch a build that wired up the wrong one.
    accelerated.withUnsafeMutableBufferPointer { out in
        JPEG.Kernel.inverseTransform(input.baseAddress!, 8, out.baseAddress!)
    }
    JPEG.Kernel.reset()
    portable.withUnsafeMutableBufferPointer { out in
        JPEG.Kernel.inverseTransform(input.baseAddress!, 8, out.baseAddress!)
    }
}
if accelerated != portable {
    failures.append("the \(installed) inverse transform disagrees with the portable one")
}

// Colour conversion is held to bit equality over the whole image, not a block.
// It is exact by construction — one fixed-point matrix, one rounding — and the
// suite proves that exhaustively; this catches a build that wired up a kernel
// for the wrong architecture, which would show as garbage rather than as a
// count.
func convert() -> [UInt8] {
    var out: [UInt8] = .init(repeating: 0, count: pixelCount * 3)
    out.withUnsafeMutableBufferPointer { out in
        ycc.withUnsafeBufferPointer { input in
            JPEG.Kernel.colorTransform(
                input.baseAddress!, pixelCount, 0, out.baseAddress!
            )
        }
    }
    return out
}

JPEG.Accelerate.install()
let acceleratedRGB: [UInt8] = convert()
JPEG.Kernel.reset()
if acceleratedRGB != convert() {
    failures.append("the \(installed) color transform disagrees with the portable one")
}

if installed == "portable" {
    print("")
    print("no accelerated kernels for this processor; ratio check skipped")
} else {
    // Deliberately loose. The measured speedups are around 5x for the
    // transforms and 3x for colour; this is asking whether the accelerated
    // kernel is being called at all and is not catastrophically slower, not
    // policing a number. A tight threshold on a shared runner is a flaky test,
    // and a flaky test gets ignored.
    let floor: Double = 1.15
    for (name, ratio): (String, Double) in [
        ("inverse", inverseRatio),
        ("forward", forwardRatio),
        ("color", colorRatio),
    ] where ratio < floor {
        failures.append(String(format: "%@ ratio %.2fx is below %.2fx",
                               name, ratio, floor))
    }
}

print("")
if failures.isEmpty {
    print("performance check passed")
    exit(0)
}
for failure: String in failures {
    print("performance check FAILED: \(failure)")
}
exit(1)
