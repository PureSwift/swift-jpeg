# swift-jpeg

A JPEG codec in pure Swift, built so it can also be published behind the
TurboJPEG C ABI.

## Status

Early. Decoding works for both baseline and progressive JPEGs, verified against
reference decodes produced by libjpeg-turbo. Encoding does not exist yet.

| | |
| --- | --- |
| Baseline sequential decode | ✅ |
| Extended sequential decode | ⚠️ shares the baseline path, untested |
| Grayscale, 4:4:4, 4:2:2, 4:2:0 | ✅ |
| Restart intervals | ✅ |
| Interpolated chroma upsampling | ✅ |
| Progressive decode | ✅ |
| Encoding | ❌ not yet |
| JFIF / EXIF metadata | ❌ not yet |
| TurboJPEG C ABI | ❌ groundwork only |

## Requirements

Swift 6.0 or later. The `JPEG` module imports nothing — not Foundation, not a
platform module — so it should build anywhere Swift does, including Embedded
Swift. That is a constraint to be enforced rather than trusted:

```sh
! grep -rlE '^\s*import ' Sources/JPEG/
```

Because the engine performs no I/O of its own, reading a file is the caller's
job. Bytes go in through `JPEG.Bytestream.Source`, which `[UInt8]` already
conforms to.

## Usage

```swift
import Foundation
import JPEG

var stream: [UInt8] = .init(try Data(contentsOf: url))
let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)

let size: (x: Int, y: Int) = image.size
let rgb: [JPEG.RGB] = image.unpack(as: JPEG.RGB.self)
```

Stopping at an earlier tier gives you the coefficients or the unsampled planes
instead:

```swift
let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream: &stream)
let planar: JPEG.Data.Planar<JPEG.Common> = spectral.decomposed()
```

## Design

An image is modeled at three tiers, and decoding walks down them:

- **`Spectral`** — quantized DCT coefficients, JPEG's native form. Rotating,
  cropping to a block boundary, or requantizing is lossless here and lossy
  anywhere else.
- **`Planar`** — samples, dequantized and inverse transformed, each component
  still at its own subsampled resolution.
- **`Rectangular`** — samples upsampled to full resolution and interleaved.

Color is a protocol rather than a hardcoded path, because JPEG records no color
meaning for its components — a frame header lists identifiers and sampling
factors and stops there. A component set the library does not recognize becomes
a *nonconforming* format instead of an error, so the image still decodes to
planes and only the color reading is left to the caller.

Errors are split by pipeline stage — lexing, parsing, decoding — so the stage
localizes the fault: bytes not shaped like a JPEG, versus a segment whose
contents are not self-consistent, versus valid segments that contradict one
another.

## The C ABI

The eventual goal is a drop-in `libturbojpeg.so.0`, so a program built against
TurboJPEG can load this instead without being recompiled. The engine is
deliberately kept ignorant that a C API exists; the boundary will be a separate
target that depends on it.

The groundwork is in `scripts/`: the 81 exported symbols grouped by ELF version
node, and linker scripts for both platforms. `CMakeLists.txt` builds the engine
today and carries the shared-library wiring, inert until the boundary target
lands.

TurboJPEG is a good substitution target where the libjpeg API is not. `tjhandle`
is `void *`, so the handle is genuinely opaque and the engine can own its own
data; `jpeglib.h` by contrast defines `jpeg_decompress_struct` in the public
header and callers read `cinfo.output_width` directly, leaving no seam to build
against. TurboJPEG also has no variadic functions, so nothing needs to stay
hand-written C.

## Testing

```sh
swift test
```

Fixtures are 133×101 — a multiple of neither 8 nor 16 — so every case exercises
MCU padding at the right and bottom edges. Reference decodes come from
ImageMagick, which decodes through libjpeg-turbo.

Comparison is against an error bound rather than bit equality, which is how T.83
defines conformance: implementations round the inverse DCT differently and are
permitted to. Current worst-case sample deviation against the reference is 1 for
grayscale and 3 for color, with mean absolute deviation under 0.1 — the same
for progressive images as for baseline ones.

The sampling modes are held to separate thresholds so a failure localizes
itself — grayscale covers the transform, 4:4:4 adds color conversion, 4:2:2 and
4:2:0 add upsampling in one axis and then both.

Two gaps worth naming. Extended sequential frames (`SOF1`) take the same code
path as baseline but no fixture exercises them, because neither ImageMagick nor
Pillow will emit one. Nothing covers 12- or 16-bit precision, which the
TurboJPEG ABI will eventually require, for the same reason.

## License

MIT. See [LICENSE](LICENSE).
