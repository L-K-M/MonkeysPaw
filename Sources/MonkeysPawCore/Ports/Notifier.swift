/// Drivers render DeliveryStrings using the native chord, without stealing focus.
public protocol Notifier {
    func copied()
    func pressPaste(chord: PasteChord, reason: CopyReason)
}
