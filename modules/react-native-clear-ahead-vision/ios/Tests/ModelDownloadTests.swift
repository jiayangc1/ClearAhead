import XCTest
import ZIPFoundation
@testable import ClearAheadVision

final class ModelDownloadTests: XCTestCase {
    func testCellularOrExpensiveConnectionsRequireConsent() {
        XCTAssertTrue(ModelManager.requiresConsent(cellular: true, expensive: false, constrained: false))
        XCTAssertTrue(ModelManager.requiresConsent(cellular: false, expensive: true, constrained: false))
        XCTAssertTrue(ModelManager.requiresConsent(cellular: false, expensive: false, constrained: true))
        XCTAssertFalse(ModelManager.requiresConsent(cellular: false, expensive: false, constrained: false))
    }

    func testCancellationInterruptsPendingWork() throws {
        let request = ModelDownloadRequest()
        var cancelled = false
        request.onCancel { cancelled = true }
        request.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try request.check())
        var lateCancelled = false
        request.onCancel { lateCancelled = true }
        XCTAssertTrue(lateCancelled)
    }

    func testExtractionRejectsTraversalAndKeepsExistingPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.mlpackage")
        try Data([7]).write(to: old)
        let zip = root.appendingPathComponent("bad.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "yolo26s.mlpackage/../../old.mlpackage", type: .file,
                             uncompressedSize: 1, provider: { _, _ in Data([8]) })
        XCTAssertThrowsError(try ModelManager.extract(zip, packageName: "yolo26s.mlpackage",
                                                     to: root.appendingPathComponent("stage"), request: ModelDownloadRequest()))
        XCTAssertEqual(try Data(contentsOf: old), Data([7]))
    }

    func testExtractionAcceptsCompletePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("model.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        for path in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
            try archive.addEntry(with: "yolo26s.mlpackage/\(path)", type: .file,
                                 uncompressedSize: 1, provider: { _, _ in Data([7]) })
        }
        let destination = root.appendingPathComponent("stage")
        let package = try ModelManager.extract(zip, packageName: "yolo26s.mlpackage", to: destination,
                                               request: ModelDownloadRequest())
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")), Data([7]))
    }

    func testWrongChecksumRejectsAsset() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try ModelManager.verify(file, size: 3, sha256: String(repeating: "0", count: 64)))
    }
}
