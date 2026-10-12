import Foundation
import MonkeysPawCore
import UserNotifications

struct UserNotificationNotifier: Notifier, LibraryAvailabilityNotifier {
    // The center's delegate is weak; retain this stateless delegate for its lifetime.
    private static let foregroundDelegate = ForegroundNotificationDelegate()
    private let requestAuthorization: (UNUserNotificationCenter, @escaping (Bool) -> Void) -> Void
    private let submit: (UNUserNotificationCenter, UNNotificationRequest) -> Void

    init(requestAuthorization: @escaping (UNUserNotificationCenter, @escaping (Bool) -> Void) -> Void = { center, completion in
        center.requestAuthorization(options: [.alert]) { granted, _ in completion(granted) }
    }, submit: @escaping (UNUserNotificationCenter, UNNotificationRequest) -> Void = { center, request in
        center.add(request, withCompletionHandler: nil)
    }) {
        self.requestAuthorization = requestAuthorization
        self.submit = submit
    }

    func copied() { notify(DeliveryStrings.copied) }

    func pressPaste(chord: PasteChord, reason: CopyReason) {
        notify(DeliveryStrings.pressCommandV)
    }

    func libraryUnavailable() {
        notify(OnboardingStrings.libraryUnavailableNotificationBody,
               title: OnboardingStrings.libraryUnavailableNotificationTitle)
    }

    private func notify(_ text: String, title: String = AppIdentity.displayName) {
        // Resolve the center and ask only for a notification. Healthy startup
        // never requests permission; unavailable startup shares this path.
        let center = UNUserNotificationCenter.current()
        center.delegate = Self.foregroundDelegate
        requestAuthorization(center) { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            // No actions or sound: a fallback must leave focus in the paste target.
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            self.submit(center, request)
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
