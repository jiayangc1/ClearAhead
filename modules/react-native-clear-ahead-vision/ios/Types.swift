import Foundation
import Vision
import simd

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
        if isRemembered {
            payload["outOfView"] = true
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

    /// A hazard that left the view and is carried forward by `HazardMemory`.
    var isRemembered: Bool { id.hasPrefix(HazardMemory.identifierPrefix) }

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
    var speechEnabled = true
    var hapticIntensity = 1.0
    var audioVolume = 1.0
    var continuousAudio = true
    var sensitivity = 0.65
    var warningDistanceMeters = 6.0
    var mountingMode = "handheld"
    var cameraHeightMeters = 0.0
    var earHeightMeters = 0.0
    var cameraForwardOffsetMeters = 0.0
    var cameraRightOffsetMeters = 0.0
    var processingMode = "responsive"
    var modelVariant = "n"
    var depthMapEnabled = false
    var lidarEnabled = true
    var showBoundingBoxes = true
    var boundingBoxVerbosity = "standard"
    var spokenCategories: Set<String> = ["person", "vehicle", "obstacle", "furniture"]
    var speechDetail = "hazards"

    init() {}

    /// Low things on the ground are detected less confidently than people or
    /// furniture, and missing one costs more than a spare cue.
    func minimumConfidence(for kind: EventKind) -> Double {
        0.42 + (1 - sensitivity) * 0.24 - (kind == .obstacle ? 0.08 : 0)
    }

    init(dictionary: [String: Any]) {
        hapticsEnabled = dictionary["hapticsEnabled"] as? Bool ?? true
        audioEnabled = dictionary["audioEnabled"] as? Bool ?? true
        speechEnabled = dictionary["speechEnabled"] as? Bool ?? true
        hapticIntensity = Self.clamp(dictionary["hapticIntensity"] as? Double, fallback: 1)
        audioVolume = Self.clamp(dictionary["audioVolume"] as? Double, fallback: 1)
        continuousAudio = dictionary["continuousAudio"] as? Bool ?? true
        sensitivity = Self.clamp(dictionary["sensitivity"] as? Double, fallback: 0.65)
        let requestedWarningDistance = dictionary["warningDistanceMeters"] as? Double
        warningDistanceMeters = requestedWarningDistance?.isFinite == true
            ? min(max(requestedWarningDistance ?? 6, 1), 12)
            : 6
        mountingMode = dictionary["mountingMode"] as? String == "chest" ? "chest" : "handheld"
        cameraHeightMeters = Self.height(dictionary["cameraHeightMeters"] as? Double)
        earHeightMeters = Self.height(dictionary["earHeightMeters"] as? Double)
        if let offset = dictionary["cameraForwardOffsetMeters"] as? Double, offset.isFinite {
            cameraForwardOffsetMeters = min(max(offset, 0), 0.8)
        }
        if let offset = dictionary["cameraRightOffsetMeters"] as? Double, offset.isFinite {
            cameraRightOffsetMeters = min(max(offset, -0.5), 0.5)
        }
        let requestedMode = dictionary["processingMode"] as? String
        processingMode = requestedMode == "detailed" ? "detailed" : "responsive"
        let requestedVariant = dictionary["modelVariant"] as? String ?? "n"
        modelVariant = ["n", "s", "m", "l", "x"].contains(requestedVariant) ? requestedVariant : "n"
        depthMapEnabled = dictionary["depthMapEnabled"] as? Bool ?? false
        lidarEnabled = dictionary["lidarEnabled"] as? Bool ?? true
        showBoundingBoxes = dictionary["showBoundingBoxes"] as? Bool ?? true
        let requestedVerbosity = dictionary["boundingBoxVerbosity"] as? String ?? "standard"
        boundingBoxVerbosity = ["verbose", "standard", "less"].contains(requestedVerbosity)
            ? requestedVerbosity : "standard"
        if let requestedCategories = dictionary["spokenCategories"] as? [String] {
            let supportedCategories = Set(EventKind.allCases.map(\.rawValue))
            spokenCategories = Set(requestedCategories.filter(supportedCategories.contains))
        }
        speechDetail = dictionary["speechDetail"] as? String == "everything" ? "everything" : "hazards"
    }

    private static func height(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0.4 else { return 0 }
        return min(value, 2.5)
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

/// How the phone is mounted: upright, or turned on its side either way. Every
/// reading downstream works in the upright picture, sky at the top; this turns
/// the camera's buffer and the phone's own axes into that picture. The screen
/// stays upright on the phone, so what is drawn is turned back to it.
enum CameraMount: String {
    /// Top edge up.
    case upright
    /// Top edge to the walker's left, as seen from behind the phone.
    case sidewaysLeft
    /// Top edge to the walker's right.
    case sidewaysRight

    /// How Vision turns the rear camera's landscape buffer upright.
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .upright: .right
        case .sidewaysLeft: .up
        case .sidewaysRight: .down
        }
    }

    /// Turns the phone's axes into the picture's: right +x, up +y, toward the walker +z.
    var phoneToPicture: simd_quatd {
        switch self {
        case .upright: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        case .sidewaysLeft: simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        case .sidewaysRight: simd_quatd(angle: -.pi / 2, axis: SIMD3(0, 0, 1))
        }
    }

    /// Where a point of the upright picture lies in the camera buffer. Both are
    /// normalized with the origin at the top left.
    func bufferPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .upright: (y, 1 - x)
        case .sidewaysLeft: (x, y)
        case .sidewaysRight: (1 - x, 1 - y)
        }
    }

    /// Where a point of the upright picture shows on the screen.
    func screenPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .upright: (x, y)
        case .sidewaysLeft: (1 - y, x)
        case .sidewaysRight: (y, 1 - x)
        }
    }

    /// A top-left-origin box of the picture as it shows on the screen.
    func screenBox(_ box: CGRect) -> CGRect {
        let first = screenPoint(x: Double(box.minX), y: Double(box.minY))
        let second = screenPoint(x: Double(box.maxX), y: Double(box.maxY))
        return CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                      width: abs(second.x - first.x), height: abs(second.y - first.y))
    }
}

/// Settles which way the phone is mounted from gravity in the phone's axes.
/// The first reading is taken at once; after that a new mount must hold well
/// past the halfway tilt for a moment, so a swinging arm does not flip it.
struct MountDetector {
    static let settleSeconds = 0.6
    private(set) var mount: CameraMount?
    private var candidate: CameraMount?
    private var candidateSince: TimeInterval = 0

    @discardableResult
    mutating func update(gravity: SIMD3<Double>, now: TimeInterval) -> CameraMount? {
        // Lying flat or pointing at the ground, the tilt says nothing about which edge is up.
        guard (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot() > 0.5 else {
            candidate = nil
            return mount
        }
        // 0 upright, -90 with the top edge to the left, 90 with it to the right.
        let roll = atan2(gravity.x, -gravity.y) * 180 / .pi
        let window = mount == nil ? 45.0 : 30.0
        let reading: CameraMount?
        if abs(roll) < window {
            reading = .upright
        } else if abs(roll + 90) < window {
            reading = .sidewaysLeft
        } else if abs(roll - 90) < window {
            reading = .sidewaysRight
        } else {
            reading = nil
        }
        guard let reading, reading != mount else {
            candidate = nil
            return mount
        }
        if mount == nil {
            mount = reading
        } else if candidate != reading {
            candidate = reading
            candidateSince = now
        } else if now - candidateSince >= Self.settleSeconds {
            mount = reading
            candidate = nil
        }
        return mount
    }
}
