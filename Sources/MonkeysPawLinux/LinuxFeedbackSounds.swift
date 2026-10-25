#if os(Linux)
import CGtk
import Foundation

/// GtkMediaFile playback for short picker and delivery cues.
///
/// The four WAVs are synthesized in memory once at first play; each play wraps
/// the bytes in a GBytes-backed GMemoryInputStream, so no audio ever touches
/// the filesystem. Every GtkMediaFile is retained until its stream reports
/// "ended" or "error", then released through an idle source so the object
/// cannot finalize inside its own signal emission or call stack.
///
/// Silence is the default: a nil environment (tests and non-runtime callers),
/// `MONKEYSPAW_SOUNDS=0`, and any test process all disable playback entirely.
/// `play` runs on the GTK UI thread only.
final class LinuxFeedbackSounds {
    enum Sound: CaseIterable {
        case tick, ready, take, nudge

        /// GtkSettings gate: ticks are input feedback, the rest event sounds.
        fileprivate var settingName: String {
            switch self {
            case .tick: return "gtk-enable-input-feedback-sounds"
            case .ready, .take, .nudge: return "gtk-enable-event-sounds"
            }
        }
    }

    private static let sampleRate = 44_100.0
    private static let playbackLifetime = 3.0

    private let enabled: Bool
    private var wavs: [Sound: Data]?
    private var playing = Set<UnsafeMutableRawPointer>()

    init(environment: [String: String]? = nil) {
        guard let environment, environment["MONKEYSPAW_SOUNDS"] != "0" else {
            enabled = false
            return
        }
        enabled = environment["XCTestConfigurationFilePath"] == nil
            && !ProcessInfo.processInfo.processName.lowercased().contains("xctest")
    }

    func play(_ sound: Sound) {
        guard enabled else { return }
        precondition(Thread.isMainThread, "LinuxFeedbackSounds.play requires the GTK thread")
        guard mp_settings_boolean(sound.settingName) != 0 else { return }

        let wav = cachedWAV(for: sound)
        guard let bytes = wav.withUnsafeBytes({ g_bytes_new($0.baseAddress, gsize($0.count)) }) else { return }
        guard let stream = g_memory_input_stream_new_from_bytes(bytes) else {
            g_bytes_unref(bytes)
            return
        }
        g_bytes_unref(bytes)

        // The media file retains the stream through its input-stream property.
        guard let file = gtk_media_file_new_for_input_stream(stream) else {
            g_object_unref(UnsafeMutableRawPointer(stream))
            return
        }
        g_object_unref(UnsafeMutableRawPointer(stream))

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
        if gtk_media_stream_is_prepared(mediaStream) != 0 { gtk_media_stream_play(mediaStream) }
        // A broken backend may never prepare or finish. Bound its ownership
        // without polling or blocking the UI thread.
        GTK.after(Self.playbackLifetime) { [weak self] in self?.release(media) }
    }

    /// First play synthesizes all four cues so later calls never resample.
    private func cachedWAV(for sound: Sound) -> Data {
        if wavs == nil {
            wavs = Dictionary(uniqueKeysWithValues: Sound.allCases.map { ($0, Self.wavData(for: $0)) })
        }
        return wavs?[sound] ?? Data()
    }

    private func release(_ media: UnsafeMutableRawPointer) {
        guard playing.remove(media) != nil else { return }
        // A notify can fire inside gtk_media_stream_play or GTK's own callback;
        // deferring the unref keeps the object alive until that stack unwinds.
        GTK.onMainLoop { g_object_unref(media) }
    }

    /// A canonical 44-byte PCM RIFF stream: 44.1 kHz, mono, 16-bit little
    /// endian. Tests inspect these bytes directly, so output is deterministic.
    static func wavData(for sound: Sound) -> Data {
        let pcm = pcmSamples(for: sound)
        var data = Data()
        data.reserveCapacity(44 + pcm.count * 2)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcm.count * 2), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)              // linear PCM
        appendLittleEndian(UInt16(1), to: &data)              // mono
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate) * 2, to: &data) // byte rate
        appendLittleEndian(UInt16(2), to: &data)              // block align
        appendLittleEndian(UInt16(16), to: &data)             // bits per sample
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(pcm.count * 2), to: &data)
        for sample in pcm { appendLittleEndian(sample, to: &data) }
        return data
    }

    static func pcmSamples(for sound: Sound) -> [Int16] {
        let signal: [Double]
        let decibels: Double
        switch sound {
        case .tick: signal = tickSignal(); decibels = -24
        case .ready: signal = readySignal(); decibels = -22
        case .take: signal = takeSignal(); decibels = -18
        case .nudge: signal = nudgeSignal(); decibels = -22
        }
        return normalize(signal, peakDecibels: decibels)
    }

    /// Normalize so the loudest sample lands exactly on the dBFS ceiling.
    private static func normalize(_ signal: [Double], peakDecibels: Double) -> [Int16] {
        let peak = signal.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return [Int16](repeating: 0, count: signal.count) }
        let scale = pow(10, peakDecibels / 20) / peak
        return signal.map { sample in
            let scaled = (sample * scale * 32_767).rounded()
            return Int16(min(32_767, max(-32_768, scaled)))
        }
    }

    private static func tickSignal() -> [Double] {
        // A 5 ms, 3 kHz bandpassed noise burst decaying to -60 dB; the first
        // 1.5 ms adds a wideband click so the onset reads as a tick, not hiss.
        let count = Int(0.005 * sampleRate)
        let clickCount = Int(0.0015 * sampleRate)
        var bandpass = Bandpass(centerFrequency: 3_000, quality: 4, sampleRate: sampleRate)
        var noise = Noise(seed: 0x5449_434B)
        return (0..<count).map { i in
            var sample = bandpass.process(noise.next()) * decay(Double(i) / Double(count - 1))
            if i < clickCount {
                sample += noise.next() * decay(Double(i) / Double(clickCount - 1))
            }
            return sample
        }
    }

    private static func readySignal() -> [Double] {
        // Two-tone chime: 8 ms linear attack, then a 650 ms exponential decay
        // that reaches -60 dB at the boundary.
        let attack = Int(0.008 * sampleRate)
        let count = attack + Int(0.650 * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let tone = sin(2 * .pi * 880 * t) + sin(2 * .pi * 1_318 * t)
            if i < attack { return tone * Double(i) / Double(attack) }
            return tone * decay(Double(i - attack) / Double(count - attack - 1))
        }
    }

    private static func takeSignal() -> [Double] {
        // A Chamberlin state-variable lowpass stays stable far below Nyquist,
        // letting the resonant 600→2400 Hz exponential sweep track per sample.
        // A 110 Hz thump decaying over 60 ms sits underneath.
        let count = Int(0.170 * sampleRate)
        let rise = Int(0.040 * sampleRate)
        let fall = count - rise
        let thumpCount = Int(0.060 * sampleRate)
        var noise = Noise(seed: 0x5441_4B45)
        var low = 0.0, band = 0.0
        return (0..<count).map { i in
            let cutoff = 600 * pow(4, Double(i) / Double(count - 1))
            let coefficient = 2 * sin(.pi * cutoff / sampleRate)
            low += coefficient * band
            band += coefficient * (noise.next() - low - band / 3) // damping 1/Q, Q = 3
            let envelope = i < rise ? Double(i) / Double(rise) : Double(count - 1 - i) / Double(fall)
            var sample = low * envelope
            if i < thumpCount {
                let t = Double(i) / sampleRate
                sample += sin(2 * .pi * 110 * t) * decay(Double(i) / Double(thumpCount - 1))
            }
            return sample
        }
    }

    private static func nudgeSignal() -> [Double] {
        // A 210 Hz pulse decaying to -60 dB at 70 ms, led by a 3 ms noise burst.
        let count = Int(0.070 * sampleRate)
        let noiseCount = Int(0.003 * sampleRate)
        var noise = Noise(seed: 0x4E55_4447)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            var sample = sin(2 * .pi * 210 * t) * decay(Double(i) / Double(count - 1))
            if i < noiseCount {
                sample += noise.next() * (1 - Double(i) / Double(noiseCount))
            }
            return sample
        }
    }

    /// Exponential decay from 1.0 to 0.001 (-60 dBFS) at progress 1.
    private static func decay(_ progress: Double) -> Double {
        exp(-log(1_000) * progress)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    /// SplitMix64: deterministic on every host, unlike SystemRandomNumberGenerator.
    private struct Noise {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) * (1.0 / 4_503_599_627_370_496.0) - 1.0
        }
    }

    /// RBJ biquad bandpass; the constant-skirt variant keeps peak gain near 0 dB.
    private struct Bandpass {
        private let b0: Double, b2: Double, a1: Double, a2: Double
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(centerFrequency: Double, quality: Double, sampleRate: Double) {
            let w0 = 2 * .pi * centerFrequency / sampleRate
            let alpha = sin(w0) / (2 * quality)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            return output
        }
    }
}
#endif
