extension JPEG.Data {
    /// An image as interleaved samples at full resolution.
    ///
    /// The bottom tier: subsampled components have been stretched back to the
    /// image size, the block padding has been cropped away, and the components
    /// are interleaved one pixel at a time. This is the representation a caller
    /// who wants pixels is after, and the only one whose dimensions match what
    /// the frame header advertised.
    public struct Rectangular<Format> where Format: JPEG.Format {
        /// The image width, in pixels.
        public let width: Int
        /// The image height, in pixels.
        public let height: Int
        /// The image geometry and component structure.
        public let layout: JPEG.Layout<Format>

        /// Samples, row-major, `layout.planes.count` per pixel.
        public private(set) var values: [UInt16]
        /// The metadata segments carried over from the stream this image was
        /// decoded from, in stream order.
        public var metadata: [JPEG.Metadata]

        init(
            width: Int,
            height: Int,
            layout: JPEG.Layout<Format>,
            values: [UInt16],
            metadata: [JPEG.Metadata] = []
        ) {
            self.width = width
            self.height = height
            self.layout = layout
            self.values = values
            self.metadata = metadata
        }
    }
}

extension JPEG.Data.Rectangular {
    /// The image size, in pixels.
    public var size: (x: Int, y: Int) {
        (x: self.width, y: self.height)
    }

    /// The number of components per pixel.
    public var stride: Int {
        self.layout.planes.count
    }

    /// Accesses the sample for the given component of the pixel at `(x, y)`.
    public subscript(x x: Int, y y: Int, plane: Int) -> UInt16 {
        self.values[(y * self.width + x) * self.stride + plane]
    }

    /// Returns the given rectangle of this image.
    ///
    /// Cropping at this tier is a copy, and exact at any offset. Cropping at
    /// the spectral tier would be cheaper — whole blocks outside the region
    /// need never be transformed — but only lands on block boundaries, so this
    /// is the general answer and the other is an optimization for the aligned
    /// case.
    ///
    /// -   Returns:
    ///     `nil` if the rectangle is not wholly inside the image.
    public func cropped(to region: (x: Int, y: Int, width: Int, height: Int)) -> Self? {
        guard
        region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
        region.x + region.width <= self.width,
        region.y + region.height <= self.height
        else {
            return nil
        }

        let stride: Int = self.stride
        var values: [UInt16] = .init(
            repeating: 0, count: region.width * region.height * stride
        )
        for y: Int in 0 ..< region.height {
            for x: Int in 0 ..< region.width {
                for plane: Int in 0 ..< stride {
                    values[(y * region.width + x) * stride + plane] =
                        self[x: region.x + x, y: region.y + y, plane]
                }
            }
        }

        var layout: JPEG.Layout<Format> = self.layout
        layout.width = region.width
        layout.height = region.height

        return .init(
            width: region.width,
            height: region.height,
            layout: layout,
            values: values,
            metadata: self.metadata
        )
    }

    /// Converts the samples into an array of colors, one per pixel, row-major.
    public func unpack<Color>(as _: Color.Type) -> [Color]
        where Color: JPEG.Color, Color.Format == Format
    {
        Color.unpack(self.values, of: self.layout.format)
    }
}

extension JPEG.Data.Planar {
    /// Maps an output coordinate to a position in a plane sampled `numerator`
    /// times for every `denominator` output samples, in Q16 fixed point.
    ///
    /// The half-sample terms are what make this an interpolation rather than a
    /// stretch. A subsampled chroma sample represents the *center* of the area
    /// it covers, not its corner, so the output grid and the source grid are
    /// offset by half a source sample. Dropping the offset shifts chroma by
    /// half a pixel — a subtle error that looks like color fringing on one side
    /// of every edge.
    private static func source(_ x: Int, _ numerator: Int, _ denominator: Int) -> Int {
        (((2 * x + 1) * numerator) << 16) / (2 * denominator) - (1 << 15)
    }

    /// Blends the four samples around an output position.
    ///
    /// Factored out so that the two loops below — one reading its columns from a
    /// table, one walking them — are demonstrably the same arithmetic. The
    /// upsampler is the one place in the decoder where two implementations of a
    /// formula coexist, and they have to agree bit for bit or the fast one is
    /// simply a different filter.
    @inline(__always)
    private static func blend(
        _ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, fx: Int32, fy: Int32
    ) -> UInt16 {
        // The fractions are narrowed to eight bits *before* multiplying, which
        // is what the expression this replaces did: Swift binds a shift tighter
        // than a multiply, so `(b - a) * fx >> 8` means `(b - a) * (fx >> 8)`
        // and not the other grouping. Written with the parentheses, because
        // relying on that reading is how the overflow below got in.
        let horizontal: Int32 = fx >> 8
        let top: Int32 = (a << 8) + (b - a) * horizontal
        let bottom: Int32 = (c << 8) + (d - c) * horizontal

        // The vertical stage in 64 bits, which is not optional. At 16 bits of
        // precision `top` reaches 26 bits, so `top << 8` overflows a signed
        // 32-bit value — and a shift discards what it pushes out silently, so
        // rather than trapping there it wrapped to a negative and trapped one
        // step later, converting to `UInt16`. A hard chroma edge in a 16-bit
        // image was enough to do it. At 8 and 12 bits everything fits and the
        // 32-bit arithmetic was correct, which is why it stood.
        //
        // On a 64-bit target this is the same instruction count with a wider
        // prefix. The first stage stays 32-bit because it genuinely fits: a
        // sample difference is 17 bits and a narrowed fraction is 8.
        let value: Int64 = (.init(top) << 8)
            + .init(bottom - top) * .init(fy >> 8)
            + (1 << 15)
        return .init(value >> 16)
    }

    /// Blends the four samples around an output position that sits at a quarter
    /// of the way between them in both directions.
    ///
    /// The same result as ``blend(_:_:_:_:fx:fy:)`` for the fractions a halving
    /// produces, and much cheaper, because at those fractions the Q16 form
    /// collapses. A halving makes every horizontal fraction 3/4 or 1/4 and, when
    /// the plane is halved vertically too, every vertical fraction likewise — so
    /// each of the four weights is a product of two of {1, 3} over 4, and the
    /// whole blend is a weighted sum over sixteen.
    ///
    /// Writing out the general form with `hx` of 192 and `fy` of 192:
    ///
    /// ```
    /// top    = 256a + 192(b - a)          = 64(a + 3b)
    /// bottom = 256c + 192(d - c)          = 64(c + 3d)
    /// value  = 64·top + 192·bottom + 2^15 = 4096[(a + 3b) + 3(c + 3d) + 8]
    /// value >> 16                         = [(a + 3b) + 3(c + 3d) + 8] >> 4
    /// ```
    ///
    /// The factor of 4096 divides out exactly, so this is not an approximation of
    /// the other function — it is the same integer, by the same rounding. The
    /// other three fraction pairs work out the same way with the weights
    /// exchanged, which is why they are passed in rather than written here.
    ///
    /// It also stays in 32 bits at every precision, where the general form cannot:
    /// the largest value this can produce is sixteen times a sample, and
    /// `16 · 65535` is 21 bits.
    ///
    /// -   Parameters:
    ///     -   h: The weights of the left and right source columns, `(1, 3)` when
    ///         the output column is nearer the right one and `(3, 1)` otherwise.
    ///     -   v: The same for the upper and lower source rows.
    @inline(__always)
    private static func blend(
        _ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32,
        h: (Int32, Int32),
        v: (Int32, Int32)
    ) -> UInt16 {
        let top: Int32 = h.0 * a + h.1 * b
        let bottom: Int32 = h.0 * c + h.1 * d
        return .init((v.0 * top + v.1 * bottom + 8) >> 4)
    }

    /// Upsamples and interleaves this image to full resolution.
    ///
    /// A component sampled as densely as the frame is copied verbatim. A
    /// subsampled one is bilinearly interpolated, which for the 2×1 and 2×2
    /// cases reproduces the triangular filter libjpeg calls "fancy upsampling"
    /// and enables by default. Matching it matters here: this library is meant
    /// to stand in for that one, and replication — which is what the standard's
    /// own reference decoder does — differs from it by up to about 40 counts at
    /// a sharp chroma edge.
    ///
    /// Reads past a plane's edge clamp, so the margins repeat the edge sample
    /// instead of interpolating toward nothing.
    ///
    /// The block padding each plane carries is dropped at the same time, since
    /// the crop and the scale share an index calculation.
    public func interleaved() -> JPEG.Data.Rectangular<Format> {
        let width: Int = self.layout.width
        let height: Int = self.layout.height
        let stride: Int = self.planes.count

        // Uninitialized, not zeroed. Plane `p` writes every index congruent to
        // `p` modulo the stride, and there is one plane per residue, so the
        // planes below partition the buffer and every element is written
        // exactly once. Zeroing it first was six megabytes of stores on a
        // megapixel image that nothing ever read.
        //
        // The obligation that comes with saying so: any future path that
        // leaves an element unwritten publishes uninitialized memory rather
        // than a zero. `fill(_:width:height:stride:)` is where that invariant
        // has to hold, and the loops there all run the full width and height.
        let values: [UInt16] = .init(
            unsafeUninitializedCapacity: width * height * stride
        ) { buffer, initialized in
            self.fill(buffer, width: width, height: height, stride: stride)
            initialized = width * height * stride
        }

        return .init(
            width: width,
            height: height,
            layout: self.layout,
            values: values,
            metadata: self.metadata
        )
    }

    /// Writes every sample of the interleaved image into `values`.
    ///
    /// Every element is written, which is what lets the caller hand this
    /// uninitialized storage.
    private func fill(
        _ values: UnsafeMutableBufferPointer<UInt16>,
        width: Int,
        height: Int,
        stride: Int
    ) {
        let scale: JPEG.Component.Sampling = self.layout.scale

        for (plane, component): (Int, JPEG.Component) in self.layout.planes.enumerated() {
            let sampling: JPEG.Component.Sampling = component.sampling
            let source: Plane = self.planes[plane]

            let extent: (x: Int, y: Int) = source.size

            guard sampling.x != scale.x || sampling.y != scale.y else {
                // Full resolution. Interpolating would be a no-op in exact
                // arithmetic but not in fixed point, so take the direct path
                // and keep the samples bit-exact. This is the luma plane of
                // every subsampled image, so it is a million samples on a
                // megapixel image and worth writing through a raw pointer.
                source.withUnsafeSamples { samples in
                    let source: UnsafePointer<UInt16> = samples.baseAddress!
                    let destination: UnsafeMutablePointer<UInt16> = values.baseAddress!
                    for y: Int in 0 ..< height {
                        // Two pointers walked forward rather than two
                        // indices recomputed, and unrolled: the body is one
                        // load and one store, so at one pixel per iteration
                        // the increment, compare and branch were most of it.
                        //
                        // Eight rather than more, and the reason is the
                        // interesting part. Instructions for the whole
                        // decode fall monotonically with the unroll factor —
                        // 1801.8M at one, 1757.3M at four, 1742.8M at eight,
                        // 1735.6M at sixteen — but wall clock stops
                        // improving after eight and sixteen is no better
                        // than eight on this machine. This loop is a strided
                        // scatter over six megabytes: it is bound by the
                        // stores, not by the arithmetic around them, so past
                        // the point where the loop overhead is amortized the
                        // only thing a wider body buys is instruction cache
                        // pressure. Eight is where the two curves part.
                        var output: UnsafeMutablePointer<UInt16> =
                            destination + (y * width * stride + plane)
                        var input: UnsafePointer<UInt16> = source + y * extent.x
                        var x: Int = 0
                        while x + 8 <= width {
                            output[0] = input[0]
                            output[stride] = input[1]
                            output[2 * stride] = input[2]
                            output[3 * stride] = input[3]
                            output[4 * stride] = input[4]
                            output[5 * stride] = input[5]
                            output[6 * stride] = input[6]
                            output[7 * stride] = input[7]
                            output += 8 * stride
                            input += 8
                            x += 8
                        }
                        while x < width {
                            output.pointee = input.pointee
                            output += stride
                            input += 1
                            x += 1
                        }
                    }
                }
                continue
            }

            // Column coordinates repeat on every row, so they are computed
            // once for the plane rather than a million times — and clamped
            // here too, since the clamp also depends only on x.
            var lefts: [Int] = .init(repeating: 0, count: width)
            var rights: [Int] = .init(repeating: 0, count: width)
            var fractions: [Int32] = .init(repeating: 0, count: width)
            for x: Int in 0 ..< width {
                let u: Int = Self.source(x, sampling.x, scale.x)
                let column: Int = u >> 16
                lefts[x] = Swift.min(Swift.max(column, 0), extent.x - 1)
                rights[x] = Swift.min(Swift.max(column + 1, 0), extent.x - 1)
                fractions[x] = .init(u - (column << 16))
            }
            // A component sampled at exactly half the frame's density — 4:2:0
            // and 4:2:2 chroma, which is nearly every subsampled image there is.
            // Halving makes the column pattern repeat every two output pixels
            // and makes a pair of them share their middle source sample, both
            // of which the general loop has no way to know.
            let halved: Bool = 2 * sampling.x == scale.x
            // Halved in the other direction too, which is 4:2:0 and so most of
            // what there is. Then the vertical fractions are a quarter and three
            // quarters as well, and the blend collapses to small integers.
            let halvedRows: Bool = 2 * sampling.y == scale.y

            // The output columns where neither source column of either pixel of
            // a pair is clamped. Outside it the interpolation reaches past the
            // plane, and the clamps the tables have folded in are needed.
            let interior: Range<Int>
            if halved, extent.x >= 3, Swift.min(width, 2 * (extent.x - 1)) >= 2 {
                interior = 2 ..< Swift.min(width, 2 * (extent.x - 1))
            } else {
                interior = 0 ..< 0
            }

            // Read once for the plane rather than once per row. A mutable
            // global carries a dynamic exclusivity check on every read, and at
            // row granularity that check is a measurable share of a kernel
            // call that only produces one row. The same hoist as the one in
            // `decomposed(scale:)`, one tier down.
            let rowKernel: JPEG.Kernel.UpsamplePairs? = JPEG.Kernel.upsamplePairs

            // Where the interior goes through the installed row kernel, it
            // lands here first and is scattered into the interleaved output
            // after. One row, allocated once per plane.
            withUnsafeTemporaryAllocation(of: UInt16.self, capacity: Swift.max(width, 1)) { scratch in
            source.withUnsafeSamples { samples in
              lefts.withUnsafeBufferPointer { lefts in
                rights.withUnsafeBufferPointer { rights in
                  fractions.withUnsafeBufferPointer { fractions in
                  for y: Int in 0 ..< height {
                      let v: Int = Self.source(y, sampling.y, scale.y)
                      // Arithmetic shift floors, including for the negative
                      // coordinates the half-sample offset produces at the
                      // top and left margins, so the fraction stays in 0 ..< 1.
                      let row: Int = v >> 16
                      let fy: Int32 = .init(v - (row << 16))

                      // Clamping the two source rows once per output row
                      // removes two bounds checks from every pixel.
                      let above: Int = Swift.min(Swift.max(row, 0), extent.y - 1) * extent.x
                      let below: Int = Swift.min(Swift.max(row + 1, 0), extent.y - 1) * extent.x

                      /// One output pixel, reading its columns from the tables
                      /// so that the clamps at the plane's edges are already
                      /// folded in. Correct everywhere, and the only path for
                      /// any ratio other than a halving.
                      @inline(__always)
                      func tabulated(_ x: Int) -> UInt16 {
                          let left: Int = lefts[x]
                          let right: Int = rights[x]
                          return Self.blend(
                              .init(samples[above + left]),
                              .init(samples[above + right]),
                              .init(samples[below + left]),
                              .init(samples[below + right]),
                              fx: fractions[x],
                              fy: fy
                          )
                      }

                      var output: Int = y * width * stride + plane
                      var x: Int = 0
                      while x < interior.lowerBound {
                          values[output] = tabulated(x)
                          output += stride
                          x += 1
                      }

                      // Two output pixels at a time. Under a halving the even
                      // pixel interpolates source columns k-1 and k at three
                      // quarters and the odd one columns k and k+1 at one
                      // quarter, so the fractions are constants rather than a
                      // third table and the walk over the source row is
                      // sequential instead of indexed.
                      //
                      // A pair spans three source columns, but only the last of
                      // them is new: the pair at k+1 reads columns k, k+1 and
                      // k+2, and the first two are the ones this iteration just
                      // read. So they are carried in registers and rotated,
                      // which makes the loop cost two loads per pair rather
                      // than six. The values are the same either way, and the
                      // resampling test holds this loop against the tabulated
                      // one to prove it.
                      var k: Int = x >> 1
                      let upper: Int = interior.upperBound
                      // Under a halving in both directions the vertical
                      // fraction is a quarter or three quarters, so the row
                      // weights come out of which side of the source pair
                      // this output row falls on — and the whole interior is
                      // the shape the row kernel takes, if one is installed.
                      if halvedRows, x + 1 < upper,
                         let kernel: JPEG.Kernel.UpsamplePairs = rowKernel
                      {
                          let pairs: Int = ((upper - x - 2) >> 1) + 1
                          kernel(
                              samples.baseAddress! + above + k,
                              samples.baseAddress! + below + k,
                              pairs,
                              fy == 49152 ? 1 : 3,
                              fy == 49152 ? 3 : 1,
                              scratch.baseAddress!
                          )
                          // The scatter from the contiguous scratch row into
                          // the interleaved output. The third strided copy in
                          // the codec, and it takes the shape the other two
                          // measured into: pointers walked forward, eight
                          // per iteration, because a body of one load and one
                          // store is all loop overhead otherwise.
                          let count: Int = 2 * pairs
                          var source: UnsafePointer<UInt16> = .init(scratch.baseAddress!)
                          var destination: UnsafeMutablePointer<UInt16> =
                              values.baseAddress! + output
                          var i: Int = 0
                          while i + 8 <= count {
                              destination[0] = source[0]
                              destination[stride] = source[1]
                              destination[2 * stride] = source[2]
                              destination[3 * stride] = source[3]
                              destination[4 * stride] = source[4]
                              destination[5 * stride] = source[5]
                              destination[6 * stride] = source[6]
                              destination[7 * stride] = source[7]
                              destination += 8 * stride
                              source += 8
                              i += 8
                          }
                          while i < count {
                              destination.pointee = source.pointee
                              destination += stride
                              source += 1
                              i += 1
                          }
                          output += count * stride
                          k += pairs
                          x += 2 * pairs
                      } else if x + 1 < upper {
                          var a: Int32 = .init(samples[above + k - 1])
                          var b: Int32 = .init(samples[above + k])
                          var c: Int32 = .init(samples[below + k - 1])
                          var d: Int32 = .init(samples[below + k])

                          if halvedRows {
                              let v: (Int32, Int32) = fy == 49152 ? (1, 3) : (3, 1)
                              while x + 1 < upper {
                                  let e: Int32 = .init(samples[above + k + 1])
                                  let f: Int32 = .init(samples[below + k + 1])

                                  values[output] = Self.blend(a, b, c, d, h: (1, 3), v: v)
                                  output += stride
                                  values[output] = Self.blend(b, e, d, f, h: (3, 1), v: v)
                                  output += stride

                                  a = b
                                  b = e
                                  c = d
                                  d = f
                                  k += 1
                                  x += 2
                              }
                          } else {
                              while x + 1 < upper {
                                  let e: Int32 = .init(samples[above + k + 1])
                                  let f: Int32 = .init(samples[below + k + 1])

                                  values[output] = Self.blend(a, b, c, d, fx: 49152, fy: fy)
                                  output += stride
                                  values[output] = Self.blend(b, e, d, f, fx: 16384, fy: fy)
                                  output += stride

                                  a = b
                                  b = e
                                  c = d
                                  d = f
                                  k += 1
                                  x += 2
                              }
                          }
                      }

                      while x < width {
                          values[output] = tabulated(x)
                          output += stride
                          x += 1
                      }
                  }
                  }
                }
              }
            }
            }
        }
    }
}

extension JPEG.Data.Spectral {
    /// Decodes all the way down to interleaved full-resolution samples.
    public func rectangular() -> JPEG.Data.Rectangular<Format> {
        self.decomposed().interleaved()
    }

    /// Decodes to interleaved samples at `n/8` of the coded size.
    public func rectangular(scale n: Int) -> JPEG.Data.Rectangular<Format> {
        self.decomposed(scale: n).interleaved()
    }
}
