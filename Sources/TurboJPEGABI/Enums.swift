import CTurboJPEG

// TurboJPEG's enumerations do not share a raw type. The ones with a negative
// sentinel — TJSAMP_UNKNOWN, TJPF_UNKNOWN, TJCS_DEFAULT, all -1 — import as
// Int32, while the ones without import as UInt32. Since the API passes every
// one of them through `int` parameters, these accessors give a single spelling
// and keep the bit-pattern conversion in one place instead of at each use.

extension TJPARAM {
    var id: Int32 {
        .init(bitPattern: self.rawValue)
    }
}

extension TJINIT {
    var id: Int32 {
        .init(bitPattern: self.rawValue)
    }
}

extension TJERR {
    var id: Int32 {
        .init(bitPattern: self.rawValue)
    }
}

extension TJXOP {
    var id: Int32 {
        .init(bitPattern: self.rawValue)
    }
}
