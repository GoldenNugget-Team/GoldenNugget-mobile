import Foundation
import UniformTypeIdentifiers

/// The pairing record's format facts, and the one path a record enters the app
/// by.
///
/// This used to be four `static` members of `GoldenNuggetView`, and the setup
/// guide needs every one of them: it is a second way in, and a second copy of
/// "what counts as a pairing record" is a second chance to accept a file the
/// restore path will later refuse — the exact shape of the bug that made pairing
/// files appear and disappear (`loadPairingFile`'s history, below). None of it is
/// view state, so none of it belongs on a view.
enum PairingRecord {
    /// Extensions accepted by the picker and the `onOpenURL` handler.  **One
    /// list**: the picker built its array from these names and the URL handler
    /// hard-coded the same three again, so adding a fourth would have worked in
    /// one path and silently not in the other.
    static let extensions = ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"]

    static let types: [UTType] = extensions.compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    static func hasKnownExtension(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// The two `UserDefaults` keys the record and the reset flag live under.
    ///
    /// Spelled out here because a first-run screen and the home page both write
    /// them: `PairingFile` is set on import and cleared by a reset, and
    /// `PairingFileAutoImportDisabled` is the user's "do not use that record
    /// again" answer. Two `@AppStorage` declarations with these literals spelled
    /// slightly differently is how a reset stops sticking.
    enum Key {
        static let stored = "PairingFile"
        static let autoImportDisabled = "PairingFileAutoImportDisabled"
    }

    // MARK: - Shape

    /// Whether the app is willing to hand these bytes to minimuxer.
    ///
    /// Deliberately **format-agnostic**: the pairing format belongs to the
    /// library, not to this file.  A pairing record is one of two shapes —
    /// `.rppairing` (`identifier`, `private_key`, `public_key`; iOS 17+
    /// RemotePairing) or `.lockdown` (`UDID`, `SystemBUID`, `EscrowBag`, the
    /// certificates) — and **only the second carries a `UDID`**.
    ///
    /// A top-level `UDID` was required here once, which rejected **every** file a
    /// user could import on an iOS 17+ device: the import accepted it, the device
    /// paired fine, and the restore path then refused the very same bytes on the
    /// next launch and reported "no pairing record".  Exactly backwards, and
    /// invisible.  So this asserts only what it can assert alone — non-empty, a
    /// plist, a non-empty top-level dictionary.  Whether it is a *recognised*
    /// record is `PairingFileParser`'s answer, and the library gives it, naming
    /// the missing keys, from `start()`.  Do not reintroduce a key list here.
    static func usable(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return false }
        return !dict.isEmpty
    }

    /// The record's top-level keys, for import and start diagnostics.
    ///
    /// Keys only — deliberately no judgement about which of them *should* be
    /// there, for the reason `usable(_:)` gives.
    static func topLevelKeys(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        guard let dict = obj as? [String: Any] else { return nil }
        return Array(dict.keys)
    }

    /// What a candidate record actually contains, for the log line — a rejected
    /// record has to be diagnosable from the log alone, because the alternative
    /// on a phone is "minimuxer did not start" with nothing to go on.
    static func sourceLabel(_ raw: String) -> String {
        guard let keys = topLevelKeys(raw) else { return "not a parseable plist" }
        return keys.isEmpty ? "(no keys)" : "keys: \(keys.sorted().joined(separator: ", "))"
    }

    /// The record at the canonical path, if it is one this app would hand to
    /// minimuxer.
    ///
    /// This is what "is a record already in place?" means for a screen that does
    /// not own the import: `Documents/pairingfile.mobiledevicepairing`, judged by
    /// the same rule the home page's restore path judges it by. A file that
    /// exists but is unusable answers `false` here on purpose — the setup guide
    /// must not tick its pairing step over a record the app cannot use.
    static func onDisk() -> String? {
        guard let raw = try? String(contentsOf: AppPaths.pairingFile, encoding: .utf8) else { return nil }
        let record = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return usable(record) ? record : nil
    }

    // MARK: - Acceptance

    /// Import a record the user picked: **validate → write → read back**.
    ///
    /// Each step is here for a way the previous version failed.  It used to read
    /// the file, write it out, and set the app's state from whatever it happened
    /// to hold — without looking at the content and without checking that the
    /// write landed.  Nothing threw for content the *restore* path then refused,
    /// so a record that came back empty or truncated (a document-picker URL that
    /// is an iCloud/other-app placeholder read before it was materialised is the
    /// common one) was written as a 0-byte file, reported as a success — the alert
    /// only fires on a thrown error, and `write` does not throw for empty
    /// content — and read back as "no pairing record" on the next launch.
    ///
    /// What it validates **with** matters as much as that it validates: see
    /// `usable(_:)`.  Checking the format's rules here is what turned a working
    /// import into a rejected one, so this defers the format verdict to minimuxer.
    ///
    /// - Returns: the **normalised** record — what the restore path compares
    ///   against on the way back in, and what minimuxer is handed, so keeping the
    ///   untrimmed original would only ever differ by whitespace the restore path
    ///   silently strips.
    @discardableResult
    static func accept(contentsOf url: URL) throws -> String {
        // Document-picker URLs are security-scoped: reading one without
        // `startAccessingSecurityScopedResource` fails with "you don't have
        // permission to view it".
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Read bytes, not a string: an empty or missing file has to be
        // distinguishable from a decode failure, and both have to be reported
        // in words rather than as a bare Cocoa error.  minimuxer's parser takes
        // text, so anything that is not UTF-8 (a binary plist, say) is refused
        // here instead of being silently mangled on the way to disk.
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw GoldenNuggetError("\(url.lastPathComponent) is not UTF-8 text "
                + "(\(data.count) bytes). A pairing file has to be an XML plist, which is what "
                + "minimuxer parses — a binary plist has to be converted first.")
        }

        let record = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isEmpty else {
            throw GoldenNuggetError("\(url.lastPathComponent) is empty — nothing to import. "
                + "If it lives in iCloud Drive, open it in Files once so it is downloaded, "
                + "then import it again.")
        }
        guard usable(record) else {
            throw GoldenNuggetError("\(url.lastPathComponent) is not a property list "
                + "(\(sourceLabel(record))). A pairing file has to be an XML plist — "
                + "minimuxer parses nothing else.")
        }

        let dest = AppPaths.pairingFile
        try record.write(to: dest, atomically: true, encoding: .utf8)

        // Read it back.  A write that did not land is indistinguishable from one
        // that did until the next launch reads it — which is exactly the delay
        // that made this look like data loss instead of a failed import.
        let written = try String(contentsOf: dest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard written == record else {
            throw GoldenNuggetError("The pairing file did not survive being written to "
                + "\(dest.lastPathComponent): \(written.count) of \(record.count) bytes came "
                + "back. Import it again.")
        }
        return record
    }

    /// Adopt a record that is **already** at the canonical path, without rewriting
    /// bytes that are in place.
    ///
    /// The wireless-pairing library writes its record straight to
    /// `AppPaths.pairingFile` (`WirelessPairing`), so the setup guide has nothing
    /// to import — only something to notice and to record in `UserDefaults` the
    /// way an import would have. Reading it back through `usable(_:)` keeps the
    /// rule single: a record the library produced that this app cannot parse is
    /// rejected with the same wording a picked file gets, instead of being trusted
    /// because it came from inside the app.
    @discardableResult
    static func adoptFromDisk() throws -> String {
        guard let record = onDisk() else {
            throw GoldenNuggetError("The pairing service finished but no usable record is at "
                + "\(AppPaths.pairingFile.lastPathComponent) (\(sourceLabelOnDisk())). "
                + "Import a pairing file instead.")
        }
        persist(record)
        return record
    }

    /// Remember an accepted record where the app looks for it on the next launch,
    /// and answer any earlier "reset pairing file" with "the user imported a new
    /// record".
    ///
    /// The flag is cleared here for the reason it is cleared in the home page's
    /// import: leaving it up would adopt the record and work *now*, then have
    /// every later launch skip the automatic load and come up "unpaired" — the
    /// failure the reset fix was about, pointing the other way.
    static func persist(_ record: String) {
        let defaults = UserDefaults.standard
        defaults.set(record, forKey: Key.stored)
        defaults.set(false, forKey: Key.autoImportDisabled)
    }

    /// The canonical file's contents, for an error message. Never throws: this
    /// only ever decorates a failure.
    private static func sourceLabelOnDisk() -> String {
        guard let raw = try? String(contentsOf: AppPaths.pairingFile, encoding: .utf8) else {
            return "no file"
        }
        return sourceLabel(raw)
    }
}