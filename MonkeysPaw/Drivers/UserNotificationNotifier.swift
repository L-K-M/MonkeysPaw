import Foundation
import MonkeysPawCore
import UserNotifications

struct UserNotificationNotifier: Notifier {
    // The center's delegate is weak; retain this stateless delegate for its lifetime.
    private static let foregroundDelegate = ForegroundNotificationDelegate()
    private let requestAuthorization: (UNUserNotificationCenter, @escaping (Bool) -> Void) -> Void

    init(requestAuthorization: @escaping (UNUserNotificationCenter, @escaping (Bool) -> Void) -> Void = { center, completion in
        center.requestAuthorization(options: [.alert]) { granted, _ in completion(granted) }
    }) {
        self.requestAuthorization = requestAuthorization
    }

    func copied() { notify(DeliveryStrings.copied) }

    func pressPaste(chord: PasteChord, reason: CopyReason) {
        notify(DeliveryStrings.pressCommandV)
    }

    private func notify(_ text: String) {
        // Resolve the center and ask only when a notification is needed, never at launch.
        let center = UNUserNotificationCenter.current()
        center.delegate = Self.foregroundDelegate
        requestAuthorization(center) { granted in
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

/// Copy-only guidance must remain visible while Setup or the self-test is key.
private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
