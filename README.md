# swift-jpeg

A JPEG codec in pure Swift, built so it can also be published behind the
TurboJPEG C ABI.

## Status

A working codec with a working C ABI. Decoding handles baseline and progressive
JPEGs; baseline encoding produces files libjpeg-turbo reads cleanly. The build
produces a real `libturbojpeg.so.0` that a C program compiled against the
stock TurboJPEG header can link and use.

| | |
| --- | --- |
| Arithmetic coding (encode + decode) | ✅ |
| Lossless process (encode + decode) | ✅ |
| Lossless cropping and custom filters | ✅ |
| 16-bit precision | ✅ |
| Baseline sequential decode | ✅ |
| Extended sequential decode | ⚠️ shares the baseline path, untested |
| Grayscale, 4:4:4, 4:2:2, 4:2:0 | ✅ |
| Restart intervals | ✅ |
| Interpolated chroma upsampling | ✅ |
| Progressive decode | ✅ |
| Baseline encoding | ✅ |
| Optimized Huffman tables | ✅ |
| Progressive encoding | ✅ |
| 12-bit precision | ✅ |
| Scaled and cropped decoding | ✅ |
| JFIF / EXIF metadata | ❌ not yet |
| Lossless transformation | ✅ |
| TurboJPEG C ABI | ✅ all 81 symbols |

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

Encoding goes the other way, at a quality on the usual 1–100 scale:

```swift
var encoded: [UInt8] = []
try image.compress(stream: &encoded, quality: 85)
```

Stopping at an earlier tier gives you the coefficients or the unsampled planes
instead:

```swift
let spectral: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream: &stream)
let planar: JPEG.Data.Planar<JPEG.Common> = spectral.decomposed()
```

## Design

An image is modeled at three tiers, and decoding walks down them:

- **`Spectral`** — quantized DCT coefficients, JPEG's native form. Rotating or
  reflecting an image here is *exactly* lossless: `image.transformed(.rotate90)`
  rearranges numbers that are already exact, where rotating decoded pixels would
  round three times. All eight symmetries of a rectangle are available, and a
  transform followed by its inverse reproduces the original byte for byte.
- **`Planar`** — samples, dequantized and inverse transformed, each component
  still at its own subsampled resolution. This is what `tj3DecompressToYUV8`
  hands back, and stopping here saves a consumer feeding a video encoder or a
  GPU texture two conversions it would only have to undo.
- **`Rectangular`** — samples upsampled to full resolution and interleaved.

Color is a protocol rather than a hardcoded path, because JPEG records no color
meaning for its components — a frame header lists identifiers and sampling
factors and stops there. A component set the library does not recognize becomes
a *nonconforming* format instead of an error, so the image still decodes to
planes and only the color reading is left to the caller.

The **lossless process** (T.81 Annex H) is a second codec sharing only the
container: no transform, no quantization, no frequency domain. Each sample is
predicted from its already-coded neighbours and only the error is coded, so the
samples come back bit-exact. It is also the only route to 16-bit precision,
which the DCT-based processes cannot carry.

Lossless images store **RGB directly**, with `R`, `G` and `B` component
identifiers, rather than converting to YCbCr. That conversion is a fixed-point
round trip costing about one count, which would make "lossless" untrue — the
conformance program caught exactly that before the format existed.

Both entropy coders the standard defines are implemented. **Huffman** is the
default and what everything in circulation uses. **Arithmetic coding** (Annex D)
compresses about 10 percent better, and is supported in both directions —
verified against a file libjpeg wrote, which is the only test that means
anything for a coder whose encoder and decoder are written together.

For Huffman, the Annex K sample tables are used where
they suffice, since matching what every other encoder emits keeps output
comparable — and minimum-redundancy tables built from the image's own symbol
statistics where they do not. Which applies is decided by trial rather than by
rule: encode with the standard tables, and rebuild if any symbol turns out to
have no code. 12-bit samples always need the built tables, since they reach
magnitude categories past the eleven Annex K covers, and every progressive scan
gets its own because a DC first pass and a full-band refinement have nothing
statistically in common.

Errors are split by pipeline stage — lexing, parsing, decoding — so the stage
localizes the fault: bytes not shaped like a JPEG, versus a segment whose
contents are not self-consistent, versus valid segments that contradict one
another.

## The C ABI

The eventual goal is a drop-in `libturbojpeg.so.0`, so a program built against
TurboJPEG can load this instead without being recompiled. The engine is
deliberately kept ignorant that a C API exists; the boundary will be a separate
target that depends on it.

`cmake --build` produces `libturbojpeg.so.0`: correct soname, all eight
`TURBOJPEG_*` version nodes, exactly the 81 published symbols, and no Swift
symbols leaked past the version script.

Sixty-one symbols are implemented: the TJ3 lifecycle, parameters and buffer
sizing, the 8-bit compress and decompress paths, the planar YUV surface in both
directions, lossless transformation, and the 1.x/2.x spelling of all of it. Covering the old API matters
more than its size suggests — most software linking TurboJPEG today was written
against it, so implementing only TJ3 would make this a drop-in for nothing
already installed. The other 20 are generated C stubs
that return the failure value their signature documents, so the library loads
and every entry point resolves; the unfinished ones fail like ordinary errors
rather than crashing or returning something plausible. `scripts/implemented.txt`
tracks which is which, and the split is enforced by the linker: listing a name
early is a missing symbol, listing it late is a duplicate.

Run `Conformance/run.sh` to build the library and exercise it from C — one
program each for the TJ3 API, the legacy API, the YUV surface, and lossless
transformation. Point `LD_LIBRARY_PATH` at a
real libjpeg-turbo instead and both should behave identically; that comparison
is why they are C rather than more Swift tests.

Not implemented, and refused rather than approximated: scaled decompression,
cropping, custom coefficient filters, image file loading and saving, ICC
profiles, and 12- or 16-bit precision. A request for any of them fails through the API's own error
convention.

TurboJPEG is a good substitution target where the libjpeg API is not. `tjhandle`
is `void *`, so the handle is genuinely opaque and the engine can own its own
data; `jpeglib.h` by contrast defines `jpeg_decompress_struct` in the public
header and callers read `cinfo.output_width` directly, leaving no seam to build
against. TurboJPEG also has no variadic functions, so nothing needs to stay
hand-written C.

One wrinkle worth knowing if you read the header: from libjpeg-turbo 3.2,
`tj3Init` is a *macro* expanding to `tj3InitVersion(initType,
TURBOJPEG_VERSION_NUMBER)`. Modern clients therefore never call `tj3Init` by
name, but older binaries did bind to that symbol, so both are implemented.

## Performance

Honest numbers, measured on a 1024×1024 4:2:0 image against the system
libjpeg-turbo on the same machine, through the C ABI in both cases:

| | decode | | encode | |
| --- | --- | --- | --- | --- |
| libjpeg-turbo | 0.0052 s | 201 Mpixel/s | 0.0045 s | 236 Mpixel/s |
| swift-jpeg | 0.045 s | 23 Mpixel/s | 0.064 s | 16 Mpixel/s |

So roughly **9× slower on decode and 14× on encode**, from 310× before any
optimization work.

Two kinds of thing produced that. The first was structural: a lexer that consumed
from the front of an array and so cost time quadratic in the file size, a heap
allocation per byte of entropy coded data, four allocations per 8×8 block, and
bounds-checked subscripting in the per-pixel loops. The second was algorithmic —
a Huffman decode table that resolves any code of eight bits or fewer in one step,
the factored inverse and forward transforms, which need 11 multiplies per
8-point transform where writing the definition out costs 64, and a subsampler
that no longer performs two integer divisions per output sample to discover that
it is averaging a single one.

The remaining gap is mostly SIMD, and part of it is now closed. `JPEG.Kernel`
is a seam of function pointers that default to the portable Swift kernels; the
`JPEGAccelerate` module detects the processor with `cpuid` and replaces the ones
it has a faster path for. The C ABI installs them when it creates its first
handle, so the shared library is as fast as the machine allows without being
asked; the Swift package leaves the choice to the caller, who may prefer the
engine's discipline to the import.

| | portable | avx2 |
| --- | --- | --- |
| inverse transform | 0.0110 s | 0.0063 s |
| forward transform + quantize | 0.0197 s | 0.0152 s |
| decode, end to end | 0.0446 s | 0.0395 s |
| encode, end to end | 0.0625 s | 0.0572 s |

The kernels are about 1.75× on the transforms themselves, which is 8–11% end to
end because the transforms are a quarter of the pipeline. They are bit-exact
against the portable ones over 8192 blocks in both directions — exact, not
within a count, because both run the same factorization with the same constants,
so any disagreement at all would mean a lane is being computed differently
rather than rounded differently.

They are written as C intrinsics with a function-level `target` attribute rather
than as assembly or a separately-flagged compilation unit. The attribute is what
makes runtime dispatch possible without either: the file compiles for the
baseline, the two kernels compile for AVX2, and nothing calls them unless `cpuid`
says it may. Building the whole library for AVX2 would need per-target compiler
flags, which in SwiftPM means `unsafeFlags`, which would stop the package being
usable as a dependency at all. The `xgetbv` check alongside `cpuid` is not
pedantry: a processor can report AVX2 while the operating system does not
preserve the wide registers across a context switch.

Still scalar: the upsampler, the colour conversion and the subsampler. The
entropy coders do not vectorize — they are inherently serial.

Everything above was done because a measurement pointed at it. Several things
that looked like they should help did not, and were reverted rather than kept:
padding the bitstream so the bit reader could gather its window without a bounds
test, acquiring each coefficient block once so the entropy decoder's writes
skipped the copy-on-write check, and hoisting the Huffman tables out of the
per-block call. Each was a plausible story about where the time went, and each
measured flat. What is left in the profile is the entropy decoder, which is
memory-bound writing coefficient planes out, and it does not get faster by
being written more carefully.

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

The encoder is checked by round-tripping through the decoder, which is not
circular: the forward and inverse transforms are separate implementations
verified against each other and against the closed form, and the Huffman encoder
derives from the same canonical rule the decoder reconstructs independently. The
drift ceiling is calibrated against libjpeg-turbo doing the identical
decode-then-re-encode, which drifts more than this encoder does.

Two gaps worth naming. Extended sequential frames (`SOF1`) take the same code
path as baseline but no fixture exercises them, because neither ImageMagick nor
Pillow will emit one. Nothing covers 12- or 16-bit precision, which the
TurboJPEG ABI will eventually require, for the same reason.

## License

MIT. See [LICENSE](LICENSE).
