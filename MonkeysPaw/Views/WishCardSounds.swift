import AppKit
import MonkeysPawCore

/// NSSound's delegate is not an ownership guarantee: retain every overlapping
/// crack until its completion callback, even when the next exposure has begun.
final class WishCardSounds: NSObject, NSSoundDelegate {
    private var playing: [NSSound] = []
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        super.init()
    }

    static func preferenceEnabled(system: Any?, global: Any?) -> Bool {
        // Sound Effects uses com.apple.systemsound; older systems used the
        // global domain. beep.feedback controls volume-key feedback instead.
        ((system ?? global) as? NSNumber)?.boolValue ?? true
    }

    func play(_ cue: WishCardCue) {
        guard !AppDelegate.isRunningTests, environment["MONKEYSPAW_SOUNDS"] != "0" else { return }
        let key = "com.apple.sound.uiaudio.enabled"
        let defaults = UserDefaults.standard
        guard Self.preferenceEnabled(system: defaults.persistentDomain(forName: "com.apple.systemsound")?[key],
            global: defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key]),
              let sound = NSSound(data: Data(cue.wav)) else { return }
        sound.delegate = self
        playing.append(sound)
        if !sound.play() { playing.removeAll { $0 === sound } }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.playing.removeAll { $0 === sound } }
    }
}
