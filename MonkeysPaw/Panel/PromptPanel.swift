import AppKit
import MonkeysPawCore

/// NSPanel flags follow Vervellum's ResearchPanel recipe (§4.6).
///
/// * `.nonactivatingPanel`: showing the panel does not make Monkey's Paw the
///   active application by itself. That is what lets it appear over a full-screen
///   app without macOS switching Spaces to find Monkey's Paw a home.
/// * `canBecomeKey` overridden to true: a borderless panel refuses key status
///   by default, and a panel that cannot become key cannot receive typing. This one
///   override is the difference between a composer that works and one that silently
///   swallows every keystroke.
/// * `canBecomeMain` left false: main status belongs to the app the user was
///   actually working in. Taking it would put Monkey's Paw's (nonexistent) menu bar
///   up and make the previous app's title bar go inactive.
final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The controller owns hiding so cancellation follows the same UI-thread path.
    var onCancel: (() -> Void)?

    convenience init(content: NSView) {
        self.init(contentRect: NSRect(x: 0, y: 0,
                                      width: CGFloat(Limits.panelSize.width),
                                      height: CGFloat(Limits.panelSize.height)),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)

        // An NSHostingView used directly as a borderless panel's content view
        // drives the window's size from its intrinsic content and grows from the
        // bottom-left origin. A container keeps the frame under our control;
        // only the content resizes.
        let container = NSView(frame: contentRect(forFrameRect: frame))
        container.autoresizesSubviews = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        content.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(content)
        contentView = container

        configure()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func configure() {
        isFloatingPanel = true
        // Default already, but stated because the opposite is an active hazard here:
        // with `becomesKeyOnlyIfNeeded` true a non-activating panel becomes key only
        // if the hit view returns true from `needsPanelToBecomeKey`, which `NSView`
        // does not. It has no bearing on a programmatic `makeKey()`.
        becomesKeyOnlyIfNeeded = false
        hasShadow = true
        // `.floating` (3), not `.popUpMenu` (101). Level orders windows within a
        // Space; appearing over a full-screen app is collectionBehavior's job.
        // A higher level would cover the menu bar, Dock and real NSMenus,
        // including our own status menu. Floating stays below system chrome.
        level = .floating
        isReleasedWhenClosed = false
        isRestorable = false
        // NSPanel overrides NSWindow's default and hides on deactivate. Left
        // alone, the panel would vanish when another app takes focus. Hiding
        // belongs to the controller rather than this AppKit default.
        hidesOnDeactivate = false
        // The flags that put the panel over another app's full-screen window:
        //   .canJoinAllSpaces       : it exists on every Space, so showing it needs
        //                             no Space switch. A .moveToActiveSpace panel
        //                             would drag the user out of a full-screen app.
        //   .canJoinAllApplications : it may join other applications' full-screen
        //                             Spaces. Apple documents this for floating
        //                             windows and system overlays; fullScreenAuxiliary
        //                             alone is for the same app's full-screen window.
        //   .fullScreenAuxiliary    : kept alongside it for the same-app case.
        //   .transient              : Mission Control hides the panel rather than
        //                             floating it on top, which stationary would do.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .transient]
    }
}
