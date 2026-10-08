public protocol Clipboard {
    func writeText(_ text: String)
    func readText() -> String?
}
