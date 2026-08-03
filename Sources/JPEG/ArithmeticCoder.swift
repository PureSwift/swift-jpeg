extension JPEG.Arithmetic {
    /// The arithmetic decoder of T.81 §D.2.
    ///
    /// An interval subdivision coder. The register `a` holds the width of the
    /// current probability interval and `c` the offset into it; each decision
    /// splits `a` in proportion to the context's estimate, and whichever
    /// subinterval `c` lands in is the symbol. When `a` grows too small to
    /// subdivide meaningfully it is renormalized, which is where fresh input
    /// bits enter.
    public struct Decoder {
        private let bytes: [UInt8]
        private var index: Int
        /// The interval width.
        private var a: Int32
        /// The offset within it.
        private var c: Int32
        /// Bits remaining before more input is needed.
        private var ct: Int
        /// Whether a marker has been reached.
        ///
        /// Unlike Huffman coding, running into a marker mid-stream is legal
        /// here: the convention is to keep supplying zero bytes until decoding
        /// finishes, because the coder can consume more bits than were actually
        /// written.
        private var exhausted: Bool

        public init(_ bytes: [UInt8]) {
            self.bytes = bytes
            self.index = 0
            self.a = 0
            self.c = 0
            self.ct = -16
            self.exhausted = false
        }

        /// Reads the next byte, unstuffing and stopping at a marker.
        private mutating func byte() -> Int32 {
            guard !self.exhausted, self.index < self.bytes.count else {
                self.exhausted = true
                return 0
            }
            var value: UInt8 = self.bytes[self.index]
            self.index += 1

            guard value == 0xFF else {
                return .init(value)
            }
            // A run of 0xFF is padding; what follows decides whether this is a
            // stuffed literal or the end of the data.
            while self.index < self.bytes.count, self.bytes[self.index] == 0xFF {
                self.index += 1
            }
            guard self.index < self.bytes.count else {
                self.exhausted = true
                return 0
            }
            value = self.bytes[self.index]
            self.index += 1
            guard value == 0x00 else {
                self.exhausted = true
                return 0
            }
            return 0xFF
        }

        /// Decodes one binary decision in the given context.
        public mutating func decode(_ context: inout Context) -> Int {
            // Renormalize first, per D.2.6, pulling in input as needed.
            while self.a < 0x8000 {
                self.ct -= 1
                if self.ct < 0 {
                    self.c = self.c << 8 | self.byte()
                    self.ct += 8
                    if self.ct < 0 {
                        self.ct += 1
                        if self.ct == 0 {
                            // Two initial bytes are in; the interval is now
                            // meaningful.
                            self.a = 0x8000
                        }
                    }
                }
                self.a <<= 1
            }

            // The sense *before* any update. The decoded symbol is defined
            // relative to it, and the conditional exchange can flip the stored
            // sense independently — so reading the answer back out of the new
            // context gives the wrong bit exactly when the exchange fires.
            let sense: UInt8 = context & 0x80
            let more: Int = .init(sense >> 7)
            let less: Int = more ^ 1
            let state: State = JPEG.Arithmetic.states[.init(context & 0x7F)]

            /// The state to store after coding the less probable symbol, whose
            /// sense flips when the estimator decides the two have swapped.
            var afterLess: UInt8 {
                (sense ^ (state.exchange ? 0x80 : 0)) | .init(truncatingIfNeeded: state.lps)
            }
            var afterMore: UInt8 {
                sense | .init(truncatingIfNeeded: state.mps)
            }

            var temp: Int32 = self.a - state.qe
            self.a = temp
            temp <<= Int32(self.ct)

            if self.c >= temp {
                self.c -= temp
                // The offset fell in the lower subinterval. That normally means
                // the less probable symbol — unless the interval has shrunk
                // past the estimate, in which case the roles have exchanged.
                // The comparison uses the reduced width, so it must happen
                // before the width is replaced.
                let exchanged: Bool = self.a < state.qe
                self.a = state.qe
                context = exchanged ? afterMore : afterLess
                return exchanged ? more : less
            }

            if self.a < 0x8000 {
                let exchanged: Bool = self.a < state.qe
                context = exchanged ? afterLess : afterMore
                return exchanged ? less : more
            }

            // The interval is still wide enough to subdivide again, so nothing
            // is renormalized and nothing re-estimated.
            return more
        }
    }
}

extension JPEG.Arithmetic {
    /// The arithmetic encoder of T.81 §D.1.
    ///
    /// The mirror of the decoder, with one complication it does not have:
    /// output carries. Adding to the offset register can propagate a carry into
    /// bytes already produced, so a byte cannot be released until it is known
    /// that nothing will change it. Pending `0xFF` bytes are stacked and
    /// pending zeros counted, and both are resolved when the next definite byte
    /// arrives.
    public struct Encoder {
        private var bytes: [UInt8]
        private var a: Int32
        private var c: Int32
        private var ct: Int
        /// The byte awaiting release, or negative if there is none yet.
        private var buffer: Int
        /// Stacked `0xFF` bytes, which a carry would turn into zeros.
        private var stacked: Int
        /// Pending zero bytes.
        private var zeros: Int

        public init() {
            self.bytes = []
            self.a = 0x10000
            self.c = 0
            self.ct = 11
            self.buffer = -1
            self.stacked = 0
            self.zeros = 0
        }

        private mutating func emit(_ value: UInt8) {
            self.bytes.append(value)
            // Byte stuffing, exactly as in Huffman-coded data: a literal 0xFF
            // is followed by a zero so it cannot be read as a marker.
            if value == 0xFF {
                self.bytes.append(0x00)
            }
        }

        private mutating func flushZeros() {
            while self.zeros > 0 {
                self.bytes.append(0x00)
                self.zeros -= 1
            }
        }

        /// Releases the pending byte, incremented by a carry.
        private mutating func carry() {
            if self.buffer >= 0 {
                self.flushZeros()
                self.emit(.init(truncatingIfNeeded: self.buffer + 1))
            }
            // The carry turns every stacked 0xFF into 0x00.
            self.zeros += self.stacked
            self.stacked = 0
        }

        /// Releases the pending byte unchanged.
        private mutating func settle() {
            if self.buffer == 0 {
                self.zeros += 1
            } else if self.buffer >= 0 {
                self.flushZeros()
                self.emit(.init(truncatingIfNeeded: self.buffer))
            }
            if self.stacked > 0 {
                self.flushZeros()
                while self.stacked > 0 {
                    self.bytes.append(0xFF)
                    self.bytes.append(0x00)
                    self.stacked -= 1
                }
            }
        }

        /// Encodes one binary decision in the given context.
        public mutating func encode(_ context: inout Context, _ value: Int) {
            let sense: UInt8 = context & 0x80
            let state: State = JPEG.Arithmetic.states[.init(context & 0x7F)]

            self.a -= state.qe

            if value != .init(sense >> 7) {
                // The less probable symbol. The interval exchange below affects
                // only the arithmetic; the state always advances along the LPS
                // path, because the encoder knows what it just wrote.
                if self.a >= state.qe {
                    self.c += self.a
                    self.a = state.qe
                }
                context = sense ^ (state.exchange ? 0x80 : 0)
                    | .init(truncatingIfNeeded: state.lps)
            } else {
                if self.a >= 0x8000 {
                    // Still a usable interval, so nothing to renormalize and
                    // nothing to re-estimate.
                    return
                }
                if self.a < state.qe {
                    self.c += self.a
                    self.a = state.qe
                }
                context = sense | .init(truncatingIfNeeded: state.mps)
            }

            repeat {
                self.a <<= 1
                self.c <<= 1
                self.ct -= 1
                if self.ct == 0 {
                    let temp: Int32 = self.c >> 19
                    if temp > 0xFF {
                        self.carry()
                        self.buffer = .init(temp & 0xFF)
                    } else if temp == 0xFF {
                        self.stacked += 1
                    } else {
                        self.settle()
                        self.buffer = .init(temp & 0xFF)
                    }
                    self.c &= 0x7FFFF
                    self.ct += 8
                }
            } while self.a < 0x8000
        }

        /// Flushes the coder and returns the finished data.
        public mutating func finish() -> [UInt8] {
            // Choose the shortest offset that still lies in the final interval.
            let temp: Int32 = (self.a &- 1 &+ self.c) & Int32(bitPattern: 0xFFFF_0000)
            self.c = temp < self.c ? temp &+ 0x8000 : temp
            self.c <<= Int32(self.ct)

            if self.c & Int32(bitPattern: 0xF800_0000) != 0 {
                self.carry()
            } else {
                self.settle()
            }

            if self.c & 0x7FF_F800 != 0 {
                self.flushZeros()
                self.emit(.init(truncatingIfNeeded: (self.c >> 19) & 0xFF))
                if self.c & 0x7F800 != 0 {
                    self.emit(.init(truncatingIfNeeded: (self.c >> 11) & 0xFF))
                }
            }

            defer {
                self = .init()
            }
            return self.bytes
        }
    }
}
