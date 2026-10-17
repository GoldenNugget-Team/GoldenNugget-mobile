import Foundation

/// The small local history of apply/reset operations — the port of
/// `src/controllers/apply_history.py`, stored where the desktop stores it
/// (`AppDataLocation/GoldenNugget/History/operations.json`) so a shared
/// container reads the same file shape: `Documents/GoldenNugget/History/operations.json`.
///
/// The desktop never lets recording change the operation result — every failure
/// is swallowed (`record_operation`'s whole body sits in `try/except`), and the
/// same holds here: `record` returns nothing and never throws.
enum ApplyHistory {
    /// `MAX_ENTRIES` (`apply_history.py:9`).
    static let maxEntries = 30

    /// One bounded record, in the reference's own field set
    /// (`apply_history.py:30`): `timestamp` (local ISO-8601 with seconds),
    /// `mode` ("apply" or "reset"), `success`, `error`, plus the device
    /// descriptors the desktop's manager had available.
    struct Record: Codable {
        let timestamp: String
        let mode: String
        let success: Bool
        let error: String
        let device: String
        let model: String
        let ios: String
        let udid: String

        /// `datetime.now().astimezone().isoformat(timespec="seconds")`, which is
        /// local time with the offset (`"2026-10-12T14:05:33+03:00"`).
        static func now() -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                       .withColonSeparatorInTime]
            formatter.timeZone = .current
            return formatter.string(from: Date())
        }
    }

    /// `load_history` — the file's list of records, or `[]` when the file is
    /// missing, unreadable or not a list (`apply_history.py:18`).
    static func load() -> [Record] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// `record_operation` — append one bounded record atomically
    /// (`apply_history.py:27`).
    ///
    /// Mirrors the reference field for field: `mode` is kept verbatim ("apply"
    /// or "reset"), the record is appended to whatever is on disk, trimmed to
    /// the last `maxEntries`, and swapped into place with `os.replace`'s Swift
    /// equivalent.  Any failure is swallowed.
    static func record(mode: String, success: Bool, error: String = "",
                       device: String = "", model: String = "", ios: String = "",
                       udid: String = "") {
        let item = Record(timestamp: Record.now(),
                          mode: mode,
                          success: success,
                          error: error,
                          device: device,
                          model: model,
                          ios: ios,
                          udid: udid)
        var records = load() + [item]
        if records.count > maxEntries {
            records = Array(records.suffix(maxEntries))
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            let temporary = directory.appendingPathComponent("operations.json.tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            // Never throw: recording must not affect the operation result.
        }
    }

    /// `clear_history` — unlink the file, tolerating its absence
    /// (`apply_history.py:52`).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// `_path` (`apply_history.py:12`): the file this app owns inside
    /// `<Documents>/GoldenNugget/History/`.
    static var fileURL: URL {
        fileURLOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoldenNugget", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("operations.json")
    }

    /// Test seam: point the store somewhere else (the regression harness keeps
    /// the real Documents folder untouched).  Never set in the app.
    static var fileURLOverride: URL?
}
