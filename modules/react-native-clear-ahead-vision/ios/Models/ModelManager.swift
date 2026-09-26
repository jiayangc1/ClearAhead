import CoreML
import CryptoKit
import Foundation

struct PreparedModelPair {
    let detector: URL
    let depth: URL?
}

private struct ModelCatalog: Decodable {
    let models: [CatalogModel]
}

private struct CatalogModel: Decodable {
    let key: String
    let package: String
    let files: [CatalogFile]
}

private struct CatalogFile: Decodable {
    let path: String
    let asset: String
    let sha256: String
}

final class ModelManager {
    static let shared = ModelManager()

    private let fileManager = FileManager.default
    private let releaseRoot = URL(string: "https://github.com/jiayangc1/cac/releases/download/yolo26-coreml-v1/")!
    private let queue = DispatchQueue(label: "com.clearahead.models", qos: .userInitiated)

    private init() {}

    func prepare(
        variant: String,
        allowDetectorOnly: Bool,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<PreparedModelPair, Error>) -> Void,
        recoveredDepth: @escaping (URL) -> Void
    ) {
        queue.async {
            do {
                guard ["n", "s", "m", "l", "x"].contains(variant) else {
                    throw ModelManagerError.unsupportedSelection
                }
                let detectorKey = "yolo26\(variant)-int8-detector"
                let depthKey = "yolo26\(variant)-int8-depth"

                if let bundled = self.bundledPair(variant: variant, allowDetectorOnly: allowDetectorOnly) {
                    progress(1, "YOLO26\(variant) models are ready")
                    completion(.success(bundled))
                    if allowDetectorOnly && bundled.depth == nil {
                        self.repairDepth(key: depthKey, progress: progress, recoveredDepth: recoveredDepth)
                    }
                    return
                }

                if let cached = try self.installedPair(
                    detectorKey: detectorKey,
                    depthKey: depthKey,
                    allowDetectorOnly: allowDetectorOnly
                ) {
                    progress(1, "YOLO26\(variant) cached models are ready")
                    completion(.success(cached))
                    if allowDetectorOnly && cached.depth == nil {
                        self.repairDepth(key: depthKey, progress: progress, recoveredDepth: recoveredDepth)
                    }
                    return
                }

                progress(0.02, "Checking YOLO26\(variant) model catalog…")
                let catalog = try self.loadCatalog()
                guard let detector = catalog.models.first(where: { $0.key == detectorKey }) else {
                    throw ModelManagerError.missingCatalogEntry
                }

                let detectorURL = try self.install(detector, progressRange: 0.05...0.52, progress: progress)
                var depthURL: URL?
                do {
                    guard let depth = catalog.models.first(where: { $0.key == depthKey }) else {
                        throw ModelManagerError.missingCatalogEntry
                    }
                    depthURL = try self.install(depth, progressRange: 0.52...0.99, progress: progress)
                } catch {
                    if !allowDetectorOnly { throw error }
                    progress(1, "Depth unavailable. Named object cues remain active.")
                }
                if depthURL != nil {
                    progress(1, "YOLO26\(variant) detector and depth models are ready")
                }
                completion(.success(PreparedModelPair(detector: detectorURL, depth: depthURL)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func repairDepth(
        key: String,
        progress: @escaping (Double, String) -> Void,
        recoveredDepth: @escaping (URL) -> Void
    ) {
        do {
            let catalog = try loadCatalog()
            guard let depth = catalog.models.first(where: { $0.key == key }) else {
                throw ModelManagerError.missingCatalogEntry
            }
            let url = try install(depth, progressRange: 0.05...0.99, progress: progress)
            recoveredDepth(url)
            progress(1, "Depth model recovered")
        } catch {
            progress(1, "Depth unavailable. Named object cues remain active.")
        }
    }

    private func bundledPair(variant: String, allowDetectorOnly: Bool) -> PreparedModelPair? {
        let bundles = [Bundle.main, Bundle(for: ModelManager.self)]
        for bundle in bundles {
            let detector = bundle.url(forResource: "YOLO26\(variant)", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "YOLO26\(variant)", withExtension: "mlpackage")
            let depth = bundle.url(forResource: "YOLO26\(variant)Depth", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "YOLO26\(variant)Depth", withExtension: "mlpackage")
            if let detector, depth != nil || allowDetectorOnly {
                return PreparedModelPair(detector: detector, depth: depth)
            }
        }
        return nil
    }

    private func loadCatalog() throws -> ModelCatalog {
        let cacheRoot = try modelsRoot()
        let cachedURL = cacheRoot.appendingPathComponent("model-catalog.json")
        let remoteURL = releaseRoot.appendingPathComponent("model-catalog.json")
        do {
            let data = try Data(contentsOf: remoteURL)
            let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
            try data.write(to: cachedURL, options: .atomic)
            return catalog
        } catch {
            guard let data = try? Data(contentsOf: cachedURL) else { throw error }
            return try JSONDecoder().decode(ModelCatalog.self, from: data)
        }
    }

    private func installedPair(
        detectorKey: String,
        depthKey: String,
        allowDetectorOnly: Bool
    ) throws -> PreparedModelPair? {
        let cachedURL = try modelsRoot().appendingPathComponent("model-catalog.json")
        guard let data = try? Data(contentsOf: cachedURL),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data),
              let detector = catalog.models.first(where: { $0.key == detectorKey }),
              let detectorURL = try verifiedInstalledURL(for: detector) else { return nil }
        let depthURL = try catalog.models.first(where: { $0.key == depthKey })
            .flatMap { try verifiedInstalledURL(for: $0) }
        guard depthURL != nil || allowDetectorOnly else { return nil }
        return PreparedModelPair(detector: detectorURL, depth: depthURL)
    }

    private func verifiedInstalledURL(for model: CatalogModel) throws -> URL? {
        let root = try modelsRoot()
        guard !model.files.isEmpty else { return nil }
        let destination = try packageURL(named: model.package, under: root)
        let marker = root.appendingPathComponent("\(model.package).complete")
        let signature = model.files.map { "\($0.path):\($0.sha256)" }.joined(separator: "\n")
        guard fileManager.fileExists(atPath: destination.path),
              (try? String(contentsOf: marker, encoding: .utf8)) == signature else { return nil }
        for file in model.files {
            let fileURL = try safeRelativeURL(file.path, under: destination)
            guard fileManager.fileExists(atPath: fileURL.path),
                  (try? sha256(of: fileURL)) == file.sha256 else { return nil }
        }
        return destination
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func install(
        _ model: CatalogModel,
        progressRange: ClosedRange<Double>,
        progress: @escaping (Double, String) -> Void
    ) throws -> URL {
        let root = try modelsRoot()
        guard !model.files.isEmpty else { throw ModelManagerError.missingCatalogEntry }
        let destination = try packageURL(named: model.package, under: root)
        let marker = root.appendingPathComponent("\(model.package).complete")
        let signature = model.files.map { "\($0.path):\($0.sha256)" }.joined(separator: "\n")
        if try verifiedInstalledURL(for: model) != nil {
            return destination
        }

        let staging = root.appendingPathComponent(".\(model.package).download", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for (index, file) in model.files.enumerated() {
                let fraction = Double(index) / Double(max(model.files.count, 1))
                let value = progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound)
                progress(value, "Downloading \(model.package)…")
                let data = try Data(contentsOf: try releaseAssetURL(named: file.asset))
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw ModelManagerError.checksumMismatch(file.asset)
                }
                let fileURL = try safeRelativeURL(file.path, under: staging)
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            }
            try? fileManager.removeItem(at: marker)
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: destination.deletingPathExtension().appendingPathExtension("mlmodelc"))
            try fileManager.moveItem(at: staging, to: destination)
            try signature.write(to: marker, atomically: true, encoding: .utf8)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func modelsRoot() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appendingPathComponent("ClearAheadModels", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func packageURL(named package: String, under root: URL) throws -> URL {
        guard !package.isEmpty,
              package != ".",
              package != "..",
              (package as NSString).lastPathComponent == package else {
            throw ModelManagerError.unsafeCatalogPath(package)
        }
        return root.appendingPathComponent(package, isDirectory: true)
    }

    private func safeRelativeURL(_ path: String, under root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              candidate.path.hasPrefix(standardizedRoot.path + "/") else {
            throw ModelManagerError.unsafeCatalogPath(path)
        }
        return candidate
    }

    private func releaseAssetURL(named asset: String) throws -> URL {
        guard !asset.isEmpty,
              asset != ".",
              asset != "..",
              (asset as NSString).lastPathComponent == asset else {
            throw ModelManagerError.unsafeCatalogPath(asset)
        }
        return releaseRoot.appendingPathComponent(asset)
    }
}

private enum ModelManagerError: LocalizedError {
    case unsupportedSelection
    case missingCatalogEntry
    case checksumMismatch(String)
    case unsafeCatalogPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection:
            return "Unsupported YOLO26 model variant."
        case .missingCatalogEntry:
            return "The selected YOLO26 model pair is not available in the download catalog."
        case let .checksumMismatch(asset):
            return "The downloaded model failed verification: \(asset)"
        case let .unsafeCatalogPath(path):
            return "The model catalog contains an unsafe path: \(path)"
        }
    }
}
