// Runs on an actual iOS Simulator, using the shipping code concatenated by
// test-audit-regressions.py. Hardware doubles are in the adjacent support file.
import Foundation
import UIKit

@MainActor
final class RegressionSuite {
    var checks = 0
    var failures: [String] = []
    var completed: [String] = []

    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }
    func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); completed.append(name) }
        catch { failures.append("\(name): \(error)") }
    }
    func resetStore(_ label: String) throws -> IdeviceGateway {
        AppPaths.root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RegressionData/\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
        let gateway = IdeviceGateway()
        Minimuxer.shared().ideviceGateway = gateway
        return gateway
    }
    func all() async {
        await run("partial media stream reports bytes and keeps original") {
            let gateway = try self.resetStore("partial-stream")
            gateway.files = ["/DCIM/a.jpg": Data([1, 2, 3])]
            gateway.afterStream = { throw GoldenNuggetError("Injected disconnect after write") }
            do {
                _ = try await AfcMediaBackup.pull(deletingOriginals: true)
                self.check(false, "partial stream must throw")
            } catch {
                self.check(error.localizedDescription.contains("failed after 3 byte(s)"),
                           "failure reports bytes already written")
            }
            self.check(gateway.removed.isEmpty && gateway.files["/DCIM/a.jpg"] == Data([1, 2, 3]),
                       "failed stream retains original")
            self.check(try AfcMediaBackup.read().entries.isEmpty, "failed stream is not journaled")
            self.check(!FileManager.default.fileExists(atPath: AppPaths.mediaStore
                .appendingPathComponent("DCIM/a.jpg.afcpartial").path), "partial copy is removed")
        }
        await run("media journal survives disconnect") {
            let gateway = try self.resetStore("disconnect")
            gateway.files = ["/DCIM/a.jpg": Data([1]), "/DCIM/b.jpg": Data([2])]
            gateway.failurePath = "/DCIM/b.jpg"
            do { _ = try await AfcMediaBackup.pull(deletingOriginals: true); self.check(false, "disconnect must throw") }
            catch {}
            let manifest = try AfcMediaBackup.read()
            self.check(gateway.removed == ["/DCIM/a.jpg"], "only verified first original removed")
            self.check(manifest.entries.map(\.source) == ["/DCIM/a.jpg"], "deleted file remains in committed journal")
            gateway.failurePath = nil
            try await AfcMediaBackup.push()
            self.check(gateway.files["/DCIM/a.jpg"] == Data([1]), "interrupted pull is restorable")
        }
        await run("repeated and empty pulls preserve prior copies") {
            let gateway = try self.resetStore("repeat")
            gateway.files = ["/DCIM/a.jpg": Data([1])]
            _ = try await AfcMediaBackup.pull(deletingOriginals: true)
            gateway.files = ["/DCIM/b.jpg": Data([2])]
            _ = try await AfcMediaBackup.pull(deletingOriginals: true)
            _ = try await AfcMediaBackup.pull(deletingOriginals: false)
            let manifest = try AfcMediaBackup.read()
            self.check(Set(manifest.entries.map(\.source)) == Set(["/DCIM/a.jpg", "/DCIM/b.jpg"]), "all old rows retained")
            gateway.files = ["/DCIM/a.jpg": Data([3, 4])]
            _ = try await AfcMediaBackup.pull(deletingOriginals: false)
            self.check(try Data(contentsOf: AppPaths.mediaStore.appendingPathComponent("DCIM/a.jpg")) == Data([3, 4]), "existing copy replaced atomically")
            self.check(try AfcMediaBackup.read().entries.count == 2, "same-path update does not duplicate journal rows")
        }
        await run("media clear cannot race a live transfer") {
            let gateway = try self.resetStore("transfer-lock")
            gateway.files = ["/DCIM/a.jpg": Data([1])]
            var rejected = false
            gateway.afterStream = {
                do { try AfcMediaBackup.clear() }
                catch { rejected = true }
            }
            _ = try await AfcMediaBackup.pull(deletingOriginals: false)
            self.check(rejected, "Clear rejected during a live pull")
            self.check(try AfcMediaBackup.read().entries.count == 1, "live store remains intact")
            try AfcMediaBackup.clear()
            self.check(!FileManager.default.fileExists(atPath: AppPaths.mediaStore.path), "Clear allowed after transfer ends")
        }
        await run("partial journal append is repaired before resuming") {
            let gateway = try self.resetStore("partial-journal")
            gateway.files = ["/DCIM/a.jpg": Data([1]), "/DCIM/b.jpg": Data([2])]
            gateway.failurePath = "/DCIM/b.jpg"
            do { _ = try await AfcMediaBackup.pull(deletingOriginals: true) } catch {}
            let journal = try FileHandle(forWritingTo: AfcMediaBackup.journalURL)
            try journal.seekToEnd()
            try journal.write(contentsOf: Data("{broken-tail".utf8))
            try journal.close()
            self.check(try AfcMediaBackup.read().entries.count == 1, "partial tail does not hide committed rows")
            gateway.failurePath = nil
            _ = try await AfcMediaBackup.pull(deletingOriginals: true)
            let recovered = try AfcMediaBackup.read()
            self.check(Set(recovered.entries.map(\.source)) == Set(["/DCIM/a.jpg", "/DCIM/b.jpg"]), "next append repairs partial journal")
            self.check(!FileManager.default.fileExists(atPath: AfcMediaBackup.journalURL.path), "successful pull compacts journal")
        }
        await run("large originals are retained") {
            let gateway = try self.resetStore("large")
            gateway.largePath = "/DCIM/video.mov"
            gateway.largeSize = AfcMediaBackup.inlineWriteLimit + 1
            _ = try await AfcMediaBackup.pull(deletingOriginals: true)
            let manifest = try AfcMediaBackup.read()
            self.check(gateway.removed.isEmpty, "unsupported restore size never deletes original")
            self.check(manifest.entries.first?.deleted == false, "large copy marked as non-destructive")
        }
        await run("journal write failure cannot delete original") {
            let gateway = try self.resetStore("journal-error")
            gateway.files = ["/DCIM/a.jpg": Data([1])]
            gateway.afterStream = {
                try FileManager.default.createDirectory(at: AfcMediaBackup.journalURL, withIntermediateDirectories: true)
            }
            do { _ = try await AfcMediaBackup.pull(deletingOriginals: true); self.check(false, "invalid journal must throw") }
            catch {}
            self.check(gateway.removed.isEmpty, "journal failure keeps originals")
        }
        await run("corrupt existing journal is not overwritten") {
            let gateway = try self.resetStore("corrupt")
            gateway.files = ["/DCIM/a.jpg": Data([1])]
            try FileManager.default.createDirectory(at: AppPaths.mediaStore, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: AfcMediaBackup.manifestURL)
            do { _ = try await AfcMediaBackup.pull(deletingOriginals: true); self.check(false, "corrupt journal must throw") }
            catch {}
            self.check(gateway.removed.isEmpty, "corrupt journal keeps originals")
            self.check(try Data(contentsOf: AfcMediaBackup.manifestURL) == Data("not-json".utf8), "corrupt evidence preserved")
        }
        await run("operation gate keeps abandoned calls isolated") {
            let gate = InFlightCall.shared
            try gate.beginRun()
            do { try gate.beginRun(); self.check(false, "concurrent run must be rejected") } catch {}
            gate.enter()
            gate.noteAbandoned(label: "test cancelled backup")
            gate.endRun()
            do { try gate.beginRun(); self.check(false, "abandoned FFI must block a new run") } catch {}
            gate.leave()
            try gate.beginRun()
            gate.endRun()
            self.check(!gate.isBusy, "gate reopens when actual call finishes")
        }
        await run("numeric imports remain bounded and cannot trap") {
            let integer = TweakCatalog.all.first { if case .int = $0.value { return $0.kind == .number }; return false }!
            self.check(TweakValue.double(1e100).coerced(to: integer) == integer.numberValue(from: "1e100"), "huge import uses spec bounds")
            self.check(TweakValue.double(.infinity).coerced(to: integer) == integer.value, "infinity falls back to default")
            self.check(TweakValue.double(.nan).coerced(to: integer) == integer.value, "NaN falls back to default")
            self.check(TweakValue.string("NaN").coerced(to: integer) == integer.value, "string NaN rejected")
            let decimal = TweakCatalog.all.first { if case .double = $0.value { return $0.kind == .number }; return false }!
            self.check(TweakValue.double(1e100).coerced(to: decimal) == .double(decimal.maxValue), "decimal spec bounds enforced")
        }
        await run("stale pairing completion preserves current service and record") {
            try self.resetStore("wireless").files.removeAll()
            try Data("trusted-current-record".utf8).write(to: AppPaths.pairingFile)
            self.check(WirelessPairing.regressionStaleCompletion(), "old completion does not tear down current Bonjour")
            self.check(try Data(contentsOf: AppPaths.pairingFile) == Data("trusted-current-record".utf8), "old pairing does not promote its record")
        }
        await run("keypad total failure throws and partial success is accepted") {
            let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let theme = PasscodeThemeInfo(name: "Regression", filePath: "unused", fileCount: 1,
                                          keysPreview: [:], rawKeyData: ["0": png])
            Airlift.attempts = 0; Airlift.successesAllowed = 0
            do {
                try await PasscodeThemeEngine.apply(theme: theme, language: .en, weight: .regularOnly,
                    pairingPath: "unused", log: { _ in }, progress: { _ in })
                self.check(false, "total keypad failure must throw")
            } catch {}
            Airlift.attempts = 0; Airlift.successesAllowed = 1
            try await PasscodeThemeEngine.apply(theme: theme, language: .en, weight: .regularOnly,
                pairingPath: "unused", log: { _ in }, progress: { _ in })
            self.check(Airlift.attempts > 1, "all cache locations attempted")
        }
        await run("legacy secret logs removed without touching pairing record") {
            _ = try self.resetStore("log-privacy")
            let leaked = AppPaths.root.appendingPathComponent("old.log")
            let clean = AppPaths.root.appendingPathComponent("clean.log")
            try Data("debug {\"private_key\": [1,2,3]}".utf8).write(to: leaked)
            try Data("safe diagnostics".utf8).write(to: clean)
            try Data("pairing record".utf8).write(to: AppPaths.pairingFile)
            try PairingLogPrivacy.removeLegacyDumps(at: [leaked, clean])
            self.check(!(try String(contentsOf: leaked, encoding: .utf8)).contains("private_key"), "legacy secret field removed")
            self.check(try String(contentsOf: clean, encoding: .utf8) == "safe diagnostics", "clean logs retained")
            self.check(try String(contentsOf: AppPaths.pairingFile, encoding: .utf8) == "pairing record", "pairing record retained")
        }
        await run("statusbar native archive class names and values") {
            var overrides = StatusBarOverrides()
            overrides.carrierName = .init(set: true, value: 0, text: "Regression")
            let archive = try StatusBarArchive.build(overrides)
            let names = StatusBarArchive.archivedClassNames(of: archive)
            self.check(names[0] == StatusBarArchive.recordClassName, "native root class recognized")
            self.check(names[1] == StatusBarArchive.dataClassName, "native data class recognized")
            self.check(names[2] == StatusBarArchive.cellularClassName, "native cellular class recognized")
            self.check(try StatusBarArchive.carrierNames(of: archive).primary == "Regression", "carrier round trip")
            self.check(StatusBarArchive.honoursArchivedClassNames, "iOS Foundation honours encoded names")
        }
    }
}

extension WirelessPairing {
    @MainActor static func regressionStaleCompletion() -> Bool {
        let subject = WirelessPairing()
        subject.generation = 2
        let current = NetService(domain: "local.", type: "_gn-regression._tcp.", name: "current", port: 1)
        subject.netService = current
        let stale = AirliftPairing.Paired(deviceName: "old", deviceModel: "old", deviceUDID: "",
                                        pairingFilePath: "/does-not-exist", hostAltIRKHex: "")
        subject.finish(.success(stale), generation: 1)
        return subject.netService === current
    }
}

@main
@MainActor
final class RegressionApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        let label = UILabel()
        label.numberOfLines = 0; label.textAlignment = .center
        label.text = "GoldenNugget regression tests running…"
        label.frame = CGRect(x: 20, y: 120, width: 350, height: 400)
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller; window?.makeKeyAndVisible()
        Task {
            let suite = RegressionSuite()
            await suite.all()
            let report: [String: Any] = ["checks": suite.checks, "failures": suite.failures,
                "completed": suite.completed, "os": UIDevice.current.systemVersion,
                "environment": "iOS Simulator; production Swift with hardware doubles"]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("regression-results.json")
            try! data.write(to: url, options: .atomic)
            label.text = suite.failures.isEmpty ? "PASS\n\(suite.checks) checks\n\(suite.completed.count) scenarios\niOS \(UIDevice.current.systemVersion)" : "FAIL\n" + suite.failures.joined(separator: "\n")
            label.textColor = suite.failures.isEmpty ? .systemGreen : .systemRed
            print(String(data: data, encoding: .utf8)!)
        }
        return true
    }
}
