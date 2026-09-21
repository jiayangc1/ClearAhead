import CoreML
import CryptoKit
import Foundation

struct PreparedModelPair {
    let detector: URL
    let depth: URL
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
        quantization: String,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<PreparedModelPair, Error>) -> Void
    ) {
        queue.async {
            do {
                guard ["n", "s", "m", "l", "x"].contains(variant), quantization == "int8" else {
                    throw ModelManagerError.unsupportedSelection
                }
                let detectorKey = "yolo26\(variant)-\(quantization)-detector"
                let depthKey = "yolo26\(variant)-\(quantization)-depth"

                if let bundled = self.bundledPair(variant: variant) {
                    progress(1, "YOLO26\(variant) models are ready")
                    completion(.success(bundled))
                    return
                }

                progress(0.02, "Checking YOLO26\(variant) model catalog…")
                let catalog = try self.loadCatalog()
                guard let detector = catalog.models.first(where: { $0.key == detectorKey }),
                      let depth = catalog.models.first(where: { $0.key == depthKey }) else {
                    throw ModelManagerError.missingCatalogEntry
                }

                let detectorURL = try self.install(detector, progressRange: 0.05...0.52, progress: progress)
                let depthURL = try self.install(depth, progressRange: 0.52...0.99, progress: progress)
                progress(1, "YOLO26\(variant) detector and depth models are ready")
                completion(.success(PreparedModelPair(detector: detectorURL, depth: depthURL)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func bundledPair(variant: String) -> PreparedModelPair? {
        let bundles = [Bundle.main, Bundle(for: ModelManager.self)]
        for bundle in bundles {
            let detector = bundle.url(forResource: "YOLO26\(variant)", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "YOLO26\(variant)", withExtension: "mlpackage")
            let depth = bundle.url(forResource: "YOLO26\(variant)Depth", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "YOLO26\(variant)Depth", withExtension: "mlpackage")
            if let detector, let depth {
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
            try data.write(to: cachedURL, options: .atomic)
            return try JSONDecoder().decode(ModelCatalog.self, from: data)
        } catch {
            guard let data = try? Data(contentsOf: cachedURL) else { throw error }
            return try JSONDecoder().decode(ModelCatalog.self, from: data)
        }
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
        let installedFilesComplete = try model.files.allSatisfy { file in
            fileManager.fileExists(atPath: try safeRelativeURL(file.path, under: destination).path)
        }
        if fileManager.fileExists(atPath: destination.path),
           installedFilesComplete,
           (try? String(contentsOf: marker, encoding: .utf8)) == signature {
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
            return "Only INT8 YOLO26 detector and depth model pairs are supported."
        case .missingCatalogEntry:
            return "The selected YOLO26 model pair is not available in the download catalog."
        case let .checksumMismatch(asset):
            return "The downloaded model failed verification: \(asset)"
        case let .unsafeCatalogPath(path):
            return "The model catalog contains an unsafe path: \(path)"
        }
    }
}
