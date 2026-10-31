import Foundation
import Darwin
import PythonKit

struct IshaConversionResult {
    let outputURL: URL
    let logs: [String]
    let isDirectory: Bool
}

final class PythonConverter {
    static let shared = PythonConverter()
    private let queue = DispatchQueue(label: "isha.converter.python", qos: .userInitiated)
    private var initialized = false

    func convert(
        input: URL,
        outputDirectory: URL,
        textureQuality: String,
        createZIP: Bool,
        fullValidation: Bool,
        preserveShadows: Bool,
        completion: @escaping (Result<IshaConversionResult, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.initializeRuntime()
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

                let appRoot = Bundle.main.bundleURL
                let appPath = appRoot.appendingPathComponent("app", isDirectory: true).path
                let packagesPath = appRoot.appendingPathComponent("app_packages", isDirectory: true).path
                let shaderPath = appRoot.appendingPathComponent("app/ios_shaders", isDirectory: true).path
                let sys = Python.import("sys")
                sys.path.insert(0, appPath)
                sys.path.insert(0, packagesPath)

                let bridge = Python.import("converter_bridge")
                let raw = try bridge.run_conversion.throwing.dynamicallyCall(withArguments: [
                    input.path,
                    shaderPath,
                    outputDirectory.path,
                    input.lastPathComponent,
                    textureQuality,
                    createZIP,
                    fullValidation,
                    preserveShadows
                ])
                let jsonText = String(raw) ?? raw.description
                guard let data = jsonText.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw IshaConverterError.invalidResponse(jsonText)
                }
                let logs = payload["logs"] as? [String] ?? []
                guard (payload["ok"] as? Bool) == true,
                      let outputPath = payload["output"] as? String else {
                    throw IshaConverterError.conversionFailed(payload["error"] as? String ?? jsonText)
                }
                let outputURL = URL(fileURLWithPath: outputPath)
                let isDirectory = (payload["isDirectory"] as? Bool) ?? false
                completion(.success(IshaConversionResult(
                    outputURL: outputURL,
                    logs: logs,
                    isDirectory: isDirectory
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func initializeRuntime() throws {
        guard !initialized else { return }
        let appRoot = Bundle.main.bundleURL
        let pythonRoot = appRoot.appendingPathComponent("python", isDirectory: true)
        let pythonLibrary = appRoot.appendingPathComponent("Frameworks/Python.framework/Python").path
        setenv("PYTHON_LIBRARY", pythonLibrary, 1)
        setenv("PYTHONHOME", pythonRoot.path, 1)
        setenv("PYTHON_VERSION", "3.14", 1)
        setenv("PYTHONPATH", "\(appRoot.appendingPathComponent("app").path):\(appRoot.appendingPathComponent("app_packages").path)", 1)
        PythonLibrary.useVersion(3, 14)
        PythonLibrary.useLibrary(at: pythonLibrary)
        _ = Python.import("sys")
        initialized = true
    }
}

enum IshaConverterError: LocalizedError {
    case invalidResponse(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let value):
            return "Hindi mabasa ang resulta ng converter: \(value)"
        case .conversionFailed(let value):
            return value
        }
    }
}
