import CryptoKit
import Foundation
import Network
import UIKit
import ZIPFoundation

struct PreparedModelPair {
    let detector: URL
    let depth: URL?
}

final class ModelDownloadRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (() -> Void)?

    func cancel() {
        lock.lock()
        cancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    func onCancel(_ action: @escaping () -> Void) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { cancellation = action }
        lock.unlock()
        if alreadyCancelled { action() }
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CocoaError(.userCancelled) }
    }

    func commit(_ action: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CocoaError(.userCancelled) }
        try action()
    }

    // Only the serial model worker waits. Cancellation releases pending network
    // checks and prompts without blocking main or subsequent model selections.
    func wait<T>(timeout: TimeInterval? = nil, _ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        start { value in result = value; semaphore.signal() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            try check()
            if let deadline, Date() >= deadline { throw URLError(.timedOut) }
        }
        try check()
        return try result!.get()
    }
}

private struct OfficialModelAsset: Decodable {
    let name: String
    let size: Int64
    let sha256: String
}

final class ModelManager {
    static let shared = ModelManager()
    private let queue = DispatchQueue(label: "com.clearahead.models", qos: .userInitiated)
    private let manager = FileManager.default
    private let releaseRoot = "https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/"
    private init() {}

    @discardableResult
    func prepare(
        variant: String,
        allowDetectorOnly: Bool,
        progress: @escaping (Double, String) -> Void,
        validate: @escaping (PreparedModelPair) throws -> Void = { _ in },
        completion: @escaping (Result<PreparedModelPair, Error>) -> Void
    ) -> ModelDownloadRequest {
        let request = ModelDownloadRequest()
        queue.async {
            do {
                try request.check()
                guard ["n", "s", "m", "l", "x"].contains(variant) else { throw Self.error("Unsupported model selection.") }
                if let pair = self.bundledPair(variant, allowDetectorOnly: allowDetectorOnly) {
                    progress(0.02, "Loading bundled models…")
                    try validate(pair)
                    try request.check()
                    progress(1, pair.depth == nil ? "Depth unavailable. Named object cues remain active." : "Bundled models are ready")
                    completion(.success(pair))
                    return
                }
                let assets = try self.assets(variant)
                let support = try self.manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
                let root = support.appendingPathComponent("ClearAheadOfficialModels", isDirectory: true)
                try self.manager.createDirectory(at: root, withIntermediateDirectories: true)
                var excludedRoot = root
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try excludedRoot.setResourceValues(values)
                let key = "\(variant)-\(assets[0].sha256.prefix(16))-\(assets[1].sha256.prefix(16))"
                let destination = root.appendingPathComponent(key, isDirectory: true)
                if let pair = self.cachedPair(at: destination, assets: assets) {
                    progress(0.02, "Loading cached models…")
                    try validate(pair)
                    try request.check()
                    progress(1, "Cached models are ready")
                    completion(.success(pair))
                    return
                }
                progress(0, "Checking connection before downloading YOLO26\(variant)…")
                let cellularAllowed = try self.downloadConsent(variant: variant, bytes: assets.reduce(0) { $0 + $1.size }, request: request)
                let stage = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
                try self.manager.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? self.manager.removeItem(at: stage) }
                var packages: [URL] = []
                let totalBytes = assets.reduce(Int64(0)) { $0 + $1.size }
                var completedBytes: Int64 = 0
                for (index, asset) in assets.enumerated() {
                    try request.check()
                    let message = "Downloading YOLO26\(variant) \(index == 0 ? "detector" : "depth")…"
                    progress(Double(completedBytes) / Double(totalBytes) * 0.85, message)
                    let archive = stage.appendingPathComponent(asset.name)
                    let offset = completedBytes
                    try self.download(asset, to: archive, cellularAllowed: cellularAllowed, request: request) { received in
                        progress(Double(offset + min(received, asset.size)) / Double(totalBytes) * 0.85, message)
                    }
                    try Self.verify(archive, size: asset.size, sha256: asset.sha256)
                    packages.append(try Self.extract(archive, packageName: String(asset.name.dropLast(4)), to: stage, request: request))
                    try self.manager.removeItem(at: archive)
                    completedBytes += asset.size
                }
                let pair = PreparedModelPair(detector: packages[0], depth: packages[1])
                progress(0.85, "Validating downloaded models…")
                try request.check()
                try validate(pair)
                let identities = try packages.map { try Self.contentIdentity(at: $0) }
                try JSONEncoder().encode(identities).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
                // Replace only after both packages pass checksums and Core ML loading.
                try request.commit {
                    if self.manager.fileExists(atPath: destination.path) {
                        _ = try self.manager.replaceItemAt(destination, withItemAt: stage)
                    } else { try self.manager.moveItem(at: stage, to: destination) }
                }
                for old in try self.manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    where old.lastPathComponent.hasPrefix("\(variant)-") && old != destination {
                    try? self.manager.removeItem(at: old)
                }
                try request.check()
                progress(1, "YOLO26\(variant) detector and depth are ready")
                completion(.success(PreparedModelPair(
                    detector: destination.appendingPathComponent(packages[0].lastPathComponent),
                    depth: destination.appendingPathComponent(packages[1].lastPathComponent))))
            } catch { completion(.failure(error)) }
        }
        return request
    }

    private func bundledPair(_ variant: String, allowDetectorOnly: Bool) -> PreparedModelPair? {
        func resource(_ name: String) -> URL? {
            for bundle in [Bundle.main, Bundle(for: ModelManager.self)] {
                if let url = bundle.url(forResource: name, withExtension: "mlmodelc")
                    ?? bundle.url(forResource: name, withExtension: "mlpackage") { return url }
            }
            return nil
        }
        guard let detector = resource("YOLO26\(variant)") else { return nil }
        let depth = resource("YOLO26\(variant)Depth")
        guard depth != nil || allowDetectorOnly else { return nil }
        return PreparedModelPair(detector: detector, depth: depth)
    }

    private func assets(_ variant: String) throws -> [OfficialModelAsset] {
        let url = [Bundle.main, Bundle(for: ModelManager.self)].compactMap {
            $0.url(forResource: "official-models", withExtension: "json")
        }.first
        guard let url else { throw Self.error("Official model download manifest is missing.") }
        let manifest = try JSONDecoder().decode([OfficialModelAsset].self, from: Data(contentsOf: url))
        return try ["yolo26\(variant).mlpackage.zip", "yolo26\(variant)-depth.mlpackage.zip"].map { name in
            guard let asset = manifest.first(where: { $0.name == name }), asset.size > 0,
                  asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw Self.error("Official model checksum is missing.")
            }
            return asset
        }
    }

    private func cachedPair(at root: URL, assets: [OfficialModelAsset]) -> PreparedModelPair? {
        let receipt = root.appendingPathComponent("receipt.json")
        guard let data = try? Data(contentsOf: receipt),
              let identities = try? JSONDecoder().decode([String].self, from: data), identities.count == 2 else { return nil }
        let packages = assets.map { root.appendingPathComponent(String($0.name.dropLast(4))) }
        guard let actual = try? packages.map({ try Self.contentIdentity(at: $0) }), actual == identities else { return nil }
        return PreparedModelPair(detector: packages[0], depth: packages[1])
    }

    static func requiresConsent(cellular: Bool, expensive: Bool, constrained: Bool) -> Bool {
        cellular || expensive || constrained
    }

    private func downloadConsent(variant: String, bytes: Int64, request: ModelDownloadRequest) throws -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let path: NWPath = try request.wait(timeout: 5) { finish in
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                finish(.success(path))
            }
            request.onCancel { monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.clearahead.model-network"))
        }
        guard path.status == .satisfied else { throw URLError(.notConnectedToInternet) }
        guard Self.requiresConsent(cellular: path.usesInterfaceType(.cellular), expensive: path.isExpensive,
                                  constrained: path.isConstrained) else { return false }
        return try request.wait { finish in
            DispatchQueue.main.async {
                do { try request.check() } catch { finish(.failure(error)); return }
                guard UIApplication.shared.applicationState == .active,
                      var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .filter({ $0.activationState == .foregroundActive })
                        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
                    finish(.failure(Self.error("Open the app to approve a cellular model download.")))
                    return
                }
                while let presented = presenter.presentedViewController { presenter = presented }
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                let alert = UIAlertController(title: "Download using cellular data?",
                    message: "YOLO26\(variant) detector and depth need \(size). This connection uses cellular or metered data.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(.failure(CocoaError(.userCancelled))) })
                alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in finish(.success(true)) })
                request.onCancel { DispatchQueue.main.async { alert.dismiss(animated: true) } }
                presenter.present(alert, animated: true)
            }
        }
    }

    private func download(_ asset: OfficialModelAsset, to destination: URL, cellularAllowed: Bool,
                          request: ModelDownloadRequest, progress: @escaping (Int64) -> Void) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = cellularAllowed
        configuration.allowsExpensiveNetworkAccess = cellularAllowed
        configuration.allowsConstrainedNetworkAccess = cellularAllowed
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var observation: NSKeyValueObservation?
        let progressLock = NSLock()
        var lastProgressTime: TimeInterval = 0
        defer { observation?.invalidate() }
        let _: Void = try request.wait { finish in
            let task = session.downloadTask(with: URL(string: releaseRoot + asset.name)!) { temporary, response, error in
                do {
                    if let error { throw error }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let temporary,
                          http.url?.scheme == "https" else { throw Self.error("Official model download failed.") }
                    try request.check()
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    finish(.success(()))
                } catch { finish(.failure(error)) }
            }
            request.onCancel { task.cancel() }
            observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
                progressLock.lock()
                let now = ProcessInfo.processInfo.systemUptime
                let report = now - lastProgressTime >= 0.1
                if report { lastProgressTime = now }
                progressLock.unlock()
                guard report else { return }
                progress(task.countOfBytesReceived)
            }
            task.resume()
        }
    }

    static func packageBytes(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 1 }
        return files.reduce(Int64(0)) { total, item in
            guard let file = item as? URL, let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    static func verify(_ file: URL, size: Int64, sha256 expected: String) throws {
        let actualSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actualSize.map({ Int64($0) }) == size else { throw error("Model download is incomplete.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw error("Official model checksum mismatch.")
        }
    }

    static func extract(_ zip: URL, packageName: String, to root: URL, request: ModelDownloadRequest) throws -> URL {
        let archive = try Archive(url: zip, accessMode: .read)
        var size: UInt64 = 0
        for entry in archive {
            try request.check()
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !parts.contains(".."), !parts.contains("."), parts.first.map(String.init) == packageName,
                  entry.type != .symlink else { throw error("Unsafe path in model archive.") }
            guard entry.uncompressedSize <= 300_000_000 - size else { throw error("Model archive exceeds size limit.") }
            size += entry.uncompressedSize
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw error("Unsafe model path.") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let progress = Progress()
            request.onCancel { progress.cancel() }
            let checksum = try archive.extract(entry, to: target, progress: progress)
            guard checksum == entry.checksum else { throw error("Corrupt model archive entry.") }
        }
        let package = root.appendingPathComponent(packageName)
        for file in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
            guard FileManager.default.fileExists(atPath: package.appendingPathComponent(file).path) else {
                throw error("Model package is incomplete.")
            }
        }
        return package
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ClearAheadModels", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func contentIdentity(at root: URL) throws -> String {
        let manager = FileManager.default
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (enumerator?.allObjects as? [URL] ?? [root])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
