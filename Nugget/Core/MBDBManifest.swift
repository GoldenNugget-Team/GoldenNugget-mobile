import CryptoKit
import Foundation

/// The iOS 26 restore manifest: `Manifest.mbdb`, the legacy binary MBDB format.
///
/// GoldenNugget branches on one field, `Backup.manifest_ios27`
/// (`src/restore/backup.py:113`, set at `restore.py:1065-1074`):
///
///     manifest_ios27 = Version(product_version) >= Version("27.0")
///
/// iOS 26 and below speak the legacy format; iOS 27+ uses the modern sqlite
/// `Manifest.db`. This file is the iOS 26 half. Its container is flat: payloads
/// sit in the backup root named by their fileID, and the device reads the row
/// list itself and asks for each payload by that name.
///
/// The record layout is `src/restore/mbdb.py:26-65`, verbatim, and it is fixed —
/// there is no negotiation and no optional tail, so the field order and widths
/// below are the format:
///
///     u16be len + bytes   domain
///     u16be len + bytes   filename
///     u16be len + bytes   link
///     u16be len + bytes   hash          (raw SHA-1 of the contents, 20 bytes)
///     u16be len + bytes   key
///     u16be               mode          (S_IFREG / S_IFDIR already OR'd in)
///     u64be               inode
///     u32be               user_id
///     u32be               group_id
///     u32be               mtime
///     u32be               atime
///     u32be               ctime
///     u64be               size
///     u8                  flags
///     u8                  propertyCount
///       repeat: u16be len + name, u16be len + value
///
/// File header is `b"mbdb" + b"\x05\x00"`. Note what is NOT in a record: there
/// is no ProtectionClass field in this format at all (that lives in the sqlite
/// `file` blob on iOS 27+), and no extended attributes — the properties list
/// carries plain name/value pairs and actool's carriers use none.
enum MBDBManifest {
    /// `S_IFREG`, from `src/utils/file_to_restore.py`'s `_FileMode`.
    static let sIFREG: UInt16 = 0o100000
    /// `S_IFDIR`, same source.
    static let sIFDIR: UInt16 = 0o040000
    /// `backup.DEFAULT` (`backup.py:15`): rwxr-xr-x. No tweak in the reference
    /// ever sets `FileToRestore.mode`, so this is what every row carries.
    static let defaultMode: UInt16 = 0o755
    /// `ConcreteFile.flags` default is 4 (`backup.py:34`) and a `Directory`
    /// hardcodes 4 as well (`backup.py:85`) — the MBDB flags byte is not the
    /// sqlite `flags` column, where 1 is a file and 2 a directory.
    static let rowFlags: UInt8 = 4

    struct Row {
        let domain: String
        let path: String
        let isDirectory: Bool
        let owner: UInt32
        let group: UInt32
        let hash: Data
        let size: UInt64
        var inode: UInt64 = 0
    }

    /// Serialise rows into a `Manifest.mbdb` payload.
    ///
    /// Directory rows get `inode = 0` and an empty hash because the reference
    /// does exactly that (`backup.py:78-95`); file rows get a random 8-byte
    /// inode (`backup.py:50`) and the SHA-1 of their contents.
    static func encode(_ rows: [Row], now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        var out = Data()
        out.append(contentsOf: Array("mbdb".utf8))
        out.append(contentsOf: [0x05, 0x00])
        for row in rows {
            let mode = (defaultMode | (row.isDirectory ? sIFDIR : sIFREG))
            let inode: UInt64 = row.isDirectory
                ? 0
                : (row.inode != 0 ? row.inode : randomInode())
            appendField(&out, row.domain)
            appendField(&out, row.path)
            appendField(&out, "")            // link
            appendField(&out, row.isDirectory ? Data() : row.hash)
            appendField(&out, Data())        // key
            out.appendBE(mode)
            out.appendBE(inode)
            out.appendBE(row.owner)
            out.appendBE(row.group)
            out.appendBE(now)
            out.appendBE(now)
            out.appendBE(now)
            out.appendBE(row.size)
            out.append(MBDBManifest.rowFlags)
            out.append(0)                   // property count
        }
        return out
    }

    /// The fileID a payload is stored under in the iOS 26 flat layout — the same
    /// `sha1("<domain>-<relativePath>")` convention the sqlite path uses, so the
    /// device's request for a file resolves to the bytes we wrote.
    static func fileID(domain: String, relativePath: String) -> String {
        ManifestStore.sha1Hex("\(domain)-\(relativePath)")
    }

    static func hash(_ contents: Data) -> Data {
        Data(Insecure.SHA1.hash(data: contents))
    }

    // MARK: - Rows for a set of payloads

    /// The rows a set of payloads needs: each payload's file, plus the domain
    /// root and every directory component above it.
    ///
    /// Mirrors `concat_regular_file` (`restore.py:43-85`), which emits a
    /// `Directory` for the domain root when the domain changes and one per path
    /// component not already covered. The device's rename step needs those
    /// directory rows to exist: dropping them makes the agent fail with
    /// `renameatx` ENOENT — the reason `clean_backup_for_restore` keeps
    /// `flags == 2` rows even with no payload.
    static func rows(for payloads: [TweakPayload]) throws -> [Row] {
        var rows: [Row] = []
        var seen: Set<String> = []

        func addDirectory(domain: String, path: String) {
            let key = "\(domain)/\(path)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            rows.append(Row(domain: domain, path: path, isDirectory: true,
                            owner: 0, group: 0, hash: Data(), size: 0))
        }

        for payload in payloads {
            addDirectory(domain: payload.domain, path: "")
            var accumulated = ""
            for component in payload.relativePath.split(separator: "/").dropLast() {
                accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
                addDirectory(domain: payload.domain, path: accumulated)
            }
        }

        for payload in payloads {
            let contents = try payload.bytes()
            rows.append(Row(domain: payload.domain, path: payload.relativePath,
                            isDirectory: false,
                            owner: rowOwner(for: payload.domain),
                            group: rowOwner(for: payload.domain),
                            hash: hash(contents), size: UInt64(contents.count)))
        }
        return rows
    }

    /// Owner/group for a row. The reference threads `owner=501, group=501`
    /// through `concat_file` (`device_manager.py:371-379`) and only the
    /// deliberately root-owned tweak, the launchd `disabled.plist`, uses 0
    /// (`device_manager.py:1188-1193`).
    private static func rowOwner(for domain: String) -> UInt32 {
        domain.hasPrefix("DatabaseDomain") ? 0 : 501
    }

    // MARK: - Byte helpers

    private static func appendField(_ data: inout Data, _ value: Data) {
        data.appendBE(UInt16(value.count))
        data.append(value)
    }

    private static func appendField(_ data: inout Data, _ value: String) {
        appendField(&data, Data(value.utf8))
    }

    private static func randomInode() -> UInt64 {
        var out: UInt64 = 0
        for byte in (0..<8).map({ _ in UInt8.random(in: 0...255) }) {
            out = (out << 8) | UInt64(byte)
        }
        return out
    }
}

// MARK: - Big-endian appends

/// MBDB is big-endian throughout, unlike the BOM container's internals.
extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
