extension JPEG.Data.Spectral {
    /// Decodes the DC coefficient of one block, first pass.
    ///
    /// Identical to the sequential DC procedure except that the value is stored
    /// shifted left by the point transform, leaving room for later refinement
    /// scans to fill in the bits below. The predictor itself is *not* shifted:
    /// differences accumulate in whole units, and only the stored coefficient
    /// carries the shift.
    mutating func decode(
        dcFirst block: (x: Int, y: Int),
        of component: Resolved,
        from bits: inout JPEG.Bitstream,
        predictor: inout Int32,
        approximation: Int
    ) throws {
        guard let dc: JPEG.Table.Huffman = component.dc else {
            return
        }

        let category: Int = .init(try dc.symbol(from: &bits))
        guard category <= 16 else {
            throw JPEG.DecodingError.invalidEntropyCodedSymbol
        }

        predictor &+= .init(bits.amplitude(category: category))
        self.planes[component.plane][x: block.x, y: block.y, z: 0] =
            .init(truncatingIfNeeded: predictor << Int32(approximation))
    }

    /// Refines the DC coefficient of one block by a single bit.
    ///
    /// A DC refinement scan carries no Huffman coding at all — one raw bit per
    /// block, in scan order. The bit is OR-ed rather than added because the
    /// coefficient's sign is already established and only a lower magnitude bit
    /// is being supplied.
    mutating func decode(
        dcRefining block: (x: Int, y: Int),
        of component: Resolved,
        from bits: inout JPEG.Bitstream,
        approximation: Int
    ) {
        guard bits.read(1) != 0 else {
            return
        }
        self.planes[component.plane][x: block.x, y: block.y, z: 0] |=
            .init(truncatingIfNeeded: 1 << approximation)
    }

    /// Decodes a band of AC coefficients, first pass.
    ///
    /// Like the sequential AC procedure, but end-of-block is generalized to an
    /// *end-of-band run*: one symbol can declare that this block and the next
    /// `2^r + extra - 1` blocks have nothing more in this band. Early
    /// progressive scans are mostly empty, so this is where their compression
    /// comes from.
    mutating func decode(
        acFirst block: (x: Int, y: Int),
        of component: Resolved,
        from bits: inout JPEG.Bitstream,
        band: Range<Int>,
        approximation: Int,
        eobrun: inout Int
    ) throws {
        guard let ac: JPEG.Table.Huffman = component.ac else {
            return
        }
        guard eobrun == 0 else {
            eobrun -= 1
            return
        }

        var k: Int = band.lowerBound
        while k < band.upperBound {
            let symbol: UInt8 = try ac.symbol(from: &bits)
            let run: Int = .init(symbol >> 4)
            let size: Int = .init(symbol & 0x0F)

            guard size > 0 else {
                guard run == 15 else {
                    // EOBn: this block, plus 2^run + extra - 1 more.
                    eobrun = (1 << run) - 1
                    if run > 0 {
                        eobrun += .init(bits.read(run))
                    }
                    return
                }
                // ZRL: sixteen zeros, and the run continues.
                k += 16
                continue
            }

            k += run
            guard k < band.upperBound else {
                throw JPEG.DecodingError.invalidEntropyCodedSymbol
            }

            self.planes[component.plane][x: block.x, y: block.y, z: JPEG.zigzag[k]] =
                .init(truncatingIfNeeded: bits.amplitude(category: size) << approximation)
            k += 1
        }
    }

    /// Refines a band of AC coefficients by a single bit.
    ///
    /// The most intricate procedure in the format, because two interleaved
    /// streams share one bit sequence. The Huffman-coded symbols describe
    /// *newly* nonzero coefficients — how many zero-so-far positions to skip,
    /// then a one-bit sign — while every already-nonzero coefficient passed
    /// along the way silently consumes one raw correction bit.
    ///
    /// So the run length counts only positions that are still zero. Miscounting
    /// by including an already-nonzero coefficient desynchronizes the rest of
    /// the scan, which is why the inner loop decrements the run in exactly one
    /// branch.
    ///
    /// A correction bit of 1 means "increase this coefficient's magnitude",
    /// which is an addition away from zero rather than a bit set, since the
    /// value is stored in two's complement.
    mutating func decode(
        acRefining block: (x: Int, y: Int),
        of component: Resolved,
        from bits: inout JPEG.Bitstream,
        band: Range<Int>,
        approximation: Int,
        eobrun: inout Int
    ) throws {
        guard let ac: JPEG.Table.Huffman = component.ac else {
            return
        }

        let positive: Int16 = .init(truncatingIfNeeded: 1 << approximation)
        let negative: Int16 = 0 &- positive

        /// Appends one correction bit to an already-nonzero coefficient.
        func correct(_ z: Int, _ bits: inout JPEG.Bitstream) {
            let coefficient: Int16 = self.planes[component.plane][
                x: block.x, y: block.y, z: z
            ]
            guard bits.read(1) != 0, coefficient & positive == 0 else {
                return
            }
            self.planes[component.plane][x: block.x, y: block.y, z: z] =
                coefficient &+ (coefficient >= 0 ? positive : negative)
        }

        var k: Int = band.lowerBound

        if eobrun == 0 {
            while k < band.upperBound {
                let symbol: UInt8 = try ac.symbol(from: &bits)
                var run: Int = .init(symbol >> 4)
                var value: Int16 = 0

                if symbol & 0x0F != 0 {
                    // A newly nonzero coefficient. Its magnitude is always
                    // exactly one at this bit position, so only the sign is
                    // transmitted.
                    value = bits.read(1) != 0 ? positive : negative
                } else if run != 15 {
                    eobrun = 1 << run
                    if run > 0 {
                        eobrun += .init(bits.read(run))
                    }
                    break
                }
                // Otherwise ZRL: skip sixteen still-zero positions, no new
                // coefficient.

                while k < band.upperBound {
                    let z: Int = JPEG.zigzag[k]
                    if self.planes[component.plane][x: block.x, y: block.y, z: z] != 0 {
                        correct(z, &bits)
                    } else {
                        if run == 0 {
                            break
                        }
                        run -= 1
                    }
                    k += 1
                }

                if value != 0, k < band.upperBound {
                    self.planes[component.plane][
                        x: block.x, y: block.y, z: JPEG.zigzag[k]
                    ] = value
                }
                k += 1
            }
        }

        if eobrun > 0 {
            // Inside an end-of-band run no new coefficients appear, but the
            // already-nonzero ones in the rest of the band still each take a
            // correction bit.
            while k < band.upperBound {
                let z: Int = JPEG.zigzag[k]
                if self.planes[component.plane][x: block.x, y: block.y, z: z] != 0 {
                    correct(z, &bits)
                }
                k += 1
            }
            eobrun -= 1
        }
    }
}
