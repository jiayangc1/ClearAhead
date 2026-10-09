import Foundation

/// Shared soft harmonic character. People and vehicles use distinct registers/partials.
/// Slot pitch separates simultaneous sources; distance changes only gain, never repetition.
enum SceneTone {
    static func frequency(kind: EventKind, slot: Int) -> Double {
        let base = kind == .person ? 392 : kind == .vehicle ? 144 : 220
        return Double(base + slot * 24)
    }

    static func samples(kind: EventKind, slot: Int, sampleRate: Int) -> [Float] {
        let frequency = frequency(kind: kind, slot: slot)
        return (0..<sampleRate).map { frame in
            let t = Double(frame) / Double(sampleRate)
            let phase = 2 * Double.pi * frequency * t
            let harmonic = kind == .person ? 0.16 * sin(phase * 3) : kind == .vehicle ? 0.12 * sin(phase * 2) : 0.08 * sin(phase * 2)
            // Integer cycles make the one-second loop seamless. Slow modulation prevents a static buzz.
            return Float((sin(phase) * 0.75 + harmonic) * (0.88 + 0.12 * sin(2 * .pi * t)))
        }
    }
}
