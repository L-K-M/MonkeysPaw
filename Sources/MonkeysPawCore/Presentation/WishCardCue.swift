import Foundation

/// Short synthesized interface cues shared by both front ends (§24.7).
///
/// Each cue is a canonical 44-byte PCM RIFF stream (44.1 kHz, mono, 16-bit
/// little endian) produced by pure seeded synthesis, so `wav` returns
/// identical bytes on every host and run. Linux writes them to private files
/// for GtkMediaFile; macOS plays them through NSSound. The synthesis moved
/// here unchanged from LinuxFeedbackSounds; a Core test pins the byte
/// identity of the original four cues.
public enum WishCardCue: CaseIterable, Sendable {
    /// Input feedback for an accepted key or roll.
    case tick
    /// The card became deliverable.
    case ready
    /// The paw carries the card away.
    case take
    /// Delivery is blocked; the card shakes.
    case nudge
    /// The paw's finger curls one stop-motion notch.
    case crack

    private static let sampleRate = 44_100.0

    /// A canonical 44-byte PCM RIFF stream: 44.1 kHz, mono, 16-bit little
    /// endian. Tests inspect these bytes directly, so output is deterministic.
    public var wav: [UInt8] {
        let pcm = pcm
        var data = Data()
        data.reserveCapacity(44 + pcm.count * 2)
        data.append(contentsOf: "RIFF".utf8)
        Self.appendLittleEndian(UInt32(36 + pcm.count * 2), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        Self.appendLittleEndian(UInt32(16), to: &data)
        Self.appendLittleEndian(UInt16(1), to: &data)              // linear PCM
        Self.appendLittleEndian(UInt16(1), to: &data)              // mono
        Self.appendLittleEndian(UInt32(Self.sampleRate), to: &data)
        Self.appendLittleEndian(UInt32(Self.sampleRate) * 2, to: &data) // byte rate
        Self.appendLittleEndian(UInt16(2), to: &data)              // block align
        Self.appendLittleEndian(UInt16(16), to: &data)             // bits per sample
        data.append(contentsOf: "data".utf8)
        Self.appendLittleEndian(UInt32(pcm.count * 2), to: &data)
        for sample in pcm { Self.appendLittleEndian(sample, to: &data) }
        return Array(data)
    }

    /// Signed 16-bit samples before WAV framing; tests inspect amplitude.
    var pcm: [Int16] {
        let signal: [Double]
        let decibels: Double
        switch self {
        case .tick: signal = Self.tickSignal(); decibels = -24
        case .ready: signal = Self.readySignal(); decibels = -22
        case .take: signal = Self.takeSignal(); decibels = -18
        case .nudge: signal = Self.nudgeSignal(); decibels = -22
        case .crack: signal = Self.crackSignal(); decibels = -18
        }
        return Self.normalize(signal, peakDecibels: decibels)
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

    private static func crackSignal() -> [Double] {
        // A 1.5 ms dry transient followed by two tiny creaking clicks, 60 Hz
        // apart within a 22 ms tail. The seeded grains have no tonal bass.
        let count = Int(0.030 * sampleRate)
        let transientCount = Int(0.0015 * sampleRate)
        let grainSpacing = Int(sampleRate / 60)
        let grainLength = Int(0.0012 * sampleRate)
        let creakEnd = transientCount + Int(0.022 * sampleRate)
        var noise = Noise(seed: 0x4352_434B)
        var signal = [Double](repeating: 0, count: count)

        for i in 0..<transientCount {
            signal[i] = noise.next() * decay(Double(i) / Double(transientCount - 1))
        }

        var start = transientCount + Int(0.001 * sampleRate)
        var amplitude = 0.30
        while start + grainLength <= creakEnd {
            for i in 0..<grainLength {
                signal[start + i] += amplitude * noise.next() * decay(Double(i) / Double(grainLength - 1))
            }
            start += grainSpacing
            amplitude *= 0.6
        }

        // Removing the mean before quantization keeps the transient DC-free.
        let mean = signal.reduce(0, +) / Double(count)
        return signal.map { $0 - mean }
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

    /// RBJ biquad bandpass, constant 0 dB peak-gain form (b0 = -b2 = alpha/a0).
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
