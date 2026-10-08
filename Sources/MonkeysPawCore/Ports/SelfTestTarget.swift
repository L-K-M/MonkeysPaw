/// UI-thread test window operations (§6.5).
public protocol SelfTestTarget {
    /// Present and focus an empty field. The expected text must not prefill it.
    func present(fieldExpecting text: String)
    func readBack() -> String?
    func close()
}
