extension JPEG {
    /// State a progressive scan carries between blocks.
    ///
    /// Sequential coding is memoryless past the DC predictor: every block emits
    /// its own symbols and is done. Progressive coding is not. An end-of-band
    /// run spans blocks and cannot be written until it is known to have ended,
    /// and a refinement scan's correction bits are held back until the symbol
    /// they follow is emitted. Both live here rather than in the driver, which
    /// only knows about blocks.
    struct Progression {
        /// How many blocks so far have ended their band with nothing left.
        ///
        /// Written as one `EOBn` symbol when the run finally breaks, which is
        /// the whole of a progressive scan's compression advantage over coding
        /// each block's emptiness separately.
        private(set) var eobrun: Int
        /// Correction bits from blocks already inside the pending run.
        ///
        /// These come out immediately after the `EOBn` symbol that closes the
        /// run, because that symbol is what tells a decoder those blocks
        /// existed at all.
        private(set) var committed: [UInt8]
        /// Correction bits from the block being coded right now.
        ///
        /// Held separately from ``committed`` and emitted *after* the next
        /// symbol rather than before it. Two buffers rather than one is the
        /// whole subtlety of this procedure: the order on the wire is
        /// `EOBn`, committed bits, symbol, pending bits, and a single queue
        /// cannot produce it. Merging them desynchronizes the decoder at the
        /// first block that has both a correction and a new coefficient.
        private(set) var pending: [UInt8]

        init() {
            self.eobrun = 0
            self.committed = []
            self.pending = []
        }

        mutating func append(correction bit: UInt8) {
            self.pending.append(bit)
        }

        /// Ends a block that had nothing more to say.
        ///
        /// The block joins the run, and its corrections become the run's, since
        /// they will now be read as that block's share of the run.
        mutating func endOfBand() {
            self.eobrun += 1
            self.committed.append(contentsOf: self.pending)
            self.pending.removeAll(keepingCapacity: true)
        }

        /// Writes any pending end-of-band run, and the corrections belonging to
        /// the blocks it covers.
        ///
        /// With no run pending this does nothing at all — in particular it does
        /// not release the current block's bits, which belong after the symbol
        /// about to be written.
        mutating func flush(
            to bits: inout JPEG.BitstreamWriter,
            using encoder: JPEG.Table.Huffman.Encoder
        ) throws {
            guard self.eobrun > 0 else {
                return
            }

            // The run length is coded as a magnitude category and its low bits,
            // exactly like a coefficient amplitude.
            let category: Int = Int.bitWidth - self.eobrun.leadingZeroBitCount - 1
            try encoder.encode(.init(truncatingIfNeeded: category << 4), to: &bits)
            if category > 0 {
                bits.write(
                    .init(truncatingIfNeeded: self.eobrun - (1 << category)),
                    count: category
                )
            }
            self.eobrun = 0

            for bit: UInt8 in self.committed {
                bits.write(.init(bit), count: 1)
            }
            self.committed.removeAll(keepingCapacity: true)
        }

        /// Writes the current block's queued corrections, after its symbol.
        mutating func flushPending(to bits: inout JPEG.BitstreamWriter) {
            for bit: UInt8 in self.pending {
                bits.write(.init(bit), count: 1)
            }
            self.pending.removeAll(keepingCapacity: true)
        }
    }
}

extension JPEG.Data.Spectral {
    /// Encodes the DC coefficient of one block, first pass.
    ///
    /// The mirror of the decoder: the value is shifted down by the point
    /// transform and then coded as a difference, exactly as a sequential DC
    /// coefficient is.
    func encode(
        dcFirst block: (x: Int, y: Int),
        plane: Int,
        encoder: JPEG.Table.Huffman.Encoder,
        to bits: inout JPEG.BitstreamWriter,
        predictor: inout Int32,
        approximation: Int
    ) throws {
        let value: Int32 =
            .init(self.planes[plane][x: block.x, y: block.y, z: 0]) >> Int32(approximation)
        let difference: Int = .init(value - predictor)
        predictor = value

        let amplitude: (category: Int, bits: UInt16) =
            JPEG.BitstreamWriter.amplitude(of: difference)
        guard amplitude.category <= 15 else {
            throw JPEG.EncodingError.coefficientOutOfRange(difference)
        }
        try encoder.encode(.init(truncatingIfNeeded: amplitude.category), to: &bits)
        bits.write(amplitude.bits, count: amplitude.category)
    }

    /// Refines the DC coefficient of one block by one bit.
    ///
    /// No Huffman coding at all — one raw bit per block, which is why a DC
    /// refinement scan needs no table.
    func encode(
        dcRefining block: (x: Int, y: Int),
        plane: Int,
        to bits: inout JPEG.BitstreamWriter,
        approximation: Int
    ) {
        let value: Int32 = .init(self.planes[plane][x: block.x, y: block.y, z: 0])
        bits.write(.init(truncatingIfNeeded: (value >> Int32(approximation)) & 1), count: 1)
    }

    /// Encodes a band of AC coefficients, first pass.
    func encode(
        acFirst block: (x: Int, y: Int),
        plane: Int,
        encoder: JPEG.Table.Huffman.Encoder,
        to bits: inout JPEG.BitstreamWriter,
        band: Range<Int>,
        approximation: Int,
        progression: inout JPEG.Progression
    ) throws {
        var run: Int = 0
        for k: Int in band {
            let coefficient: Int = .init(
                self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]]
            )
            // Toward zero, not floor: the point transform discards magnitude,
            // and rounding a negative value away from zero would make it grow.
            let value: Int = coefficient < 0
                ? -((-coefficient) >> approximation)
                : coefficient >> approximation

            guard value != 0 else {
                run += 1
                continue
            }

            // A pending end-of-band run has to be written before anything else
            // can be, since it describes blocks that came earlier.
            try progression.flush(to: &bits, using: encoder)

            while run >= 16 {
                try encoder.encode(0xF0, to: &bits)
                run -= 16
            }

            let amplitude: (category: Int, bits: UInt16) =
                JPEG.BitstreamWriter.amplitude(of: value)
            guard amplitude.category <= 15 else {
                throw JPEG.EncodingError.coefficientOutOfRange(value)
            }
            try encoder.encode(
                .init(truncatingIfNeeded: run << 4 | amplitude.category), to: &bits
            )
            bits.write(amplitude.bits, count: amplitude.category)
            run = 0
        }

        // A trailing run joins the end-of-band run rather than being coded.
        if run > 0 {
            progression.endOfBand()
            if progression.eobrun == 0x7FFF {
                try progression.flush(to: &bits, using: encoder)
            }
        }
    }

    /// Refines a band of AC coefficients by one bit.
    ///
    /// The intricate one, and the mirror of the decoder's hardest procedure.
    /// Two streams share one bit sequence: Huffman symbols announce
    /// coefficients that become nonzero at this bit position, while every
    /// coefficient that was *already* nonzero contributes a raw correction bit.
    ///
    /// The ordering rule is what makes it fiddly. Correction bits for a stretch
    /// are emitted after the symbol that ends that stretch, so they are queued;
    /// and the zero run a symbol carries counts only positions that are still
    /// zero, so an already-nonzero coefficient passed on the way does not
    /// advance it.
    func encode(
        acRefining block: (x: Int, y: Int),
        plane: Int,
        encoder: JPEG.Table.Huffman.Encoder,
        to bits: inout JPEG.BitstreamWriter,
        band: Range<Int>,
        approximation: Int,
        progression: inout JPEG.Progression
    ) throws {
        // The magnitudes at this bit position, and where the last newly nonzero
        // coefficient sits. Everything past that point is either zero or a
        // correction, which is what lets the tail fold into an end-of-band run.
        var magnitudes: [Int] = .init(repeating: 0, count: 64)
        var last: Int = band.lowerBound - 1
        for k: Int in band {
            let coefficient: Int = .init(
                self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]]
            )
            let magnitude: Int = (coefficient < 0 ? -coefficient : coefficient) >> approximation
            magnitudes[k] = magnitude
            if magnitude == 1 {
                last = k
            }
        }

        var run: Int = 0
        for k: Int in band {
            let magnitude: Int = magnitudes[k]

            guard magnitude != 0 else {
                run += 1
                continue
            }

            // Sixteen still-zero positions need an explicit ZRL, but only while
            // a newly nonzero coefficient is still to come; past that the run
            // folds into the end-of-band run instead.
            while run > 15, k <= last {
                try progression.flush(to: &bits, using: encoder)
                try encoder.encode(0xF0, to: &bits)
                run -= 16
                progression.flushPending(to: &bits)
            }

            guard magnitude == 1 else {
                // Already nonzero: this position contributes a correction bit
                // and does not interrupt the run.
                progression.append(correction: .init(magnitude & 1))
                continue
            }

            try progression.flush(to: &bits, using: encoder)

            let coefficient: Int = .init(
                self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]]
            )
            try encoder.encode(.init(truncatingIfNeeded: run << 4 | 1), to: &bits)
            // Magnitude is always exactly one here, so only the sign is sent.
            bits.write(coefficient < 0 ? 0 : 1, count: 1)
            progression.flushPending(to: &bits)
            run = 0
        }

        if run > 0 || !progression.pending.isEmpty {
            progression.endOfBand()
            if progression.eobrun == 0x7FFF {
                try progression.flush(to: &bits, using: encoder)
            }
        }
    }
}
