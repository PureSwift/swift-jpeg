extension JPEG.Data.Spectral {
    /// The sequence of scans a progressive image is written as.
    ///
    /// This is libjpeg's default script, and matching it matters more than the
    /// specific choices in it: a progressive JPEG's scan structure is entirely
    /// the encoder's decision, so the only meaningful benchmark for "did we
    /// choose sensibly" is the one everything else in the world already uses.
    ///
    /// The shape of it, for colour:
    ///
    /// 1. All DC coefficients at once, minus the bottom bit. A viewer can draw
    ///    a whole, blocky image from this alone.
    /// 2. The first few luminance AC coefficients, coarsely — the fastest way
    ///    to turn those blocks into something recognizable.
    /// 3. Chrominance in one pass each. There is little of it and it is not
    ///    worth spending scans on.
    /// 4. The rest of the luminance AC coefficients, then successive
    ///    refinements, then the bottom bit of each.
    ///
    /// The bottom bit of luminance comes last because it is the largest scan
    /// and the least visible; anything else finishes sooner.
    func progression() -> [JPEG.Header.Scan] {
        let keys: [JPEG.Component.Key] = self.layout.keys

        /// One interleaved scan covering the DC coefficient of every component.
        func dc(from high: Int, to low: Int) -> JPEG.Header.Scan {
            .init(
                band: 0 ..< 1,
                bits: low ..< (high == 0 ? Int.max : high),
                components: keys.enumerated().map {
                    let slot: JPEG.Table.Huffman.Key = .init($0.offset == 0 ? 0 : 1)
                    return .init(component: $0.element, dc: slot, ac: slot)
                }
            )
        }

        /// One scan of a band of one component's AC coefficients.
        ///
        /// Never interleaved: T.81 forbids it, since an MCU made of partial
        /// blocks has no meaning.
        func ac(_ plane: Int, _ band: ClosedRange<Int>, from high: Int, to low: Int)
            -> JPEG.Header.Scan
        {
            let slot: JPEG.Table.Huffman.Key = .init(plane == 0 ? 0 : 1)
            return .init(
                band: band.lowerBound ..< band.upperBound + 1,
                bits: low ..< (high == 0 ? Int.max : high),
                components: [.init(component: keys[plane], dc: slot, ac: slot)]
            )
        }

        guard keys.count == 3 else {
            // The all-purpose script: the same idea without the assumption that
            // component 0 is luminance and deserves the most attention.
            var scans: [JPEG.Header.Scan] = [dc(from: 0, to: 1)]
            for plane: Int in keys.indices {
                scans.append(ac(plane, 1 ... 5, from: 0, to: 2))
            }
            for plane: Int in keys.indices {
                scans.append(ac(plane, 6 ... 63, from: 0, to: 2))
            }
            for plane: Int in keys.indices {
                scans.append(ac(plane, 1 ... 63, from: 2, to: 1))
            }
            scans.append(dc(from: 1, to: 0))
            for plane: Int in keys.indices {
                scans.append(ac(plane, 1 ... 63, from: 1, to: 0))
            }
            return scans
        }

        return [
            dc(from: 0, to: 1),
            ac(0, 1 ... 5, from: 0, to: 2),
            ac(2, 1 ... 63, from: 0, to: 1),
            ac(1, 1 ... 63, from: 0, to: 1),
            ac(0, 6 ... 63, from: 0, to: 2),
            ac(0, 1 ... 63, from: 2, to: 1),
            dc(from: 1, to: 0),
            ac(2, 1 ... 63, from: 1, to: 0),
            ac(1, 1 ... 63, from: 1, to: 0),
            ac(0, 1 ... 63, from: 1, to: 0),
        ]
    }
}

extension JPEG.Data.Spectral {
    /// Builds tables for one scan from that scan's own symbol statistics.
    ///
    /// Progressive scans are not alike: a DC first pass, a five-coefficient AC
    /// band and a full-band refinement produce completely different symbol
    /// distributions, and one shared table would serve none of them well. The
    /// Annex K tables are not even applicable — they describe sequential
    /// statistics — so every scan gets its own.
    ///
    /// A DC refinement scan is not Huffman coded at all and needs none.
    func tables(for scan: JPEG.Header.Scan, restartInterval: Int) throws(JPEG.Failure) -> JPEG.Tables {
        let kind: JPEG.Header.Scan.Kind = scan.kind(process: self.layout.process)
        if case .dc(refining: true) = kind {
            return .init()
        }

        // Slots have to exist before they can be counted into, so this seeds
        // one counter per slot the scan names.
        var seed: JPEG.Tables = .init()
        let empty: (counts: [Int], values: [UInt8]) = (
            counts: [1] + .init(repeating: 0, count: 15), values: [0]
        )
        for component: JPEG.ScanComponent in scan.components {
            seed.push(
                try .init(
                    counts: empty.counts, values: empty.values,
                    target: component.dc, class: .dc
                )
            )
            seed.push(
                try .init(
                    counts: empty.counts, values: empty.values,
                    target: component.ac, class: .ac
                )
            )
        }

        let counting = JPEG.Encoders.counting(like: seed)
        _ = try self.encode(
            scan: scan, encoders: counting.encoders, restartInterval: restartInterval
        )

        var tables: JPEG.Tables = .init()
        for (key, counter) in counting.dc {
            tables.push(try .optimal(frequencies: counter.frequencies, target: key, class: .dc))
        }
        for (key, counter) in counting.ac {
            tables.push(try .optimal(frequencies: counter.frequencies, target: key, class: .ac))
        }
        return tables
    }
}
