/// Drivers render DeliveryStrings using the native chord, without stealing focus.
public protocol Notifier {
    func copied()
    func pressPaste(chord: PasteChord, reason: CopyReason)
    func pressPaste(chord: PasteChord, reason: CopyReason, target: DeliveryTarget?)
}

public extension Notifier {
    func pressPaste(chord: PasteChord, reason: CopyReason, target: DeliveryTarget?) {
        pressPaste(chord: chord, reason: reason)
    }
}
