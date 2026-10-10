public protocol EntropySource {
    /// Return exactly count bytes. A failing source must throw a sanitized error.
    func bytes(count: Int) throws -> [UInt8]
}
