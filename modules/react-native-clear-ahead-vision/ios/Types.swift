import Foundation
import Vision

enum Direction: String, CaseIterable {
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

enum Proximity: String {
    case near
    case medium
    case far
    case unknown
}

enum MotionState: String {
    case stationary
    case approaching
    case receding
    case crossing
}

enum CollisionRisk: String, Comparable {
    case none
    case caution
    case imminent

    private var rank: Int {
        switch self {
        case .none: 0
        case .caution: 1
        case .imminent: 2
        }
    }

    static func < (lhs: CollisionRisk, rhs: CollisionRisk) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum EventKind: String, CaseIterable {
    case obstacle
    case person
    case vehicle
    case furniture

    var risk: Double {
        switch self {
        case .vehicle: 1
        case .obstacle: 0.88
        case .person: 0.72
        case .furniture: 0.65
        }
    }
}

struct SpatialEvent {
    let id: String
    let kind: EventKind
    let label: String?
    let direction: Direction
    let proximity: Proximity
    let approximateDistanceMeters: Double?
    let approachSpeed: Double
    let motionState: MotionState
    let collisionRisk: CollisionRisk
    let timeToCollisionSeconds: Double?
    let trajectoryConfidence: Double
    let confidence: Double
    var urgency: Double
    let timestamp: TimeInterval
    let box: CGRect?

    init(
        id: String,
        kind: EventKind,
        label: String? = nil,
        direction: Direction,
        proximity: Proximity,
        approximateDistanceMeters: Double?,
        approachSpeed: Double,
        motionState: MotionState = .stationary,
        collisionRisk: CollisionRisk = .none,
        timeToCollisionSeconds: Double? = nil,
        trajectoryConfidence: Double = 0,
        confidence: Double,
        urgency: Double,
        timestamp: TimeInterval,
        box: CGRect?
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.direction = direction
        self.proximity = proximity
        self.approximateDistanceMeters = approximateDistanceMeters
        self.approachSpeed = approachSpeed
        self.motionState = motionState
        self.collisionRisk = collisionRisk
        self.timeToCollisionSeconds = timeToCollisionSeconds
        self.trajectoryConfidence = trajectoryConfidence
        self.confidence = confidence
        self.urgency = urgency
        self.timestamp = timestamp
        self.box = box
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "direction": direction.rawValue,
            "proximity": proximity.rawValue,
            "approachSpeed": approachSpeed,
            "motionState": motionState.rawValue,
            "collisionRisk": collisionRisk.rawValue,
            "trajectoryConfidence": trajectoryConfidence,
            "confidence": confidence,
            "urgency": urgency,
            "timestamp": timestamp * 1_000,
        ]
        if let approximateDistanceMeters {
            payload["approximateDistanceMeters"] = approximateDistanceMeters
        }
        if let label {
            payload["label"] = label
        }
        if let timeToCollisionSeconds {
            payload["timeToCollisionSeconds"] = timeToCollisionSeconds
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

    /// Stereo position of the hazard. A known box pans continuously with where
    /// the hazard sits in view; otherwise the coarse direction decides.
    var pan: Float {
        guard let box else { return direction.pan }
        return Float(min(max((Double(box.midX) - 0.5) / 0.3, -1), 1))
    }
}

struct FeedbackConfiguration {
    var hapticsEnabled = true
    var audioEnabled = true
    var speechEnabled = false
    var hapticIntensity = 0.72
    var audioVolume = 0.65
    var sensitivity = 0.65
    var warningDistanceMeters = 6.0
    var mountingMode = "handheld"
    var processingMode = "responsive"
    var modelVariant = "n"
    var depthMapEnabled = false
    var showBoundingBoxes = true
    var boundingBoxVerbosity = "standard"
    var spokenCategories: Set<String> = ["person", "vehicle", "obstacle", "furniture"]

    init() {}

    init(dictionary: [String: Any]) {
        hapticsEnabled = dictionary["hapticsEnabled"] as? Bool ?? true
        audioEnabled = dictionary["audioEnabled"] as? Bool ?? true
        speechEnabled = dictionary["speechEnabled"] as? Bool ?? false
        hapticIntensity = Self.clamp(dictionary["hapticIntensity"] as? Double, fallback: 0.72)
        audioVolume = Self.clamp(dictionary["audioVolume"] as? Double, fallback: 0.65)
        sensitivity = Self.clamp(dictionary["sensitivity"] as? Double, fallback: 0.65)
        let requestedWarningDistance = dictionary["warningDistanceMeters"] as? Double
        warningDistanceMeters = requestedWarningDistance?.isFinite == true
            ? min(max(requestedWarningDistance ?? 6, 1), 12)
            : 6
        mountingMode = dictionary["mountingMode"] as? String == "chest" ? "chest" : "handheld"
        let requestedMode = dictionary["processingMode"] as? String
        processingMode = requestedMode == "detailed" ? "detailed" : "responsive"
        let requestedVariant = dictionary["modelVariant"] as? String ?? "n"
        modelVariant = ["n", "s", "m", "l", "x"].contains(requestedVariant) ? requestedVariant : "n"
        depthMapEnabled = dictionary["depthMapEnabled"] as? Bool ?? false
        showBoundingBoxes = dictionary["showBoundingBoxes"] as? Bool ?? true
        let requestedVerbosity = dictionary["boundingBoxVerbosity"] as? String ?? "standard"
        boundingBoxVerbosity = ["verbose", "standard", "less"].contains(requestedVerbosity)
            ? requestedVerbosity : "standard"
        if let requestedCategories = dictionary["spokenCategories"] as? [String] {
            let supportedCategories = Set(EventKind.allCases.map(\.rawValue))
            spokenCategories = Set(requestedCategories.filter(supportedCategories.contains))
        }
    }

    private static func clamp(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

extension Direction {
    static func from(horizontalMidpoint midpoint: CGFloat) -> Direction {
        if midpoint < 0.36 { return .left }
        if midpoint > 0.64 { return .right }
        return .center
    }
}

extension Proximity {
    static func from(distance: Double?) -> Proximity {
        guard let distance else { return .unknown }
        if distance < 2 { return .near }
        if distance < 5 { return .medium }
        return .far
    }
}
