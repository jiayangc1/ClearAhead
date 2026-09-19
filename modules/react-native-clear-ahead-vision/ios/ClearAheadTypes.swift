import Foundation
import Vision

enum CADirection: String, CaseIterable {
    case left
    case center
    case right

    var pan: Float {
        switch self {
        case .left: -0.82
        case .center: 0
        case .right: 0.82
        }
    }
}

enum CAProximity: String {
    case near
    case medium
    case far
    case unknown
}

enum CAEventKind: String {
    case obstacle
    case person
    case vehicle
    case furniture
    case opening
    case deviceWarning = "device-warning"

    var risk: Double {
        switch self {
        case .vehicle: 1
        case .obstacle: 0.88
        case .person: 0.72
        case .furniture: 0.65
        case .deviceWarning: 0.62
        case .opening: 0.25
        }
    }
}

struct CASpatialEvent {
    let id: String
    let kind: CAEventKind
    let direction: CADirection
    let proximity: CAProximity
    let approximateDistanceMeters: Double?
    let approachSpeed: Double
    let confidence: Double
    var urgency: Double
    let timestamp: TimeInterval
    let box: CGRect?

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "direction": direction.rawValue,
            "proximity": proximity.rawValue,
            "approachSpeed": approachSpeed,
            "confidence": confidence,
            "urgency": urgency,
            "timestamp": timestamp * 1_000,
        ]
        if let approximateDistanceMeters {
            payload["approximateDistanceMeters"] = approximateDistanceMeters
        }
        if let box {
            payload["box"] = [
                "x": box.minX,
                "y": 1 - box.maxY,
                "width": box.width,
                "height": box.height,
            ]
        }
        return payload
    }
}

struct CAFeedbackConfiguration {
    var hapticsEnabled = true
    var audioEnabled = true
    var speechEnabled = false
    var hapticIntensity = 0.72
    var audioVolume = 0.65
    var sensitivity = 0.65
    var warningDistanceMeters = 6.0
    var feedbackFrequency = 0.55
    var mountingMode = "handheld"
    var processingMode = "responsive"
    var spokenCategories: Set<String> = ["person", "vehicle", "device-warning"]

    init() {}

    init(dictionary: [String: Any]) {
        hapticsEnabled = dictionary["hapticsEnabled"] as? Bool ?? true
        audioEnabled = dictionary["audioEnabled"] as? Bool ?? true
        speechEnabled = dictionary["speechEnabled"] as? Bool ?? false
        hapticIntensity = Self.clamp(dictionary["hapticIntensity"] as? Double ?? 0.72)
        audioVolume = Self.clamp(dictionary["audioVolume"] as? Double ?? 0.65)
        sensitivity = Self.clamp(dictionary["sensitivity"] as? Double ?? 0.65)
        warningDistanceMeters = min(max(dictionary["warningDistanceMeters"] as? Double ?? 6, 1), 12)
        feedbackFrequency = Self.clamp(dictionary["feedbackFrequency"] as? Double ?? 0.55)
        mountingMode = dictionary["mountingMode"] as? String ?? "handheld"
        let requestedMode = dictionary["processingMode"] as? String
        processingMode = requestedMode == "detailed" ? "detailed" : "responsive"
        spokenCategories = Set(dictionary["spokenCategories"] as? [String] ?? [])
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

extension CADirection {
    static func from(horizontalMidpoint midpoint: CGFloat) -> CADirection {
        if midpoint < 0.36 { return .left }
        if midpoint > 0.64 { return .right }
        return .center
    }
}

extension CAProximity {
    static func from(distance: Double?) -> CAProximity {
        guard let distance else { return .unknown }
        if distance < 2 { return .near }
        if distance < 5 { return .medium }
        return .far
    }
}
