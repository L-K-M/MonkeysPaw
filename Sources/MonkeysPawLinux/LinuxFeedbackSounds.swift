#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GtkMediaFile playback for short picker and delivery cues.
///
/// Core's WishCardCue synthesizes the WAVs; they are written once at first
/// play to the private runtime directory. Files, not memory streams: GTK's
/// GStreamer backend asserts (aborting the app) on stream-backed media
/// files. Without a runtime directory, or if writing fails, the cues stay
/// silent. Every GtkMediaFile is retained until its stream reports
/// "ended" or "error", then released through an idle source so the object
/// cannot finalize inside its own signal emission or call stack.
///
/// Silence is the default: a nil environment (tests and non-runtime callers),
/// `MONKEYSPAW_SOUNDS=0`, and any test process all disable playback entirely.
/// `play` runs on the GTK UI thread only.
final class LinuxFeedbackSounds {
    /// The shared cue identifiers, synthesized by Core.
    typealias Sound = WishCardCue

    private static let playbackLifetime = 3.0

    private let enabled: Bool
    private let directory: URL?
    private var files: [Sound: String]?
    private var playing = Set<UnsafeMutableRawPointer>()

    init(environment: [String: String]? = nil) {
        guard let environment, environment["MONKEYSPAW_SOUNDS"] != "0" else {
            enabled = false
            directory = nil
            return
        }
        enabled = environment["XCTestConfigurationFilePath"] == nil
            && !ProcessInfo.processInfo.processName.lowercased().contains("xctest")
        directory = LinuxPaths(environment: environment).runtimeDirectory?
            .appendingPathComponent("sounds", isDirectory: true)
    }

    func play(_ sound: Sound) {
        guard enabled else { return }
        precondition(Thread.isMainThread, "LinuxFeedbackSounds.play requires the GTK thread")
        guard mp_settings_boolean(sound.settingName) != 0 else { return }

        guard let path = cachedFile(for: sound), let file = gtk_media_file_new_for_filename(path) else { return }

        let media = UnsafeMutableRawPointer(file)
        let mediaStream = media.assumingMemoryBound(to: GtkMediaStream.self)

        // With no usable backend the error may already be set before any notify.
        guard gtk_media_stream_get_error(mediaStream) == nil else {
            g_object_unref(media)
            return
        }

        playing.insert(media)
        GTK.onNotify(media, "ended") { [self] in
            if gtk_media_stream_get_ended(mediaStream) != 0 { release(media) }
        }
        GTK.onNotify(media, "error") { [self] in
            if gtk_media_stream_get_error(mediaStream) != nil { release(media) }
        }
        GTK.onNotify(media, "prepared") { [self] in
            guard playing.contains(media), gtk_media_stream_is_prepared(mediaStream) != 0 else { return }
            if gtk_media_stream_get_error(mediaStream) == nil { gtk_media_stream_play(mediaStream) }
            else { release(media) }
        }
        if gtk_media_stream_is_prepared(mediaStream) != 0 {
            if gtk_media_stream_get_error(mediaStream) == nil { gtk_media_stream_play(mediaStream) }
            else { release(media) }
        }
        // A broken backend may never prepare or finish. Bound its ownership
        // without polling or blocking the UI thread.
        GTK.after(Self.playbackLifetime) { [weak self] in self?.release(media) }
    }

    /// First play writes all cues so later calls never resample.
    private func cachedFile(for sound: Sound) -> String? {
        if files == nil { files = directory.map(Self.writeCues) ?? [:] }
        return files?[sound]
    }

    /// Writes every cue into `directory` (created private) and returns their
    /// paths; any failure returns none, which keeps playback silent.
    static func writeCues(to directory: URL) -> [Sound: String] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var written: [Sound: String] = [:]
            for sound in Sound.allCases {
                let url = directory.appendingPathComponent("\(sound).wav")
                try wavData(for: sound).write(to: url, options: .atomic)
                written[sound] = url.path
            }
            return written
        } catch {
            return [:]
        }
    }

    private func release(_ media: UnsafeMutableRawPointer) {
        guard playing.remove(media) != nil else { return }
        // A notify can fire inside gtk_media_stream_play or GTK's own callback;
        // deferring the unref keeps the object alive until that stack unwinds.
        GTK.onMainLoop { g_object_unref(media) }
    }

    /// A canonical 44-byte PCM RIFF stream: 44.1 kHz, mono, 16-bit little
    /// endian, synthesized deterministically by Core.
    static func wavData(for sound: Sound) -> Data {
        Data(sound.wav)
    }
}

private extension WishCardCue {
    /// GtkSettings gate: ticks are input feedback, the rest event sounds.
    var settingName: String {
        switch self {
        case .tick: return "gtk-enable-input-feedback-sounds"
        case .ready, .take, .nudge, .crack: return "gtk-enable-event-sounds"
        }
    }
}
#endif
