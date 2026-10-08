import Foundation
import MonkeysPawCore
import UserNotifications

struct UserNotificationNotifier: Notifier {
    func copied() { notify(DeliveryStrings.copied) }

    func pressPaste(chord: PasteChord, reason: CopyReason) {
        notify(DeliveryStrings.pressCommandV)
    }

    private func notify(_ text: String) {
        // Resolve the center and ask only when a notification is needed, never at launch.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = AppIdentity.displayName
            content.body = text
            // No actions or sound: a fallback must leave focus in the paste target.
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
