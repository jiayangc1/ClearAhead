import CoreGraphics
import Foundation
import simd

/// Portrait camera coordinates: right +x, up +y, forward -z (AVAudioEnvironmentNode).
struct CameraGeometry {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double

    var valid: Bool {
        [fx, fy, cx, cy].allSatisfy(\.isFinite) && fx > 0 && fy > 0
    }

    func point(x: Double, y: Double, depth: Double) -> SIMD3<Double> {
        SIMD3((x - cx) * depth / fx, (cy - y) * depth / fy, -depth)
    }
}

struct GroundPlane {
    let normal: SIMD3<Double>
    let height: Double
    let support: Double

    func contains(_ point: SIMD3<Double>) -> Bool {
        abs(simd_dot(normal, point) + height) < 0.10 + simd_length(point) * 0.02
    }
}

struct GroundNormalizer {
    private(set) var scale = 1.0
    private(set) var plane: GroundPlane?
    private(set) var status = "metric-estimate"
    private var previousHeight: Double?
    private var consistentFits = 0
    private var referenceHeight = 0.0
    private var metricDepth = false

    mutating func update(map: DepthMap, geometry: CameraGeometry?, gravity: SIMD3<Double>?,
                         cameraHeight: Double, stable: Bool, metric: Bool = false) {
        if metricDepth != metric {
            self = GroundNormalizer()
            metricDepth = metric
        }
        if referenceHeight != cameraHeight {
            referenceHeight = cameraHeight
            consistentFits = 0
            previousHeight = nil
        }
        plane = nil
        status = scale == 1 ? "metric-estimate" : "calibration-held-ground-unavailable"
        guard stable, let geometry, geometry.valid, let gravity,
              simd_length(gravity) > 0.9 else { consistentFits = 0; return }
        let up = -simd_normalize(gravity)
        var points: [(point: SIMD3<Double>, x: Double, y: Double)] = []
        for row in stride(from: map.height / 2, to: map.height, by: 3) {
            for column in stride(from: 0, to: map.width, by: 3) {
                let depth = map.values[row * map.width + column]
                let x = (Double(column) + 0.5) / Double(map.width)
                let y = (Double(row) + 0.5) / Double(map.height)
                guard depth.isFinite, depth > 0.2, depth < 12 else { continue }
                let point = geometry.point(x: x, y: y, depth: depth)
                if simd_dot(up, point) < -0.25 { points.append((point, x, y)) }
            }
        }
        guard points.count >= 30 else { consistentFits = 0; return }
        var best: GroundPlane?
        var bestCount = 0
        // Deterministic RANSAC; no per-frame randomness or full-resolution plane fitting.
        for trial in 0..<64 {
            let a = points[(trial * 17) % points.count].point
            let b = points[(trial * 37 + points.count / 3) % points.count].point
            let c = points[(trial * 53 + points.count * 2 / 3) % points.count].point
            let cross = simd_cross(b - a, c - a)
            guard simd_length(cross) > 0.05 else { continue }
            var normal = simd_normalize(cross)
            if simd_dot(normal, up) < 0 { normal = -normal }
            guard simd_dot(normal, up) > cos(12 * .pi / 180) else { continue }
            let height = -simd_dot(normal, a)
            guard height > 0.35, height < 2.5 else { continue }
            let candidate = GroundPlane(normal: normal, height: height, support: 0)
            // Count inliers and their extent in one pass without allocating,
            // and stop once this trial can no longer beat the best one.
            var inlierCount = 0
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            for (offset, entry) in points.enumerated() {
                if inlierCount + points.count - offset <= bestCount { break }
                guard candidate.contains(entry.point) else { continue }
                inlierCount += 1
                minX = min(minX, entry.x)
                maxX = max(maxX, entry.x)
                minY = min(minY, entry.y)
                maxY = max(maxY, entry.y)
            }
            guard inlierCount > bestCount, maxX - minX > 0.5, maxY - minY > 0.2 else { continue }
            bestCount = inlierCount
            best = GroundPlane(normal: normal, height: height,
                               support: Double(inlierCount) / Double(points.count))
        }
        guard let fit = best, fit.support >= 0.65 else { consistentFits = 0; return }
        if let previousHeight, abs(fit.height - previousHeight) > previousHeight * 0.12 {
            consistentFits = 0
        }
        previousHeight = fit.height
        consistentFits += 1
        guard consistentFits >= 3 else { return }
        plane = fit
        status = "ground-consistent-model-estimate"
        // A slope can explain a changed plane height; never use it to rescale the scene.
        guard !metric, simd_dot(fit.normal, up) > cos(5 * .pi / 180), cameraHeight >= 0.4 else { return }
        let target = cameraHeight / fit.height
        guard target >= 0.65, target <= 1.5 else {
            status = "calibration-mismatch"
            plane = nil
            return
        }
        scale += min(max((target - scale) * 0.08, -0.01), 0.01)
        status = "height-calibrated"
    }
}

struct SceneSource {
    var event: SpatialEvent
    var position: SIMD3<Double>?
    var contours: [[CGPoint]]
    let visibility: Double
    let isSurface: Bool

    /// A hazard with no depth region of its own: one remembered after it left
    /// the view, or a ground hazard no region matched. It is placed on the
    /// ground ahead so its tone and vibration still reach the walker.
    static func onGround(_ event: SpatialEvent, cameraHeight: Double) -> SceneSource {
        let distance = max(event.approximateDistanceMeters ?? 1, 0.3)
        let drop = cameraHeight >= 0.4 ? cameraHeight : HazardMemory.assumedCameraHeight
        var outline: [[CGPoint]] = []
        if !event.isRemembered, let box = event.box {
            outline = [[CGPoint(x: box.minX, y: 1 - box.maxY), CGPoint(x: box.maxX, y: 1 - box.maxY),
                        CGPoint(x: box.maxX, y: 1 - box.minY), CGPoint(x: box.minX, y: 1 - box.minY)]]
        }
        return SceneSource(event: event, position: SIMD3(Double(event.pan) * 0.3, -drop, -distance),
                           contours: outline, visibility: 1, isSurface: false)
    }

    /// Unnamed surfaces keep their tones and outlines, but speech names one
    /// only when it is on a collision course or is a confirmed ground hazard.
    /// A wall that is merely close carries caution without a time to
    /// collision, so it stays silent.
    var isSpeakable: Bool {
        guard isSurface else { return true }
        return event.collisionRisk != .none
            && (event.timeToCollisionSeconds != nil || event.label == GroundHazardTracker.label)
    }

    var dictionary: [String: Any] {
        var payload = event.dictionary
        payload["visibility"] = visibility
        payload["isSurface"] = isSurface
        payload["contours"] = contours.map { $0.map { ["x": $0.x, "y": $0.y] } }
        if let position {
            payload["position"] = ["x": position.x, "y": position.y, "z": position.z]
        }
        return payload
    }
}

/// Depth supplies only visible pixels. Semantic boxes annotate those pixels; they never add hidden geometry.
enum SceneBuilder {
    static let columns = 32
    static let rows = 48

    static func build(map: DepthMap, objects: [SpatialEvent], hazards: [SpatialEvent],
                      geometry: CameraGeometry?, gravity: SIMD3<Double>?, ground: GroundNormalizer,
                      configuration: FeedbackConfiguration, now: TimeInterval) -> [SceneSource] {
        let count = columns * rows
        var depths = [Double](repeating: .nan, count: count)
        var labels = [Int](repeating: -1, count: count)
        let named = visibleObjects(objects.filter {
            $0.confidence >= configuration.minimumConfidence(for: $0.kind)
        }, map: map)
        for index in 0..<count {
            let x = (Double(index % columns) + 0.5) / Double(columns)
            let y = (Double(index / columns) + 0.5) / Double(rows)
            let depth = map.values[min(Int(y * Double(map.height)), map.height - 1) * map.width
                                   + min(Int(x * Double(map.width)), map.width - 1)]
            guard depth.isFinite, depth > 0.15, depth <= configuration.warningDistanceMeters else { continue }
            if let geometry, let plane = ground.plane,
               plane.contains(geometry.point(x: x, y: y, depth: depth / ground.scale)) { continue }
            depths[index] = depth
            let point = CGPoint(x: x, y: 1 - y)
            let matches = named.indices.filter {
                guard named[$0].box?.contains(point) == true,
                      let objectDepth = named[$0].approximateDistanceMeters else { return false }
                return abs(depth - objectDepth) < max(0.3, objectDepth * 0.18)
            }
            labels[index] = matches.min { named[$0].box!.width * named[$0].box!.height
                < named[$1].box!.width * named[$1].box!.height } ?? -1
        }
        var visited = [Bool](repeating: false, count: count)
        var sources: [SceneSource] = []
        for start in depths.indices where depths[start].isFinite && !visited[start] {
            var cells = [start]
            visited[start] = true
            var offset = 0
            while offset < cells.count {
                let index = cells[offset]
                offset += 1
                let row = index / columns
                let column = index % columns
                for neighbor in [row > 0 ? index - columns : -1, row + 1 < rows ? index + columns : -1,
                                 column > 0 ? index - 1 : -1, column + 1 < columns ? index + 1 : -1]
                    where neighbor >= 0 && !visited[neighbor] && depths[neighbor].isFinite {
                    guard labels[index] == labels[neighbor],
                          abs(depths[index] - depths[neighbor]) <= max(0.22, min(depths[index], depths[neighbor]) * 0.16) else { continue }
                    visited[neighbor] = true
                    cells.append(neighbor)
                }
            }
            guard cells.count >= 5 else { continue }
            var minX = columns, maxX = 0, minY = rows, maxY = 0
            for cell in cells {
                minX = min(minX, cell % columns)
                maxX = max(maxX, cell % columns + 1)
                minY = min(minY, cell / columns)
                maxY = max(maxY, cell / columns + 1)
            }
            let box = CGRect(x: Double(minX) / Double(columns), y: 1 - Double(maxY) / Double(rows),
                             width: Double(maxX - minX) / Double(columns), height: Double(maxY - minY) / Double(rows))
            let distance = DepthMap.percentile(cells.map { depths[$0] }, fraction: 0.35)
            let namedEvent = labels[start] >= 0 ? named[labels[start]] : nil
            // A wall running alongside has a bounding box that reaches the middle
            // of the view. Where its nearest part sits is where it actually is.
            var nearColumnSum = 0.0
            var nearCount = 0.0
            for cell in cells where depths[cell] <= distance {
                nearColumnSum += Double(cell % columns) + 0.5
                nearCount += 1
            }
            let nearX: Double = nearCount > 0 ? nearColumnSum / nearCount / Double(columns) : Double(box.midX)
            let hazard = (hazards + [namedEvent].compactMap { $0 }).filter {
                guard let hazardBox = $0.box else { return false }
                // The nearest part must lie inside the hazard, not merely share a bounding box with it.
                return nearX >= Double(hazardBox.minX) && nearX <= Double(hazardBox.maxX)
                    && overlap(box, hazardBox) >= 0.45
                    && abs(($0.approximateDistanceMeters ?? 100) - distance) < max(0.4, distance * 0.2)
            }.max { $0.collisionRisk < $1.collisionRisk }
            let risk = hazard?.collisionRisk ?? .none
            // Use an actually visible pixel nearest the region center, never a centroid inside an occlusion hole.
            let center = cells.min { a, b in
                let da = hypot(Double(a % columns) + 0.5 - Double(box.midX) * Double(columns),
                               Double(a / columns) + 0.5 - (1 - Double(box.midY)) * Double(rows))
                let db = hypot(Double(b % columns) + 0.5 - Double(box.midX) * Double(columns),
                               Double(b / columns) + 0.5 - (1 - Double(box.midY)) * Double(rows))
                return da < db
            }!
            var position = geometry.map { $0.point(x: (Double(center % columns) + 0.5) / Double(columns),
                                                   y: (Double(center / columns) + 0.5) / Double(rows), depth: depths[center]) }
            if let gravity, let point = position, configuration.earHeightMeters >= 0.4,
               configuration.cameraHeightMeters >= 0.4, ground.plane != nil {
                position = SceneAudioMath.earPoint(point, gravity: gravity, configuration: configuration)
            }
            let listenerDistance = position.map { simd_length($0) } ?? distance
            guard listenerDistance <= configuration.warningDistanceMeters || risk != .none else { continue }
            let event = SpatialEvent(id: namedEvent?.id ?? "surface", kind: namedEvent?.kind ?? .obstacle,
                                     label: namedEvent?.label ?? hazard?.label ?? "surface", direction: .from(horizontalMidpoint: CGFloat(nearX)),
                                     proximity: .from(distance: listenerDistance), approximateDistanceMeters: listenerDistance,
                                     approachSpeed: hazard?.approachSpeed ?? 0, motionState: hazard?.motionState ?? .stationary,
                                     collisionRisk: risk, timeToCollisionSeconds: hazard?.timeToCollisionSeconds,
                                     confidence: namedEvent?.confidence ?? 0.7,
                                     urgency: risk == .imminent ? 1 : risk == .caution ? 0.7 : 0,
                                     timestamp: now, box: box)
            sources.append(SceneSource(event: event, position: position, contours: contours(cells: Set(cells)),
                                       visibility: Double(cells.count) / Double((maxX - minX) * (maxY - minY)),
                                       isSurface: namedEvent == nil))
        }
        return sources
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return Double(intersection.width * intersection.height / max(min(a.width * a.height, b.width * b.height), 0.001))
    }

    static func visibleObjects(_ objects: [SpatialEvent], map: DepthMap) -> [SpatialEvent] {
        objects.filter { event in
            guard let box = event.box, let depth = event.approximateDistanceMeters else { return false }
            let samples = map.samples(in: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            guard samples.count >= 4 else { return false }
            let support = samples.filter { abs($0 - depth) < max(0.3, depth * 0.18) }.count
            guard Double(support) / Double(samples.count) >= 0.4 else { return false }
            return !objects.contains { front in
                guard front.id != event.id, let frontBox = front.box,
                      let frontDepth = front.approximateDistanceMeters else { return false }
                let intersection = box.intersection(frontBox)
                guard !intersection.isNull else { return false }
                let covered = intersection.width * intersection.height / max(box.width * box.height, 0.001)
                return covered >= 0.65 && frontDepth <= depth + 0.15
                    && (frontDepth < depth - 0.25 || front.confidence > event.confidence + 0.05)
            }
        }
    }

    private static func contours(cells: Set<Int>) -> [[CGPoint]] {
        let stride = columns + 1
        var edges: [Int: [Int]] = [:]
        func add(_ a: Int, _ b: Int) { edges[a, default: []].append(b) }
        for index in cells.sorted() {
            let x = index % columns
            let y = index / columns
            let a = y * stride + x
            if y == 0 || !cells.contains(index - columns) { add(a, a + 1) }
            if x == columns - 1 || !cells.contains(index + 1) { add(a + 1, a + stride + 1) }
            if y == rows - 1 || !cells.contains(index + columns) { add(a + stride + 1, a + stride) }
            if x == 0 || !cells.contains(index - 1) { add(a + stride, a) }
        }
        var paths: [[CGPoint]] = []
        while let start = edges.keys.min() {
            var vertices = [start]
            var current = start
            while let next = edges[current]?.popLast() {
                if edges[current]?.isEmpty == true { edges.removeValue(forKey: current) }
                current = next
                if current == start { break }
                vertices.append(current)
            }
            guard current == start, vertices.count >= 4 else { continue }
            paths.append(vertices.indices.compactMap { i in
                let previous = vertices[(i + vertices.count - 1) % vertices.count]
                let vertex = vertices[i]
                let next = vertices[(i + 1) % vertices.count]
                if (previous % stride == vertex % stride && vertex % stride == next % stride)
                    || (previous / stride == vertex / stride && vertex / stride == next / stride) { return nil }
                return CGPoint(x: Double(vertex % stride) / Double(columns), y: Double(vertex / stride) / Double(rows))
            })
        }
        return paths
    }
}

final class SceneSelector {
    private var selected: [SceneSource] = []
    private var nextID = 0
    static let maximumSources = 6

    func reset() { selected = []; nextID = 0 }

    func select(_ candidates: [SceneSource], now: TimeInterval, range: Double) -> [SceneSource] {
        var used = Set<String>()
        var ranked: [(source: SceneSource, score: Double)] = []
        for candidate in candidates {
            var source = candidate
            if let previous = previousMatch(for: source, excluding: used) {
                source.event = copy(source.event, id: previous.event.id)
                used.insert(previous.event.id)
            } else {
                source.event = copy(source.event, id: "scene-\(nextID)")
                nextID += 1
            }
            ranked.append((source, score(source.event, visibility: source.visibility,
                                         continued: used.contains(source.event.id), range: range)))
        }
        ranked.sort { (lhs: (source: SceneSource, score: Double), rhs: (source: SceneSource, score: Double)) -> Bool in
            if lhs.score == rhs.score { return lhs.source.event.id < rhs.source.event.id }
            return lhs.score > rhs.score
        }
        // Retain identity only while currently visible. Audio handles fade-out; no stale objects survive occlusion.
        var kept: [SceneSource] = []
        for entry in ranked.prefix(Self.maximumSources) { kept.append(entry.source) }
        selected = kept
        return selected
    }

    // Each term is its own typed statement; a combined expression here has
    // exceeded the Swift type-checker's time limit.
    private func score(_ event: SpatialEvent, visibility: Double, continued: Bool, range: Double) -> Double {
        var total: Double = 0
        switch event.collisionRisk {
        case .imminent: total += 3
        case .caution: total += 1.5
        case .none: break
        }
        let distance: Double = event.approximateDistanceMeters ?? range
        let ratio: Double = distance / range
        total += 1 - Swift.min(ratio, 1)
        total += visibility * 0.25
        total += event.confidence * 0.1
        if continued { total += 0.18 }
        return total
    }

    private func previousMatch(for source: SceneSource, excluding used: Set<String>) -> SceneSource? {
        guard let box = source.event.box else { return nil }
        var best: SceneSource?
        var bestOverlap = 0.35
        for previous in selected {
            guard !used.contains(previous.event.id), previous.isSurface == source.isSurface,
                  previous.event.kind == source.event.kind, let previousBox = previous.event.box else { continue }
            let overlap = Double(SceneBuilder.overlap(previousBox, box))
            if overlap > bestOverlap { best = previous; bestOverlap = overlap }
        }
        guard let best else { return nil }
        let previousDistance: Double = best.event.approximateDistanceMeters ?? 100
        let distance: Double = source.event.approximateDistanceMeters ?? 0
        return abs(previousDistance - distance) < 1 ? best : nil
    }

    private func copy(_ event: SpatialEvent, id: String) -> SpatialEvent {
        SpatialEvent(id: id, kind: event.kind, label: event.label, direction: event.direction,
                     proximity: event.proximity, approximateDistanceMeters: event.approximateDistanceMeters,
                     approachSpeed: event.approachSpeed, motionState: event.motionState,
                     collisionRisk: event.collisionRisk, timeToCollisionSeconds: event.timeToCollisionSeconds,
                     trajectoryConfidence: event.trajectoryConfidence, confidence: event.confidence,
                     urgency: event.urgency, timestamp: event.timestamp, box: event.box)
    }
}

enum SceneAudioMath {
    // Headphones use +x right, +y forward, +z up; audio uses +x right, +y up, -z forward.
    static let audioToHeadphoneAxes = simd_quatd(angle: .pi / 2, axis: SIMD3<Double>(1, 0, 0))

    static func earPoint(_ point: SIMD3<Double>, gravity: SIMD3<Double>, configuration: FeedbackConfiguration) -> SIMD3<Double> {
        let up = -simd_normalize(gravity)
        let right = simd_cross(SIMD3<Double>(0, 0, -1), up)
        guard simd_length(right) > 0.25 else { return point }
        let horizontalRight = simd_normalize(right)
        let forward = simd_cross(up, horizontalRight)
        return point + up * (configuration.cameraHeightMeters - configuration.earHeightMeters)
            + forward * configuration.cameraForwardOffsetMeters + horizontalRight * configuration.cameraRightOffsetMeters
    }

    static func listenerPoint(_ point: SIMD3<Double>, camera: simd_quatd, head: simd_quatd,
                              alignment: simd_quatd) -> SIMD3<Double> {
        (alignment * head).inverse.act(camera.act(point))
    }

    static func gain(distance: Double, range: Double, volume: Double, count: Int) -> Float {
        let closeness = 1 - min(max(distance / range, 0), 1)
        return Float(volume * (0.03 + 0.18 * closeness * closeness) / Double(max(count, 1)))
    }
}

struct UrgencyHaptics {
    private var lastRisk: CollisionRisk = .none
    private var lastTime = -Double.infinity

    mutating func shouldPlay(_ risk: CollisionRisk, now: TimeInterval) -> Bool {
        defer { lastRisk = risk }
        guard risk != .none else { return false }
        let interval = risk == .imminent ? 0.45 : 1.5
        guard risk > lastRisk || now - lastTime >= interval else { return false }
        lastTime = now
        return true
    }
}
