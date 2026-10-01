import XCTest
@testable import ClearAheadVision

final class ModelManagerTests: XCTestCase {
    func testUnsupportedVariantFailsWithoutDownloading() {
        let finished = expectation(description: "selection rejected")
        ModelManager.shared.prepare(variant: "unsupported", allowDetectorOnly: false, progress: { _, _ in }, completion: { result in
            if case .success = result { XCTFail("Unsupported variant must fail") }
            finished.fulfill()
        })
        wait(for: [finished], timeout: 2)
    }

    func testContentIdentityChangesEvenWhenModificationDateDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("weights.bin")
        try Data([1, 2]).write(to: file)
        let before = try ModelManager.contentIdentity(at: root)
        let date = Date(timeIntervalSince1970: 1)
        try Data([1, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        XCTAssertNotEqual(before, try ModelManager.contentIdentity(at: root))
    }
}
