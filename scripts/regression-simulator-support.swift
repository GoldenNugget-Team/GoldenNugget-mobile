// Hardware doubles for the simulator regression app. The runner compiles the
// production Swift files unchanged except for imports of device-only modules.
// No pairing, sandbox escape, deletion or restore request reaches a real phone.
import Foundation
import UIKit
import UniformTypeIdentifiers

struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AppPaths {
    static var root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RegressionData", isDirectory: true)
    static var mediaStore: URL { root.appendingPathComponent("Media", isDirectory: true) }
    static var pairingFile: URL { root.appendingPathComponent("pairingfile.mobiledevicepairing") }
    static var appLog: URL { root.appendingPathComponent("goldennugget.log") }
}

final class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()
    func log(_ text: String) { AppLog.write(text) }
}

enum MinimuxerConstants {
    static let defaultHostModel = "Mac17,7"
    static let defaultAdDomain = "local."
    static let remotePairingPairableHostServiceType = "_remotepairing-pairable-host._tcp."
}

struct AfcFsEntry {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date? = nil
    var linkTarget: String? = nil
}

final class IdeviceGateway {
    var files: [String: Data] = [:]
    var failurePath: String?
    var afterStream: (() throws -> Void)?
    var removed: [String] = []
    var writes: [String] = []
    var largePath: String?
    var largeSize: Int64 = 0
    /// How many times a file body was actually streamed. The pull's skip is only
    /// real if a second pull leaves this unchanged.
    var streamCount = 0

    func afcEntryInfo(path: String) async throws -> AfcFsEntry {
        if path == "/DCIM" { return .init(path: path, name: "DCIM", isDirectory: true, size: 0) }
        if path == largePath { return .init(path: path, name: "video.mov", isDirectory: false, size: largeSize) }
        guard let data = files[path] else { throw GoldenNuggetError("Missing fake AFC file") }
        return .init(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                     isDirectory: false, size: Int64(data.count))
    }
    func afcList(path: String) async throws -> [AfcFsEntry] {
        var result: [AfcFsEntry] = []
        for path in files.keys.sorted() { result.append(try await afcEntryInfo(path: path)) }
        if let largePath { result.append(try await afcEntryInfo(path: largePath)) }
        return result
    }
    func afcStreamFile(path: String, chunkSize: Int, _ consume: (Data) throws -> Void) async throws -> Int64 {
        if path == failurePath { throw GoldenNuggetError("Injected AFC disconnect") }
        if path == largePath {
            streamCount += 1
            var remaining = largeSize
            while remaining > 0 {
                let count = Int(min(Int64(chunkSize), remaining))
                try consume(Data(count: count))
                remaining -= Int64(count)
            }
            return largeSize
        }
        streamCount += 1
        let data = files[path]!
        try consume(data)
        try afterStream?()
        return Int64(data.count)
    }
    func afcDelete(path: String) async throws { removed.append(path); files.removeValue(forKey: path) }
    func afcMakeDirectory(path: String) async throws {}
    func afcWrite(path: String, data: Data) async throws { writes.append(path); files[path] = data }
}

final class Minimuxer {
    static let instance = Minimuxer()
    static func shared() -> Minimuxer { instance }
    var ideviceGateway: IdeviceGateway? = IdeviceGateway()
}

enum Airlift {
    static var attempts = 0
    static var successesAllowed = 0
    static func writeDir(pairingPath: String, sourceDir: String, targetDir: String) async throws {
        attempts += 1
        if attempts > successesAllowed { throw GoldenNuggetError("Injected AirLift write failure") }
    }
    static func extractPassthm(archivePath: String, destDir: String) async throws -> String {
        throw GoldenNuggetError("No archive extraction in this hardware double")
    }
}

enum AirliftPairing {
    struct Ready { let serviceID: String; let port: UInt16; let txt: [String: String] }
    struct Paired {
        let deviceName: String
        let deviceModel: String
        let deviceUDID: String
        let pairingFilePath: String
        let hostAltIRKHex: String
    }
    static func run(name: String, model: String, outPath: String, hostAltIRKHex: String?,
                    onReady: @escaping (Ready) -> Void,
                    onPin: @escaping (String) -> Void) throws -> Paired {
        throw GoldenNuggetError("No RemotePairing device in simulator tests")
    }
}
