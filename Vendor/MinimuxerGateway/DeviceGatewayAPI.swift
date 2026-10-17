//
//  DeviceGatewayAPI.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

public struct PairedDeviceRecord: Sendable {
    public let name: String
    public let model: String
    public let pairingFilePath: String
    public let pairingFile: any PairingFile
    
    public init(name: String, model: String, pairingFilePath: String, pairingFile: any PairingFile) {
        self.name = name
        self.model = model
        self.pairingFilePath = pairingFilePath
        self.pairingFile = pairingFile
    }
}

public protocol DeviceGatewayAPI: AnyObject, Sendable {
    var pairingFileType: PairingProtocol { get }
    var pairingFileData: Data? { get }
    var pairingDataDict: [String: any Sendable]? { get }

    func getPort(for protocol: PairingProtocol) -> UInt16
    func setPort(_ port: UInt16, for protocol: PairingProtocol)

    func start(pairingFileContent: String) async throws
    func setDeviceEndpointIp(_ ip: String?)
    func setLogging(_ enabled: Bool)
    func getPairingFileType() -> PairingProtocol

    func fetchUDID() async throws -> String?
    func getLockdownValue(key: String) async throws -> String?

    func isDDIMounted() async throws -> Bool
    func mountDeveloperImage(image: Data, signature: Data) async throws
    func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws

    func installProvisioningProfile(profile: Data) async throws
    func removeProvisioningProfile(id: String) async throws
    func dumpProfiles(docsPath: String) async throws -> String
    func removeApp(bundleId: String) async throws
    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws
    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws
    func installIpa(bundleId: String) async throws
    func installAppBundle(bundleId: String, appName: String) async throws
    func wipeContainer(identifier: String) async throws

    func debugApp(appId: String) async throws
    func debugProcess(pid: UInt32) async throws

    func performHeartbeat(interval: UInt64) async throws -> UInt64

    func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord

    func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord

    func afcListDirectory(bundleId: String, path: String) async throws -> [String]
    func afcReadFile(bundleId: String, path: String) async throws -> Data
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64)

    // MARK: - AFC filesystem (com.apple.afc)
    //
    // The three calls above are *house_arrest*: each one is scoped to one
    // app's Documents container by `bundleId`.  What follows is the plain AFC
    // service, whose root is the device's `/var/mobile/Media` (DCIM, Downloads,
    // Books, Recordings, …) with read **and** write.  It is the same client
    // `sendIpaAfc` already uses to push an IPA, so no new library is involved.
    //
    // Paths are absolute in AFC's own space: "/" is the Media root, and there is
    // no ".." support — every path this API takes is a path the caller already
    // got out of `afcList(path:)` or a parent of one.
    func afcVolumeInfo() async throws -> AfcFsVolumeInfo
    func afcList(path: String) async throws -> [AfcFsEntry]
    func afcEntryInfo(path: String) async throws -> AfcFsEntry
    func afcRead(path: String) async throws -> Data
    func afcWrite(path: String, data: Data) async throws
    func afcMakeDirectory(path: String) async throws
    func afcRename(path: String, to newPath: String) async throws
    func afcDelete(path: String) async throws

    /// Read one file into `onChunk`, in order, without ever holding the whole
    /// file in memory. Returns the number of bytes handed over.
    ///
    /// `afcRead` is right for a preview and wrong for a 2 GB video: it returns
    /// one `Data` of the file's full length, so the caller both allocates it and
    /// cannot stop early. This keeps **one** AFC connection open for the whole
    /// file (opening one per 4 MB chunk would cost more than the transfer) and
    /// stops at end of file.
    ///
    /// Throwing out of `onChunk` propagates: that is how a cancelled transfer
    /// unwinds without the caller having to poll anything.
    func afcStreamFile(
        path: String,
        chunkSize: Int,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64

    // MARK: - App containers (house_arrest)
    //
    // The same AFC client, handed over by house_arrest instead of opened
    // directly — which is how an `afc://<udid>:<n>/` URL in a desktop file
    // manager reaches an app's data: the numbers in that URL scheme select the
    // service, and the container services are house_arrest.  `vend_container`
    // is the whole data container (Documents, Library, tmp), `vend_documents`
    // only Documents — the two roots macOS Finder offers for an app.
    //
    // Read *and* write, same primitives as the Media calls above, so a caller
    // can treat both locations alike.
    func installedApps() async throws -> [DeviceAppInfo]
    func afcContainerList(bundleId: String, path: String) async throws -> [AfcFsEntry]
    func afcContainerInfo(bundleId: String, path: String) async throws -> AfcFsEntry
    func afcContainerRead(bundleId: String, path: String) async throws -> Data
    func afcContainerWrite(bundleId: String, path: String, data: Data) async throws
    func afcContainerMakeDirectory(bundleId: String, path: String) async throws
    func afcContainerRename(bundleId: String, path: String, to newPath: String) async throws
    func afcContainerDelete(bundleId: String, path: String) async throws
}

/// One installed app, as `installation_proxy` reports it.
public struct DeviceAppInfo: Sendable, Hashable, Identifiable {
    public let bundleID: String
    /// `CFBundleDisplayName`, else `CFBundleName`, else the bundle ID.
    public let name: String
    /// `CFBundleShortVersionString`, when the app has one.
    public let version: String
    /// The data container path on the device, e.g.
    /// `/var/mobile/Containers/Data/Application/<UUID>`.  Shown next to the name
    /// because it is the thing a person recognises from a desktop file manager.
    public let containerPath: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String, version: String, containerPath: String) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.containerPath = containerPath
    }
}

/// One row of an AFC directory listing, with the metadata
/// `afc_get_file_info` reports for it.
public struct AfcFsEntry: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    /// `nil` when the device sent a timestamp this side cannot make sense of.
    public let modified: Date?
    /// Set for symlinks: where the link points, as the device reports it.
    public let linkTarget: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date?,
        linkTarget: String?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.linkTarget = linkTarget
    }
}

/// What `afc_get_device_info` reports about the AFC volume.
public struct AfcFsVolumeInfo: Sendable {
    public let model: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let blockSize: Int64

    public init(model: String, totalBytes: Int64, freeBytes: Int64, blockSize: Int64) {
        self.model = model
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.blockSize = blockSize
    }
}

public extension DeviceGatewayAPI {
    // Active service port for the currently loaded pairing file mode
    var servicePort: UInt16 {
        getPort(for: pairingFileType)
    }

    // MARK: - AFC filesystem defaults
    //
    // Only `IdeviceGateway` implements these: the app's singleton always builds
    // its gateway from it (`Minimuxer.createInstance` maps *both* backend cases
    // to `IdeviceGateway.shared`).  `LibimobiledeviceGateway` also conforms to
    // this protocol and stays usable for the other services, so the defaults
    // throw instead of the protocol growing a second implementation nobody
    // calls.
    func afcVolumeInfo() async throws -> AfcFsVolumeInfo {
        throw AfcFsUnsupportedError()
    }

    func afcList(path: String) async throws -> [AfcFsEntry] {
        throw AfcFsUnsupportedError()
    }

    func afcEntryInfo(path: String) async throws -> AfcFsEntry {
        throw AfcFsUnsupportedError()
    }

    func afcRead(path: String) async throws -> Data {
        throw AfcFsUnsupportedError()
    }

    func afcWrite(path: String, data: Data) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcMakeDirectory(path: String) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcRename(path: String, to newPath: String) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcDelete(path: String) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcStreamFile(
        path: String,
        chunkSize: Int,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64 {
        throw AfcFsUnsupportedError()
    }

    func installedApps() async throws -> [DeviceAppInfo] {
        throw AfcFsUnsupportedError()
    }

    func afcContainerList(bundleId: String, path: String) async throws -> [AfcFsEntry] {
        throw AfcFsUnsupportedError()
    }

    func afcContainerInfo(bundleId: String, path: String) async throws -> AfcFsEntry {
        throw AfcFsUnsupportedError()
    }

    func afcContainerRead(bundleId: String, path: String) async throws -> Data {
        throw AfcFsUnsupportedError()
    }

    func afcContainerWrite(bundleId: String, path: String, data: Data) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcContainerMakeDirectory(bundleId: String, path: String) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcContainerRename(bundleId: String, path: String, to newPath: String) async throws {
        throw AfcFsUnsupportedError()
    }

    func afcContainerDelete(bundleId: String, path: String) async throws {
        throw AfcFsUnsupportedError()
    }
}

/// Thrown by the default `afcFs*` implementations above.
public struct AfcFsUnsupportedError: LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "This gateway backend does not implement the AFC filesystem (com.apple.afc) service."
    }
}
