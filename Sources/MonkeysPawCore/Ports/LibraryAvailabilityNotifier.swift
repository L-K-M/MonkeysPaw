/// Startup recovery notifications, independent of delivery's Notifier port.
/// Drivers render OnboardingStrings' path-free notification without taking focus.
public protocol LibraryAvailabilityNotifier {
    func libraryUnavailable()
}
