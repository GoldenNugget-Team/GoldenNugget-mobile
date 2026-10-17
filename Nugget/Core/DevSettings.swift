import Foundation
import Minimuxer

/// The Development-mode switches, and the one gate that turns them off.
///
/// Every switch here changes what a *run* does to a real device, so nothing reads
/// the stored values directly. `applyTweaks` consults `effective`, which ANDs each
/// behavioural switch with the master toggle: a stored `forcePartialRestore` of
/// `true` with the master off reads as `false`. That is the property that matters —
/// flipping the master cannot leave the next run in a state the UI is no longer
/// showing, and there is no way to be "in development mode" for one run and quietly
/// stay that way for the next.
///
/// Plain `UserDefaults` rather than `@AppStorage`, because `applyTweaks` is not on
/// the main actor and can run for minutes, and `UserDefaults` is safe to read from
/// any thread. The settings page binds through `Binding(get:set:)` over these same
/// accessors, so the page and the run still have exactly one source of truth.
enum DevSettings {
    /// Namespaced with a `Dev.` prefix, the way `AfcMedia.deleteOriginals` is, so
    /// the reset action can name the whole group without touching anyone else's key.
    ///
    /// Internal, not private: the settings page declares its `@AppStorage` bindings
    /// over these same strings so a toggle is reactive in the view while the engine
    /// keeps reading plain `UserDefaults` off the main actor. Spelling the key twice
    /// is how a switch ends up drawn in one state and obeyed in another.
    enum Key {
        static let enabled = "Dev.Enabled"
        static let forcePartialRestore = "Dev.ForcePartialRestore"
        static let verboseLog = "Dev.VerboseLog"
        static let skipAfcMedia = "Dev.SkipAfcMedia"
    }

    /// The `UserDefaults` keys in declaration order, for the reset action.
    static let allKeys = [Key.forcePartialRestore, Key.verboseLog, Key.skipAfcMedia]

    private static var defaults: UserDefaults { .standard }

    // MARK: - Stored switches

    /// The master gate. Off by default: everything below it has a "what did it do
    /// to my device" failure mode, so none of it is shown until it is asked for.
    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Take the iOS 26 branch — build a Partial Restore from nothing — even on a
    /// device that reports iOS 27+.
    ///
    /// This is the counterpart of the reference's `GOLDENNUGGET_NO_PROTECTIVE_BACKUP`,
    /// and it is the switch to reach for when the 27 path misbehaves on a beta
    /// build and the open question is *which* branch is at fault. It is a diagnostic,
    /// not a fix: on a real iOS 27 device this branch synthesises a legacy MBDB
    /// manifest, and `restored` rejects domains it cannot resolve
    /// ("Failed to prepare INSERT for ManagedPreferencesDomain"), because only a
    /// pulled manifest carries the device's own domain registration.
    static var forcePartialRestore: Bool {
        get { defaults.bool(forKey: Key.forcePartialRestore) }
        set { defaults.set(newValue, forKey: Key.forcePartialRestore) }
    }

    /// The vendor's `verboseLog` lines. They are not in the app log a bug report
    /// usually attaches — they are in `minimuxer.log`, alongside the protocol —
    /// so this is the switch that decides whether the protocol half is recorded at
    /// all.
    ///
    /// Defaults to on, which is the vendor's own default, so entering development
    /// mode and touching nothing else does not change what gets recorded.
    static var verboseLog: Bool {
        get { defaults.object(forKey: Key.verboseLog) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.verboseLog) }
    }

    /// Skip the AFC media pull that a run performs between the backup and the prune.
    /// With a full camera roll that stage is minutes of the run and the stage a Stop
    /// most often lands in, so this is how a run gets timed without it.
    /// The reference spells it `GOLDENNUGGET_NO_AFC_MEDIA`.
    static var skipAfcMedia: Bool {
        get { defaults.bool(forKey: Key.skipAfcMedia) }
        set { defaults.set(newValue, forKey: Key.skipAfcMedia) }
    }

    // MARK: - What a run obeys

    /// The resolved settings for one run. This is the only thing the engine is
    /// allowed to read.
    struct Effective: Equatable {
        var forcePartialRestore = false
        var verboseLog = true
        var skipAfcMedia = false
    }

    static var effective: Effective {
        Effective(forcePartialRestore: enabled && forcePartialRestore,
                  // Logging is the one switch that is *restored* rather than gated:
                  // see `applyLoggingPreference`.
                  verboseLog: enabled ? verboseLog : true,
                  skipAfcMedia: enabled && skipAfcMedia)
    }

    /// Push the logging switch into the vendor.
    ///
    /// With development mode off this restores the vendor default instead of leaving
    /// whatever a dev run last set, so the two directions are symmetric and "off"
    /// means "what the app did about logging before this page existed".
    static func applyLoggingPreference() {
        MinimuxerLogging.setLogging(effective.verboseLog)
    }

    /// Back to shipping defaults for the individual switches. Removes the keys
    /// rather than writing `false` into them, so each accessor lands back on its own
    /// default — which is how `verboseLog` returns to *on* instead of the `false` a
    /// literal assignment would leave it at.
    ///
    /// Deliberately leaves `enabled` alone: turning development mode off is a
    /// separate, visible decision with its own control, and a reset that quietly did
    /// it would leave the page looking like it had done something it did not.
    static func resetSwitches() {
        for key in allKeys { defaults.removeObject(forKey: key) }
    }
}
