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
