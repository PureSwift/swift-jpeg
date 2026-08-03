extension JPEG.Data.Spectral {
    /// Entropy codes one sequential arithmetic scan.
    ///
    /// The exact mirror of the decoder. Where the decoder deduces each value
    /// from a sequence of decisions, this poses the same sequence and answers
    /// it — so the two walk identical context trees and neither needs to
    /// transmit anything about them.
    func encode(
        arithmetic scan: JPEG.Header.Scan,
        conditioning: JPEG.Arithmetic.Conditioners,
        restartInterval: Int
    ) throws -> [UInt8] {
        let planes: [Int] = try self.layout.validate(scan: scan)
        let interleaved: Bool = planes.count > 1
        let units: (x: Int, y: Int) = interleaved
            ? self.layout.mcus
            : self.layout.blocks(plane: planes[0], scan: scan)
        let total: Int = units.x * units.y

        var output: [UInt8] = []
        var coder: JPEG.Arithmetic.Encoder = .init()
        var statistics: JPEG.Arithmetic.Statistics = .init(planes: self.planes.count)
        statistics.prepare(scan)
        var phase: Int = 0

        for index: Int in 0 ..< total {
            let unit: (x: Int, y: Int) = (x: index % units.x, y: index / units.x)

            for (component, plane): (Int, Int) in planes.enumerated() {
                let bound: JPEG.ScanComponent = scan.components[component]
                let sampling: JPEG.Component.Sampling = interleaved
                    ? self.layout.planes[plane].sampling
                    : .init(x: 1, y: 1)

                for v: Int in 0 ..< sampling.y {
                    for h: Int in 0 ..< sampling.x {
                        let block: (x: Int, y: Int) = interleaved
                            ? (
                                x: unit.x * sampling.x + h,
                                y: unit.y * sampling.y + v
                            )
                            : unit

                        self.encode(
                            arithmetic: block,
                            plane: plane,
                            component: bound,
                            conditioning: conditioning,
                            coder: &coder,
                            statistics: &statistics,
                            slot: plane
                        )
                    }
                }
            }

            if restartInterval > 0,
               (index + 1) % restartInterval == 0,
               index + 1 < total
            {
                // The coder is flushed and everything it learned is discarded,
                // which is what lets the next interval stand alone.
                output.append(contentsOf: coder.finish())
                output.append(0xFF)
                output.append(0xD0 + .init(truncatingIfNeeded: phase))
                phase = (phase + 1) & 7
                coder = .init()
                statistics = .init(planes: self.planes.count)
                statistics.prepare(scan)
            }
        }

        output.append(contentsOf: coder.finish())
        return output
    }

    private func encode(
        arithmetic block: (x: Int, y: Int),
        plane: Int,
        component: JPEG.ScanComponent,
        conditioning: JPEG.Arithmetic.Conditioners,
        coder: inout JPEG.Arithmetic.Encoder,
        statistics: inout JPEG.Arithmetic.Statistics,
        slot: Int
    ) {
        let dcConditioning: JPEG.Arithmetic.Conditioning = conditioning.dc(component.dc)
        let acConditioning: JPEG.Arithmetic.Conditioning = conditioning.ac(component.ac)

        // -- the DC difference -----------------------------------------------
        var dc: [JPEG.Arithmetic.Context] = statistics.dc[component.dc] ?? .init(
            repeating: 0, count: 64
        )
        let base: Int = statistics.contexts[slot]
        let coefficient: Int32 = .init(self.planes[plane][x: block.x, y: block.y, z: 0])
        var difference: Int = .init(coefficient - statistics.predictors[slot])

        if difference == 0 {
            coder.encode(&dc[base], 0)
            statistics.contexts[slot] = 0
        } else {
            statistics.predictors[slot] = coefficient
            coder.encode(&dc[base], 1)

            var index: Int
            if difference > 0 {
                coder.encode(&dc[base + 1], 0)
                index = base + 2
                statistics.contexts[slot] = 4
            } else {
                difference = -difference
                coder.encode(&dc[base + 1], 1)
                index = base + 3
                statistics.contexts[slot] = 8
            }

            var magnitude: Int = 0
            difference -= 1
            if difference != 0 {
                coder.encode(&dc[index], 1)
                magnitude = 1
                var remaining: Int = difference
                index = 20
                while true {
                    remaining >>= 1
                    guard remaining != 0 else {
                        break
                    }
                    coder.encode(&dc[index], 1)
                    magnitude <<= 1
                    index += 1
                }
            }
            coder.encode(&dc[index], 0)

            if magnitude < (1 << dcConditioning.lower) >> 1 {
                statistics.contexts[slot] = 0
            } else if magnitude > (1 << dcConditioning.upper) >> 1 {
                statistics.contexts[slot] += 8
            }

            index += 14
            var bit: Int = magnitude
            while true {
                bit >>= 1
                guard bit != 0 else {
                    break
                }
                coder.encode(&dc[index], bit & difference != 0 ? 1 : 0)
            }
        }
        statistics.dc[component.dc] = dc

        // -- the AC coefficients ---------------------------------------------
        var ac: [JPEG.Arithmetic.Context] = statistics.ac[component.ac] ?? .init(
            repeating: 0, count: 256
        )
        defer {
            statistics.ac[component.ac] = ac
        }

        // The last nonzero coefficient, so the end-of-block decision is posed
        // exactly once rather than at every position.
        var last: Int = 63
        while last > 0, self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[last]] == 0 {
            last -= 1
        }

        var k: Int = 1
        while k <= last {
            var index: Int = 3 * (k - 1)
            coder.encode(&ac[index], 0)

            while self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]] == 0 {
                coder.encode(&ac[index + 1], 0)
                index += 3
                k += 1
            }
            coder.encode(&ac[index + 1], 1)

            var value: Int = .init(
                self.planes[plane][x: block.x, y: block.y, z: JPEG.zigzag[k]]
            )
            if value > 0 {
                coder.encode(&statistics.fixed, 0)
            } else {
                value = -value
                coder.encode(&statistics.fixed, 1)
            }
            index += 2

            var magnitude: Int = 0
            value -= 1
            if value != 0 {
                coder.encode(&ac[index], 1)
                magnitude = 1
                var remaining: Int = value
                remaining >>= 1
                if remaining != 0 {
                    coder.encode(&ac[index], 1)
                    magnitude <<= 1
                    index = k <= acConditioning.kx ? 189 : 217
                    while true {
                        remaining >>= 1
                        guard remaining != 0 else {
                            break
                        }
                        coder.encode(&ac[index], 1)
                        magnitude <<= 1
                        index += 1
                    }
                }
            }
            coder.encode(&ac[index], 0)

            index += 14
            var bit: Int = magnitude
            while true {
                bit >>= 1
                guard bit != 0 else {
                    break
                }
                coder.encode(&ac[index], bit & value != 0 ? 1 : 0)
            }
            k += 1
        }

        if k <= 63 {
            coder.encode(&ac[3 * (k - 1)], 1)
        }
    }
}
