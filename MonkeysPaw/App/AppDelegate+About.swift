import AppKit
import MonkeysPawCore

extension AppDelegate {
    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: Self.aboutPanelOptions(bundle: .main))
    }

    static func aboutPanelOptions(bundle: Bundle) -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(string: Strings.aboutDescription + "\n\n")
        let link = NSAttributedString(string: Strings.projectLink, attributes: [
            .link: URL(string: "https://github.com/L-K-M/MonkeysPaw")!
        ])
        credits.append(link)
        return [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits
        ]
    }
}
