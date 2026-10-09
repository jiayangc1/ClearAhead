# Path End and Curve Cues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While assisting, say "Path ends ahead", "Path curves left" or "Path curves right" when the surface the walker is on stops or bends.

**Architecture:** A new pure Swift file reads the camera's YUV frame on a coarse grid, follows the cells that look like the ground at the walker's feet, and reports whether that region stops or bends. A small tracker confirms a reading over half a second and limits repeats. The engine runs both on frames that produced a depth map and speaks through the existing speech queue.

**Tech Stack:** Swift, CoreVideo, the existing `DepthMap` and `Feedback` types. No new model, no React Native changes.

**Spec:** `docs/superpowers/specs/2026-10-09-sidewalk-end-and-curve-design.md`

## Global Constraints

- Spoken text is exactly `Path ends ahead`, `Path curves left`, `Path curves right`.
- Voice only. No tone, haptic, overlay, setting, `SpatialEvent`, or Nitro spec change.
- Follows `speechEnabled`; silent while VoiceOver is running (same as other speech).
- Hazard speech wins: no path cue within 2.5 s of a spoken hazard.
- Same cue no sooner than 8 s later, and only after it has been absent for 1.5 s.
- **Do not write tests and do not run tests.** This is the repo owner's standing rule and it overrides the TDD steps this plan format normally carries. Each task is verified by building the app target only. Do not run `scripts/check-ios.py`; it runs the native test scheme.
- Keep Swift expressions short. This codebase has twice had to split expressions the Swift type-checker timed out on.
- Commit messages are semantic (`feat:`, `fix:`, `chore:`, `docs:`).

## Build command

Used by every task. Run from the repo root.

```bash
UDID=$(xcrun simctl list devices available --json | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(x['udid'] for r,g in d.items() if 'iOS' in r for x in g if 'iPhone' in x['name']))")
xcodebuild build -workspace ios/ClearAhead.xcworkspace -scheme ClearAhead \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/ios-checks CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: unused|BUILD (SUCCEEDED|FAILED)"
```

Expected: a single line `** BUILD SUCCEEDED **`.

## Review Focus

No task has tests, so these are checked by reading the code in the task named, and by walking with the app afterwards.

1. **Camera frame is not 8-bit bi-planar YUV** (another pixel format): expect silence, not a crash or garbage. Task 1, the format guard in `grid(from:)`.
2. **A wall, fence or parked car where the pavement stops:** expect no "Path ends ahead"; the obstacle code owns that. Task 1, the `past >= stop * 1.03` check.
3. **Walker standing still at the end of a path:** expect the cue once, not every 8 seconds. Task 2, the `cleared` flag.
4. **A hazard is being announced when a cue is confirmed:** expect the cue to come after the hazard, not be lost. Task 3, `spoke` is only called when the cue is actually sent.
5. **Phone swinging or low light:** expect any half-built confirmation to reset. Task 3, `update(nil, ...)` is still called on those frames.

---

### Task 1: Read the path's shape from a frame

**Files:**
- Create: `modules/react-native-clear-ahead-vision/ios/WalkablePath.swift`
- Modify: `modules/react-native-clear-ahead-vision/ClearAheadVision.podspec` (the `s.source_files` list)

**Interfaces:**
- Consumes: `DepthMap.samples(in:step:)` (top-left origin, normalized box), `DepthMap.percentile(_:fraction:)`, `Direction` (`.left`, `.center`, `.right`).
- Produces: `struct PathShape { var endDistanceMeters: Double?; var bend: Direction? }` and `WalkablePath.shape(pixelBuffer: CVPixelBuffer, depthMap: DepthMap, maximumDistance: Double) -> PathShape?`. `nil` means nothing to report.

- [ ] **Step 1: Create the file**

Write `modules/react-native-clear-ahead-vision/ios/WalkablePath.swift`:

```swift
import CoreGraphics
import CoreVideo
import Foundation

/// What the walking surface ahead is doing, read from one camera frame.
struct PathShape: Equatable {
    /// Depth at which the surface under the walker stops, if it does.
    var endDistanceMeters: Double?
    /// The side the path bends toward, if it bends.
    var bend: Direction?
}

/// Follows the surface at the walker's feet up the image. No model here knows
/// what a sidewalk is, so the path is whatever keeps looking like the ground
/// underfoot.
enum WalkablePath {
    static let columns = 48
    static let rows = 64
    /// Only the lower 60% of the image can hold nearby ground.
    static let firstRow = 26
    /// An upright phone sees no ground nearer than about 2.5 m, and the patch
    /// at the feet has to stay on the path, so the range reaches past that.
    static let endRange = 0.8...4.0

    struct Cell {
        var luma = 0.0
        var cb = 0.0
        var cr = 0.0
        var texture = 0.0
    }

    /// One row of path. `left` and `right` are both inside it.
    struct Run {
        let row: Int
        let left: Int
        let right: Int

        var width: Int { right - left + 1 }
        var center: Double { Double(left + right + 1) / 2 }
    }

    static func shape(pixelBuffer: CVPixelBuffer, depthMap: DepthMap, maximumDistance: Double) -> PathShape? {
        guard let cells = grid(from: pixelBuffer), let path = follow(cells) else { return nil }
        return read(runs: path.runs, similar: path.similar, depthMap: depthMap, maximumDistance: maximumDistance)
    }

    /// Averages the frame into upright cells. Row `rows - 1` is at the feet.
    static func grid(from pixelBuffer: CVPixelBuffer) -> [Cell]? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard width >= rows * 4, height >= columns * 4, chromaWidth > 1, chromaHeight > 1 else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let cellWidth = Double(width) / Double(rows)
        let cellHeight = Double(height) / Double(columns)
        var cells = [Cell](repeating: Cell(), count: columns * rows)
        for row in firstRow..<rows {
            for column in 0..<columns {
                // The buffer is landscape and shown turned clockwise: going
                // down the upright image runs along the buffer's x, and going
                // right runs up the buffer's y.
                let originX = Double(row) * cellWidth
                let originY = Double(columns - 1 - column) * cellHeight
                var sum = 0.0
                var squares = 0.0
                var cb = 0.0
                var cr = 0.0
                for step in 0..<16 {
                    let x = min(width - 1, Int(originX + (Double(step % 4) + 0.5) / 4 * cellWidth))
                    let y = min(height - 1, Int(originY + (Double(step / 4) + 0.5) / 4 * cellHeight))
                    let value = Double(luma[y * lumaStride + x])
                    sum += value
                    squares += value * value
                    // Colour changes slowly; the four samples on the diagonal are enough.
                    guard step % 5 == 0 else { continue }
                    let chromaX = min(chromaWidth - 1, x * chromaWidth / width)
                    let chromaY = min(chromaHeight - 1, y * chromaHeight / height)
                    cb += Double(chroma[chromaY * chromaStride + chromaX * 2])
                    cr += Double(chroma[chromaY * chromaStride + chromaX * 2 + 1])
                }
                let mean = sum / 16
                let deviation = max(0, squares / 16 - mean * mean).squareRoot()
                cells[row * columns + column] = Cell(luma: mean, cb: cb / 4, cr: cr / 4, texture: deviation)
            }
        }
        return cells
    }

    /// The rows of path joined to the walker's feet, nearest first, with every
    /// cell that looks like that ground whether or not it is joined.
    static func follow(_ cells: [Cell]) -> (runs: [Run], similar: [Bool])? {
        let seedColumns = 16..<32
        let seedRows = (rows - 8)..<rows
        var seed: [Cell] = []
        for row in seedRows {
            for column in seedColumns { seed.append(cells[row * columns + column]) }
        }
        func middle(_ measure: (Cell) -> Double) -> (median: Double, spread: Double) {
            let values = seed.map(measure)
            let low = DepthMap.percentile(values, fraction: 0.16)
            let high = DepthMap.percentile(values, fraction: 0.84)
            return (DepthMap.percentile(values, fraction: 0.5), (high - low) / 2)
        }
        let luma = middle { $0.luma }
        let cb = middle { $0.cb }
        let cr = middle { $0.cr }
        let texture = middle { $0.texture }
        // Standing on two surfaces at once leaves no single look to follow.
        guard luma.spread <= 28, cb.spread <= 9, cr.spread <= 9 else { return nil }
        // Shade darkens pavement without changing its colour, so brightness is
        // allowed to wander much further than colour is.
        let lumaTolerance = max(40, luma.spread * 3.5)
        let cbTolerance = max(7, cb.spread * 3.5)
        let crTolerance = max(7, cr.spread * 3.5)
        let textureLimit = max(12, texture.median * 2.5 + texture.spread * 3)

        var raw = [Bool](repeating: false, count: columns * rows)
        for index in (firstRow * columns)..<(rows * columns) {
            let cell = cells[index]
            let sameColour = abs(cell.cb - cb.median) <= cbTolerance && abs(cell.cr - cr.median) <= crTolerance
            raw[index] = sameColour && abs(cell.luma - luma.median) <= lumaTolerance && cell.texture <= textureLimit
        }
        // A crack, a joint or a leaf is one cell of something else with path on
        // both sides of it.
        var similar = raw
        for row in firstRow..<rows {
            for column in 0..<columns where !raw[row * columns + column] {
                let index = row * columns + column
                let sides = column > 0 && column < columns - 1 && raw[index - 1] && raw[index + 1]
                let ends = row > firstRow && row < rows - 1 && raw[index - columns] && raw[index + columns]
                if sides || ends { similar[index] = true }
            }
        }

        var joined = [Bool](repeating: false, count: columns * rows)
        var pending: [Int] = []
        func visit(_ index: Int) {
            guard similar[index], !joined[index] else { return }
            joined[index] = true
            pending.append(index)
        }
        for row in seedRows {
            for column in seedColumns { visit(row * columns + column) }
        }
        guard pending.count * 10 >= seed.count * 6 else { return nil }
        while let index = pending.popLast() {
            let column = index % columns
            if column > 0 { visit(index - 1) }
            if column < columns - 1 { visit(index + 1) }
            if index - columns >= firstRow * columns { visit(index - columns) }
            if index + columns < rows * columns { visit(index + columns) }
        }

        var runs: [Run] = []
        var reach = seedColumns.lowerBound...(seedColumns.upperBound - 1)
        for row in stride(from: rows - 1, through: firstRow, by: -1) {
            var best: Run?
            var bestOverlap = 0
            var column = 0
            while column < columns {
                guard joined[row * columns + column] else { column += 1; continue }
                var end = column
                while end + 1 < columns, joined[row * columns + end + 1] { end += 1 }
                let overlap = min(end, reach.upperBound) - max(column, reach.lowerBound) + 1
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = Run(row: row, left: column, right: end)
                }
                column = end + 1
            }
            // Three cells is narrower than anything a person walks along.
            guard let best, best.width >= 3 else { break }
            runs.append(best)
            reach = best.left...best.right
        }
        return runs.count >= seedRows.count ? (runs, similar) : nil
    }

    static func read(runs: [Run], similar: [Bool], depthMap: DepthMap, maximumDistance: Double) -> PathShape? {
        func depth(_ band: ClosedRange<Int>, across run: Run) -> Double? {
            let box = CGRect(
                x: Double(run.left) / Double(columns),
                y: Double(band.lowerBound) / Double(rows),
                width: Double(run.width) / Double(columns),
                height: Double(band.count) / Double(rows)
            )
            let values = depthMap.samples(in: box, step: 1)
            return values.count >= 4 ? DepthMap.percentile(values, fraction: 0.5) : nil
        }

        var shape = PathShape()
        if let last = runs.last, runs.count >= 8, last.row >= firstRow + 4 {
            let nearer = runs[runs.count - 5]
            var alike = 0
            for row in (last.row - 4)..<last.row {
                for column in last.left...last.right where similar[row * columns + column] { alike += 1 }
            }
            // Under a quarter of the four rows past the stop still look like
            // path. A path that only thins to a point is running out of view
            // instead.
            let stopsAcross = alike < last.width && last.width * 2 >= nearer.width
            // Ground keeps getting farther up the image. A wall or a parked
            // car stays at one depth, and the obstacle checks speak for those.
            if stopsAcross,
               let stop = depth(last.row...last.row, across: last),
               let past = depth((last.row - 4)...(last.row - 2), across: last),
               endRange.contains(stop), stop <= maximumDistance, past >= stop * 1.03 {
                shape.endDistanceMeters = stop
            }
        }

        // A row cut off by the side of the image has no true centre.
        func whole(_ run: Run) -> Bool { run.left > 0 && run.right < columns - 1 }
        let framed = Array(runs.drop { !whole($0) }.prefix(while: whole))
        if framed.count >= 14, let top = framed.last, let reach = depth(top.row...top.row, across: top), reach >= 2 {
            let near = framed.prefix(max(4, framed.count / 3))
            var sumY = 0.0
            var sumC = 0.0
            var sumYY = 0.0
            var sumYC = 0.0
            for run in near {
                let y = Double(run.row)
                sumY += y
                sumC += run.center
                sumYY += y * y
                sumYC += y * run.center
            }
            let count = Double(near.count)
            let slope = (count * sumYC - sumY * sumC) / (count * sumYY - sumY * sumY)
            let intercept = (sumC - slope * sumY) / count
            // How far a row's centre sits from where the near path was heading.
            func drift(_ run: Run) -> Double { run.center - (intercept + slope * Double(run.row)) }
            let far = framed.suffix(framed.count / 2)
            let endDrift = drift(top)
            let agreeing = far.filter { drift($0) * endDrift > 0 }.count
            let limit = max(3, Double(top.width) * 0.75)
            if abs(endDrift) > limit, agreeing * 5 >= far.count * 4, let first = far.first,
               abs(endDrift) >= abs(drift(first)) {
                shape.bend = endDrift > 0 ? .right : .left
            }
        }
        return shape.endDistanceMeters == nil && shape.bend == nil ? nil : shape
    }
}
```

- [ ] **Step 2: List the file in the podspec**

In `modules/react-native-clear-ahead-vision/ClearAheadVision.podspec`, inside `s.source_files`, add one line after `"ios/Types.swift",`:

```ruby
    "ios/Types.swift",
    "ios/WalkablePath.swift",
```

- [ ] **Step 3: Regenerate the Pods project**

Run: `bundle exec pod install --project-directory=ios`
Expected: ends with `Pod installation complete!`. `ios/Podfile.lock` changes (the `ClearAheadVision` checksum).

- [ ] **Step 4: Build**

Run the Build command above.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add modules/react-native-clear-ahead-vision/ios/WalkablePath.swift \
  modules/react-native-clear-ahead-vision/ClearAheadVision.podspec ios/Podfile.lock
git commit -m "feat: read where the path underfoot ends or bends from the camera image"
```

---

### Task 2: Confirm a reading before it is spoken

**Files:**
- Modify: `modules/react-native-clear-ahead-vision/ios/WalkablePath.swift` (append)

**Interfaces:**
- Consumes: `PathShape` from Task 1.
- Produces: `enum PathCue: Hashable { case ends, curvesLeft, curvesRight; var text: String }` and `struct PathCueTracker` with `mutating func update(_ shape: PathShape?, now: TimeInterval) -> PathCue?`, `mutating func spoke(_ cue: PathCue, now: TimeInterval)`, `mutating func reset()`.

- [ ] **Step 1: Append the cue and tracker**

Add to the end of `modules/react-native-clear-ahead-vision/ios/WalkablePath.swift`:

```swift

enum PathCue: Hashable {
    case ends
    case curvesLeft
    case curvesRight

    var text: String {
        switch self {
        case .ends: "Path ends ahead"
        case .curvesLeft: "Path curves left"
        case .curvesRight: "Path curves right"
        }
    }
}

/// Holds a path reading back until it has lasted, and keeps it from repeating.
/// A shadow reads as the end of the path for a frame or two; a real end stays.
struct PathCueTracker {
    private struct Spoken {
        var at: TimeInterval
        var lastPresent: TimeInterval
        var cleared = false
    }

    private var current: PathCue?
    private var since: TimeInterval = 0
    private var missed = false
    private var distance: Double?
    private var spoken: [PathCue: Spoken] = [:]

    mutating func reset() { self = PathCueTracker() }

    /// The cue that is ready to be said. It keeps coming back until `spoke`
    /// is called, so one held behind a hazard warning is not lost.
    mutating func update(_ shape: PathShape?, now: TimeInterval) -> PathCue? {
        var reading: PathCue?
        if shape?.endDistanceMeters != nil {
            reading = .ends
        } else if shape?.bend == .left {
            reading = .curvesLeft
        } else if shape?.bend == .right {
            reading = .curvesRight
        }
        // Someone standing at the end of a path has already been told.
        if let reading, var record = spoken[reading] {
            if now - record.lastPresent >= 1.5 { record.cleared = true }
            record.lastPresent = now
            spoken[reading] = record
        }

        var steady = reading != nil && reading == current
        if steady, let previous = distance, let measured = shape?.endDistanceMeters, abs(measured - previous) > 0.8 {
            steady = false
        }
        if steady {
            missed = false
            distance = shape?.endDistanceMeters
        } else if current != nil, !missed {
            // One frame may disagree. Two start over.
            missed = true
            return nil
        } else {
            current = reading
            since = now
            missed = false
            distance = shape?.endDistanceMeters
            return nil
        }

        guard let current, now - since >= 0.5 else { return nil }
        if let record = spoken[current], !record.cleared || now - record.at < 8 { return nil }
        return current
    }

    mutating func spoke(_ cue: PathCue, now: TimeInterval) {
        spoken[cue] = Spoken(at: now, lastPresent: now)
    }
}
```

- [ ] **Step 2: Build**

Run the Build command above.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add modules/react-native-clear-ahead-vision/ios/WalkablePath.swift
git commit -m "feat: confirm path cues over half a second and keep them from repeating"
```

---

### Task 3: Speak the cues while assisting

**Files:**
- Modify: `modules/react-native-clear-ahead-vision/ios/Feedback/Feedback.swift` (after `speakWarning`, about line 159)
- Modify: `modules/react-native-clear-ahead-vision/ios/ClearAheadEngine.swift` (property list about line 58, `resetSessionState` about line 267, `process` about lines 494-546)

**Interfaces:**
- Consumes: `WalkablePath.shape(pixelBuffer:depthMap:maximumDistance:)`, `PathCueTracker`, `PathCue.text`.
- Produces: nothing other code depends on.

- [ ] **Step 1: Add the speech entry point**

In `Feedback.swift`, directly after the closing brace of `speakWarning`, add:

```swift

    func speakPathCue(_ message: String, configuration: FeedbackConfiguration) {
        guard configuration.speechEnabled, !UIAccessibility.isVoiceOverRunning else { return }
        // Below every hazard, so a warning already waiting is never displaced.
        requestSpeech(text: message, key: "path:\(message)", priority: 0.2, mayInterrupt: false, cooldown: 8)
    }
```

- [ ] **Step 2: Hold the tracker in the engine**

In `ClearAheadEngine.swift`, after the line `private var groundHazardTracker = GroundHazardTracker()`, add:

```swift
    private var pathCueTracker = PathCueTracker()
    private var lastHazardSpeech: TimeInterval = 0
```

In `resetSessionState()`, after the line `groundHazardTracker.reset()`, add:

```swift
        pathCueTracker.reset()
        lastHazardSpeech = 0
```

- [ ] **Step 3: Read image quality for the path check**

In `process`, find this block:

```swift
        let imageUsable = depthUsesLidar
            ? qualityState.imageQuality != "camera-covered"
            : qualityState.imageQuality == "good" && !cameraTooClose
        stateLock.unlock()
```

Replace it with:

```swift
        let imageUsable = depthUsesLidar
            ? qualityState.imageQuality != "camera-covered"
            : qualityState.imageQuality == "good" && !cameraTooClose
        // The path is read from how the picture looks, LiDAR or not.
        let imageClear = qualityState.imageQuality == "good" && !cameraTooClose
        stateLock.unlock()
```

- [ ] **Step 4: Run the path check after hazard speech**

In `process`, find:

```swift
        if let utterance = speechGate.next(from: speakable, configuration: currentConfiguration, now: evaluationTime) {
            feedback.speak(utterance, configuration: currentConfiguration)
        }
```

Replace it with:

```swift
        if let utterance = speechGate.next(from: speakable, configuration: currentConfiguration, now: evaluationTime) {
            feedback.speak(utterance, configuration: currentConfiguration)
            lastHazardSpeech = evaluationTime
        }
        // Where the path goes matters less than what is in the way, so it
        // waits for a gap. Frames that cannot be trusted still reach the
        // tracker, as nothing, so a half-confirmed reading does not survive them.
        if shouldEstimateDepth {
            var shape: PathShape?
            if imageClear, currentRotationRate() < 0.9, let map = latestDepthMap {
                shape = WalkablePath.shape(pixelBuffer: pixelBuffer, depthMap: map,
                                           maximumDistance: currentConfiguration.warningDistanceMeters)
            }
            if let cue = pathCueTracker.update(shape, now: evaluationTime), evaluationTime - lastHazardSpeech >= 2.5 {
                feedback.speakPathCue(cue.text, configuration: currentConfiguration)
                pathCueTracker.spoke(cue, now: evaluationTime)
            }
        }
```

- [ ] **Step 5: Build**

Run the Build command above.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add modules/react-native-clear-ahead-vision/ios/Feedback/Feedback.swift \
  modules/react-native-clear-ahead-vision/ios/ClearAheadEngine.swift
git commit -m "feat: say when the path ahead ends or curves"
```

---

## After the build passes

This cannot be confirmed from a desk. Install on a phone and walk:

1. A sidewalk that ends at grass or a road. Expect "Path ends ahead" about 3 to 4 m out.
2. A sidewalk with a clear bend. Expect "Path curves left" or "right".
3. A long straight block, in sun and under tree shade. Expect silence.

The numbers most likely to need changing are all in `WalkablePath.swift`: the tolerances in `follow` (`40`, `7`, `12`), `endRange`, and the `0.75` curve limit in `read`.
