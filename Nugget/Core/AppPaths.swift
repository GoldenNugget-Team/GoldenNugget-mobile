import Foundation

/// Every on-device path this app owns, in one place.
///
/// These used to be spelled out inline at nine call sites —
/// `FileManager.default.urls(for: .documentDirectory, …)` appeared in the
/// engine, the diagnostics writer, the two log sinks and the view — which made
/// "which file is actually being read?" a grep exercise and left two spellings
/// of the same directory (`URL.documents` and the inline form) side by side.
enum AppPaths {
    /// `<Documents>/goldennugget.log` — the app-side log sink.
    static let appLog = URL.documents.appendingPathComponent("goldennugget.log")

    /// `<Documents>/minimuxer.log` — the Rust `tracing` sink installed by
    /// `enableRustFileLogging()`.
    static let rustLog = URL.documents.appendingPathComponent("minimuxer.log")

    /// `<Documents>/diagnostics.txt` — the last dumped diagnostics block, so it
    /// can be shared as a FILE instead of hand-selecting text in the log list.
    static let diagnostics = URL.documents.appendingPathComponent("diagnostics.txt")

    /// `<Documents>/pairingfile.mobiledevicepairing` — the imported pairing file.
    /// minimuxer reads it from Documents too, so this is the canonical location.
    static let pairingFile = URL.documents.appendingPathComponent("pairingfile.mobiledevicepairing")

    /// `<Documents>/<udid>/` — the full protective backup pulled from the device.
    /// The AFC media store, inside the container.
    ///
    /// Its own store and its own manifest rather than the backup's
    /// `MediaDomain` rows: a protective prune keeps only the payloads it pulled
    /// itself, so anything parked here would be dropped on the next apply.
    static let mediaStore = URL.documents.appendingPathComponent("Media", conformingTo: .data)

    static func fullBackupRoot(udid: String) -> URL {
        URL.documents.appendingPathComponent(udid, conformingTo: .data)
    }

    /// `<Documents>/Baseline/<udid>/` — the retained pull the next run diffs
    /// against.
    ///
    /// `Manifest.db` here is the pristine, device-produced manifest kept aside
    /// **before** the prune mutates the working copy in place, and `baseline.json`
    /// is the record that authorises seeding it (`BackupBaseline`). Its own root
    /// rather than the working tree's, because the two copies have different jobs:
    /// the pruned one is what a restore needs, the pristine one is what the device
    /// needs, and keeping them apart is what makes reuse possible without
    /// weakening the prune.
    static func baselineDir(udid: String) -> URL {
        URL.documents.appendingPathComponent("Baseline", conformingTo: .data)
            .appendingPathComponent(udid, conformingTo: .data)
    }

    /// `<Documents>/PosterBoardFetch/` — the scratch root of a PosterBoard
    /// database fetch.
    ///
    /// Its own root rather than the protective backup's, which is re-created on
    /// every apply: a PosterBoard apply runs both exchanges, and the second one
    /// must not wipe the first one's backup out from under the injection that is
    /// about to read it.
    static let posterBoardFetchRoot = URL.documents
        .appendingPathComponent("PosterBoardFetch", conformingTo: .data)

    /// `<Documents>/Templates/Work/` — where a `.batter` template's tree is
    /// unpacked before its options rewrite it and the result becomes payloads.
    ///
    /// Separate from `PosterBoard.workDirectory` because a PosterBoard-domain
    /// template is unpacked **into** that one (so the wallpaper walk finds it),
    /// and mixing the two would have a template's own files picked up as a pack.
    static let templatesWorkDirectory = URL.documents
        .appendingPathComponent("Templates/Work", conformingTo: .data)

    /// `<Documents>/TemplateChoices/` — where a `replace` option's picked file is
    /// kept until the apply reads it.
    ///
    /// Its own directory because the files are transient by nature: a template's
    /// chosen image belongs to one template and one apply, and keeping the ones
    /// a user tried and abandoned would leave hundreds of megabytes behind with
    /// nothing pointing at them.  It is emptied at the start of every apply,
    /// which is also why a chosen file does not survive a relaunch.
    static let templateChoices = URL.documents
        .appendingPathComponent("TemplateChoices", conformingTo: .data)

    /// `<backupRoot>/<udid>/` — the per-device directory inside a backup root.
    static func deviceDir(backupRoot: URL, udid: String) -> URL {
        backupRoot.appendingPathComponent(udid)
    }
}
