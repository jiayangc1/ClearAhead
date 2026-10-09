import Foundation
import simd

/// Shared soft harmonic character. People and vehicles use distinct registers/partials.
/// Slot pitch separates simultaneous sources; live cue parameters also follow hazard geometry and risk.
enum SceneTone {
    struct Cue {
        let pitchCents: Float
        let brightness: Float
        let pulseRate: Double
        let pulseDepth: Double
    }

    static func cue(event: SpatialEvent, position: SIMD3<Double>?, range: Double) -> Cue {
        let distance = event.approximateDistanceMeters ?? range
        let close = 1 - min(max(distance / max(range, 1), 0), 1)
        let risk = event.collisionRisk == .imminent ? 1.0 : event.collisionRisk == .caution ? 0.55 : 0
        let closing = event.motionState == .approaching ? min(max(event.approachSpeed / 1.5, 0), 1) : 0
        let hazard = max(risk, closing)
        let elevation: Double
        if let position {
            elevation = atan2(position.y, max(hypot(position.x, position.z), 0.1)) / (.pi / 2)
        } else {
            elevation = event.box.map { Double($0.midY) * 2 - 1 } ?? 0
        }
        return Cue(pitchCents: Float(elevation * 400 + close * 150 + hazard * 300),
                   brightness: Float(close * 3 + hazard * 6),
                   pulseRate: 0.8 + close + hazard * 3.2,
                   pulseDepth: 0.15 + hazard * 0.65)
    }

    static func pulse(phase: Double, depth: Double) -> Float {
        Float(1 - depth * (0.5 - 0.5 * cos(phase)))
    }

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
