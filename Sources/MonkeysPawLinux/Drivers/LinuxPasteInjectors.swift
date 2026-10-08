#if os(Linux)
import Foundation
import MonkeysPawCore

final class XdotoolPasteInjector: PasteInjector {
    let backend = PasteBackend.xdotool
    private let runner: LinuxToolRunner
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.xdotool")

    init(runner: LinuxToolRunner = LinuxToolRunner()) { self.runner = runner }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        worker.async {
            let keys = chord == .terminal ? "ctrl+shift+v" : "ctrl+v"
            switch self.runner.run("xdotool", arguments: ["key", "--clearmodifiers", keys]) {
            case .success: completion(.sent)
            case .failure(let failure): completion(.failed(failure))
            }
        }
    }
}

final class YdotoolPasteInjector: PasteInjector {
    let backend = PasteBackend.ydotool
    private enum Syntax { case symbolic, evdev }
    private let runner: LinuxToolRunner
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.ydotool")
    private let socketReachable: (String) -> Bool
    // The serial worker exclusively owns dialect state.
    private var syntax: Syntax?

    init(runner: LinuxToolRunner = LinuxToolRunner(),
         socketReachable: @escaping (String) -> Bool = YdotoolSocket.isReachable) {
        self.runner = runner
        self.socketReachable = socketReachable
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        worker.async {
            completion(self.inject(chord))
        }
    }

    private func inject(_ chord: PasteChord) -> PasteAttemptResult {
        let syntax: Syntax
        switch detectSyntax() {
        case .success(let detected): syntax = detected
        case .failure(let failure): return .failed(failure)
        }

        // 0.1.8 has a fixed socket and ignores YDOTOOL_SOCKET (Copywraith).
        let socket = syntax == .symbolic ? YdotoolSocket.legacyPath
            : YdotoolSocket.path(in: runner.environment)
        guard socketReachable(socket) else { return .failed(.permissionDenied) }

        let keys: [String]
        switch syntax {
        case .symbolic:
            keys = [chord == .terminal ? "ctrl+shift+v" : "ctrl+v"]
        case .evdev:
            // linux/input-event-codes.h: KEY_LEFTCTRL=29, KEY_LEFTSHIFT=42,
            // KEY_V=47. Release in reverse order; never try symbolic as fallback.
            keys = chord == .terminal
                ? ["29:1", "42:1", "47:1", "47:0", "42:0", "29:0"]
                : ["29:1", "47:1", "47:0", "29:0"]
        }
        switch runner.run("ydotool", arguments: ["key"] + keys,
                          environmentOverrides: ["YDOTOOL_SOCKET": socket]) {
        case .success: return .sent
        case .failure(let failure): return .failed(failure)
        }
    }

    private func detectSyntax() -> Result<Syntax, PasteFailure> {
        if let syntax { return .success(syntax) }
        switch runner.run("ydotool", arguments: ["help"], errorOutput: .mergeForHelp,
                          acceptedStatuses: [0, 1]) {
        case .failure(let failure): return .failure(failure)
        case .success(let output):
            guard output.text.contains("Usage: ydotool <cmd> <args>"),
                  output.text.split(separator: "\n").contains(where: {
                      $0.trimmingCharacters(in: .whitespaces) == "key"
                  }) else { return .failure(.unknown) }

            let advertisesSocket = output.text.contains("YDOTOOL_SOCKET")
            if output.status == 0, advertisesSocket {
                syntax = .evdev
                return .success(.evdev)
            }
            if output.status == 1, !advertisesSocket {
                syntax = .symbolic
                return .success(.symbolic)
            }
            return .failure(.unknown)
        }
    }
}
#endif
