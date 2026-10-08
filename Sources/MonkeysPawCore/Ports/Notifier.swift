/// Drivers render DeliveryStrings using the native chord, without stealing focus.
public protocol Notifier {
    func copied(chord: PasteChord)
    func pressPaste(chord: PasteChord, reason: CopyReason)
}
