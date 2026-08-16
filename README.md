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
| Extended sequential decode | ✅ |
| Grayscale, 4:4:4, 4:2:2, 4:2:0 | ✅ |
| Restart intervals | ✅ |
| Interpolated chroma upsampling | ✅ |
| Progressive decode | ✅ |
| Baseline encoding | ✅ |
| Optimized Huffman tables | ✅ |
| Progressive encoding | ✅ |
| 12-bit precision | ✅ |
| Scaled and cropped decoding | ✅ |
| JFIF / EXIF metadata | ✅ JFIF and EXIF orientation typed; the rest carried intact |
| Lossless transformation | ✅ |
| TurboJPEG C ABI | ✅ all 81 symbols |

## Requirements

Swift 6.0 or later. The `JPEG` module imports nothing — not Foundation, not a
platform module — and it builds for **Embedded Swift**:

```sh
! grep -rlE '^\s*import ' Sources/JPEG/
swiftc -enable-experimental-feature Embedded -wmo -Osize \
       -swift-version 6 -c Sources/JPEG/*.swift -o /tmp/embedded.o
```

Both are checked on every push, because they are the kind of thing one
convenient `import Foundation` undoes silently.

Embedded is why the engine throws `JPEG.Failure` rather than using a plain
`throws`. An untyped `throws` is `throws(any Error)`, and an existential needs
runtime machinery an embedded target does not have — so a single unannotated
`throws` anywhere in the engine takes the whole platform away. The four
stage-specific error enumerations are unchanged and are still the useful
classification; `JPEG.Failure` only gathers them so the throw can be declared.
Functions the engine generic over a thrown type, like the block accessors, use
`throws(E)` rather than `rethrows`, because `rethrows` propagates `any Error`.

Because the engine performs no I/O of its own, reading a file is the caller's
job. Bytes go in through `JPEG.Bytestream.Source`, which `[UInt8]` already
conforms to.

`Span` is used where it pays and not where it does not, and the line between them
was measured rather than guessed. Reading a whole plane is a `Span`:
`plane.withSamples { ... }` is public, needs no unsafe code and copies nothing,
and the lifetime is enforced by the compiler rather than requested by a comment.
The per-sample loops inside the resamplers keep raw pointers, because a `Span`
subscript is bounds checked and in those loops the check is not eliminated — the
index is a clamped column plus a row offset and the optimizer cannot prove the
sum is in range. Counted under callgrind, that costs 30% more instructions on the
upsampler's inner loop and 60% more on a strided copy. The spelling says which is
which: `withSamples` is the safe one, `withUnsafeSamples` has to be asked for.

`~Copyable` is not used, and that is also a measurement rather than a taste. The
only real candidate was `JPEG.Bitstream`, where forbidding copies would prevent a
reader being duplicated and its position silently diverging. Applied, it compiles,
and it generates the same code to within 67 instructions out of 182 million — so
there is no performance argument, only a safety one, and against that it removes a
capability a caller might legitimately want (saving a read position to backtrack
to) and makes the type harder to test, since swift-testing's `#expect` requires
`Copyable` to inspect a property. Nothing else in the codebase is a candidate at
all: the three image tiers are values that callers copy on purpose, and the ABI's
handle has to be a class to have an address a `void *` can carry.

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

Metadata rides on the image. Application segments and comments are collected in
stream order on decode and written back on encode, so decode-edit-encode
preserves them without the caller touching anything. JFIF is typed; EXIF and
everything else is carried intact rather than interpreted:

```swift
if case .jfif(let jfif)? = image.metadata.first {
    print(jfif.density, jfif.unit ?? "aspect ratio only")
}
image.metadata = [.jfif(.init(density: (300, 300), unit: .inches))]
```

The one EXIF field a codec can act on is orientation, so that one is read:
each of its eight values names one of the eight symmetries above. Turning a
sideways photograph upright is therefore lossless, and costs a transform and a
restamp:

```swift
var image: JPEG.Data.Spectral<JPEG.Common> = try .decompress(stream: &stream)
image = image.transformed(image.metadata.orientation.transform)
image.metadata.set(orientation: .up)
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

Scaled decompression, cropping, custom coefficient filters, image file loading
and saving, ICC profiles, lossless transformation, and 12- and 16-bit precision
are all implemented and covered by those programs. What is still refused rather
than approximated is the legacy `tjDecompress` spelling of scaled decompression,
which takes an arbitrary output size rather than one of the scaling factors the
modern API enumerates. Refusals go through the API's own error convention.

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
libjpeg-turbo on the same machine, both through a C ABI:

| | decode | | encode | |
| --- | --- | --- | --- | --- |
| libjpeg-turbo | 0.0056 s | 187 Mpixel/s | 0.0046 s | 228 Mpixel/s |
| swift-jpeg | 0.0436 s | 24 Mpixel/s | 0.0416 s | 25 Mpixel/s |

So roughly **8× slower on decode and 9× on encode**, from 310× before any
optimization work.

Three kinds of thing produced that. The first was structural: a lexer that
consumed from the front of an array and so cost time quadratic in the file size,
a heap allocation per byte of entropy coded data, and four allocations per 8×8
block. The second was algorithmic — a Huffman decode table that resolves any code
of eight bits or fewer in one step, and the factored transforms, which need 11
multiplies per 8-point transform where writing the definition out costs 64.

The third was specialization: writing out the cases every real image actually
hits, where the general code paid for generality on every sample. The subsampler
performed two integer divisions per output sample to discover it was averaging a
single one, which alone was the largest cost in the encoder. The upsampler read
two columns and a fraction from three tables per pixel where a halved ratio makes
the pattern repeat every two. And `tj3DecompressHeader` ran a full decode and
threw the image away, so a caller following the documented pattern of header then
decompress paid for two decodes to get one image — the shared library was very
nearly half as fast as the code inside it.

What is left is mostly SIMD, and a good deal of it is now closed. `JPEG.Kernel`
is a seam of function pointers that default to the portable Swift kernels; the
`JPEGAccelerate` module detects the processor with `cpuid` and replaces the ones
it has a faster path for. The C ABI installs them when it creates its first
handle, so the shared library is as fast as the machine allows without being
asked; the Swift package leaves the choice to the caller, who may prefer the
engine's discipline to the import.

| | portable | avx2 | |
| --- | --- | --- | --- |
| inverse transform, 16384 blocks | 0.0038 s | 0.0007 s | 5.8× |
| forward transform, 16384 blocks | 0.0031 s | 0.0007 s | 4.7× |
| YCbCr to RGB, 1 Mpixel | 0.0091 s | 0.0016 s | 5.9× |
| color to YCbCr, 1 Mpixel | 0.0081 s | 0.0016 s | 5.1× |
| decode, end to end | 0.0554 s | 0.0429 s | 1.29× |
| encode, end to end | 0.0480 s | 0.0437 s | 1.10× |

Reproduce both rows of that table with `swift run -c release jpeg-benchmark` and
`swift run -c release jpeg-benchmark --portable`.

The kernels are 5× and the pipeline is 1.1–1.3×, and the gap between those two
numbers is the honest part. A kernel measured on its own is 5× because that is
what vectorizing nine multiplies gets you; end to end the transforms and the
colour conversion are together about a third of the work, and the rest —
entropy coding above all, which is inherently serial — is untouched. The
end-to-end encode figure moves least because the benchmark's encoder is handed
YCbCr samples and so never calls the colour kernel at all; through the C ABI,
where the caller hands over pixels, that kernel is worth another 8 ms.

The kernels are bit-exact against the portable ones. The transforms are checked
over 8192 blocks in each direction, and the two colour kernels exhaustively —
all 16777216 inputs each, at every channel arrangement and every partial-vector
length. Exact rather than within a count, in both cases for a specific reason:
the transforms run the same factorization with the same constants, so any
disagreement would mean a lane is being computed differently rather than rounded
differently, and colour conversion is a single fixed-point matrix with a single
rounding, so a disagreement of one count would not be rounding at all — it would
be a tint on every pixel of every image, visible only to users of whichever
processor selected that kernel.

They are written as C intrinsics with a function-level `target` attribute rather
than as assembly or a separately-flagged compilation unit. The attribute is what
makes runtime dispatch possible without either: the file compiles for the
baseline, the two kernels compile for AVX2, and nothing calls them unless `cpuid`
says it may. Building the whole library for AVX2 would need per-target compiler
flags, which in SwiftPM means `unsafeFlags`, which would stop the package being
usable as a dependency at all. The `xgetbv` check alongside `cpuid` is not
pedantry: a processor can report AVX2 while the operating system does not
preserve the wide registers across a context switch.

There are two vector implementations, AVX2 and NEON, selected by `cpuid` and by
the target architecture respectively. NEON needs no detection: it is mandatory
on AArch64.

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

Continuous integration runs the tests, the C conformance suite, the two
discipline checks above and the benchmark, on x86-64 and on native arm64
runners. arm64 is not optional coverage — it is the only place the NEON kernels
run at all.

The performance job asserts a *ratio* between the portable and accelerated
kernels measured moments apart in one process, never an absolute time. A shared
runner under unknown load cannot be held to a number of seconds without becoming
flaky, and a flaky check gets ignored; the load slows both kernels alike, so the
ratio survives it. Absolute figures go to the run summary, which is what they
are good for.

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

One gap worth naming. Extended sequential frames (`SOF1`) take the same code path
as baseline but no fixture exercises them, because neither ImageMagick nor Pillow
will emit one.

12- and 16-bit precision are covered from the C side rather than by fixtures, by
round-tripping through `tj3Compress12`/`tj3Decompress12` and their 16-bit
counterparts — there is no reference decoder to hand for those, but a round trip
still catches a path that only works at 8 bits. It found one: the upsampler built
an intermediate that overflows a signed 32-bit value once a sample is wider than
about 13 bits, and because the overflow happened in a shift, which discards what
it pushes out rather than trapping, the value wrapped negative and trapped one
step later on a conversion. `ResampleTests` now holds that case with the hard
chroma edge that provokes it; a gradient does not, since the overflow needs the
largest possible difference between neighbouring samples.

## License

MIT. See [LICENSE](LICENSE).

All code here is original, and no other codec's source is reproduced in it. The
one thing this library is deliberately compatible with is the TurboJPEG C API,
whose header is BSD-3-Clause and is vendored under
[`Sources/CTurboJPEG`](Sources/CTurboJPEG) with its notice intact — a drop-in
replacement has to agree with the interface it replaces, and that is the
interface.
