extension JPEG {
    /// Anything that can go wrong reading or writing a JPEG stream.
    ///
    /// The four stage-specific enumerations remain the useful classification —
    /// see ``Error`` for why the stage is the thing worth knowing. This gathers
    /// them into one concrete type so that every function in the engine can
    /// declare *which* errors it throws rather than throwing `any Error`.
    ///
    /// That declaration is not decoration. An untyped `throws` is
    /// `throws(any Error)`, and an existential needs the runtime machinery that
    /// Embedded Swift does not have — so the engine could not be built for an
    /// embedded target while any of its functions threw one. Typed throws is
    /// what makes the engine's no-imports discipline actually reach the target
    /// it was for.
    ///
    /// A caller who wants the specific failure switches on it; a caller who
    /// only wants to report it reads ``message`` and ``details``, which forward
    /// to whichever error is inside.
    public enum Failure: JPEG.Error {
        /// The byte stream is not shaped like a JPEG.
        case lexing(JPEG.LexingError)
        /// A marker segment was found but its contents are not self-consistent.
        case parsing(JPEG.ParsingError)
        /// The segments are individually valid but do not agree with one
        /// another.
        case decoding(JPEG.DecodingError)
        /// The image cannot be written as asked.
        case encoding(JPEG.EncodingError)
    }
}

extension JPEG.Failure {
    /// The stage that produced this failure.
    ///
    /// Static on the protocol, because there it names the enumeration; here it
    /// has to come from the case, so this reports the stage of whatever is
    /// wrapped rather than a name for the wrapper, which would tell a caller
    /// nothing.
    public static var namespace: String {
        "JPEG error"
    }

    // No `underlying: any JPEG.Error` accessor. It would be the obvious
    // convenience, and it is exactly the thing this type exists to avoid: an
    // existential is what Embedded Swift cannot represent. Callers that want
    // the specific error switch on the case, which is better typed anyway.

    /// The stage name of the wrapped error.
    public var stage: String {
        switch self {
        case .lexing:   return JPEG.LexingError.namespace
        case .parsing:  return JPEG.ParsingError.namespace
        case .decoding: return JPEG.DecodingError.namespace
        case .encoding: return JPEG.EncodingError.namespace
        }
    }

    public var message: String {
        switch self {
        case .lexing(let error):    return error.message
        case .parsing(let error):   return error.message
        case .decoding(let error):  return error.message
        case .encoding(let error):  return error.message
        }
    }

    public var details: String? {
        switch self {
        case .lexing(let error):    return error.details
        case .parsing(let error):   return error.details
        case .decoding(let error):  return error.details
        case .encoding(let error):  return error.details
        }
    }
}
