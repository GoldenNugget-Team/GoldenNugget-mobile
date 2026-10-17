import Foundation

/// A page that can be reset on the device, mirroring the entries
/// `src/utils/pages.py:get_resettable_pages` hands to the reference's reset
/// dialog.
///
/// The reference builds that list as `[StatusBar, Springboard, InternalOptions,
/// Daemons]` and drops `StatusBar` on iOS 27, where the old Speakeasy
/// `FeatureFlags` write is gone. This port keeps it on every version because it
/// *can* reset the status bar on iOS 27: the same `StatusBarMechanism` that
/// delivers the tweak delivers the reset, and its archive branch is a supported
/// writer here (`StatusBarArchive`), unlike the reference's dialog. All four map
/// one-to-one, in the reference's order.
///
/// The name is `Page` in the reference and carries the same meaning — a
/// *feature area*, not a navigation destination. `AppDestination` is this app's
/// navigation enum and would be the wrong thing to reuse: it holds Daemons but
/// not Springboard or Internal, which are sections of the Tweaks page.
enum ResetPage: String, CaseIterable, Identifiable, Sendable {
    case statusBar
    case springboard
    case internalOptions
    case daemons

    var id: String { rawValue }

    /// `Page.getPageName()` — "Internal", not "Internal Options", because that
    /// is the string the reference's checkbox carries.
    var title: String {
        switch self {
        case .statusBar: return "Status Bar"
        case .springboard: return "Springboard"
        case .internalOptions: return "Internal"
        case .daemons: return "Daemons"
        }
    }

    /// The files this page's reset writes, in the order the reference appends
    /// them, for the sheet's "what this will touch" line and the run log.
    ///
    /// `statusBar` names the iOS 27 archive location; on iOS 26 the run writes
    /// the classic `/Library/SpringBoard/statusBarOverrides` instead, which has
    /// no `FileLocation` case in the reference and so is the one path spelled
    /// out in `plan` rather than looked up from this list.
    ///
    /// `internalOptions` carries seven files while the catalog's Internal
    /// section only uses six of them: the reference nulls
    /// `.GlobalPreferences.plist` in HomeDomain as well, and no tweak in this
    /// port writes that copy. It is kept because the reference clears it, and
    /// dropping it would make this a *different* reset rather than a port of
    /// the same one.
    var locations: [TweakFileLocation] {
        switch self {
        case .statusBar:
            return [.statusBarOverridesArchive]
        case .springboard:
            return [.springboard, .uikit]
        case .internalOptions:
            return [.globalPreferences, .globalPreferencesHomeDomain, .appStore,
                    .backboardd, .coreMotion, .pasteboard, .notes]
        case .daemons:
            return [.disabledDaemons]
        }
    }
}

/// Builds the file set a page reset restores.
///
/// A port of `device_manager._reset_tweaks`
/// (`src/devicemanagement/device_manager.py:1106-1245`): no psysbackup capture,
/// no reading of the device's current values — the run writes a fixed set of
/// files that put the named pages back to stock.
///
/// ## No psysbackup, on either branch
///
/// The reference's iOS 27 branch captures the device's original plists with
/// psysbackup first and restores *those*, which is what makes its reset a real
/// "put back what was there" rather than "write the same values again". This
/// port has no capture and no materialiser, so it does what the reference
/// itself does when its capture is unavailable — its `plistlib.dumps({})`
/// fallback, which is a documented, deliberate path rather than a degraded one:
///
/// > Restore a valid empty plist instead of a zero-byte file: on iOS 26.2+ a
/// > truncated plist (e.g. an empty com.apple.springboard.plist) makes
/// > SpringBoard crash at boot, which sends the device into a boot loop. An
/// > empty dict parses fine and makes the system fall back to its default
/// > values.
///
/// So the two branches differ in exactly one thing, and it is the nulled
/// file's *bytes*:
///
/// | branch | nulled file written as | why |
/// |---|---|---|
/// | iOS 26 and below | 0 bytes | the original Nugget's behaviour, and a daemon reading an empty file falls back to its defaults |
/// | iOS 27+ | `plistlib.dumps({})` — a valid, empty XML plist | a 0-byte plist is a *truncated* plist there, and that is the boot loop above |
///
/// The daemons file is the stock dict on both, and neither branch reads
/// anything back from the device first.
///
/// ## The two kinds of file
///
/// * **Nulled** — 0 bytes or an empty dict, per the table above.
///   `NullifyFileTweak`'s trick, which this port already ships for the
///   ScreenTime daemon: the daemon that reads the file falls back to its
///   defaults.
/// * **Daemons** — the *stock* `disabled.plist`, a six-key dict. Not empty and
///   not "the tweaks off": launchd's own file on a stock device disables five
///   of these, so an empty dict would leave `otpaird`, `bootpd`, `dhcp6d`,
///   `magicswitchd.companion` and `relevanced` *enabled* where the factory
///   device has them off, and a reset would be a way to break pairing.
/// * **Status bar** — a fresh, all-default `StatusBarOverrides` written through
///   the same `StatusBarMechanism` the apply uses: the classic struct on iOS 26,
///   a no-cellular `StatusBarOverrides.archive` on iOS 27+. Neither is nulled —
///   an empty file is not a valid override struct, so "off" has to be spelled
///   out as a zeroed one.
///
/// The owner/group the reference passes for that file (`owner=0, group=0`) need
/// no special case here: `/var/db/…` maps to `DatabaseDomain`, whose
/// `TweakRowProfile` is measured at `0/0`.
enum TweakReset {
    /// What one file of the reset gets written as. Carried rather than derived
    /// from `contents.count`, because the iOS 27 variant is 43 bytes of XML and
    /// the log must not describe that as "not nulled".
    enum Kind: String, Sendable {
        /// 0 bytes, the iOS 26 null.
        case zeroBytes = "0 bytes"
        /// `plistlib.dumps({})`, the iOS 27 null.
        case emptyPlist = "empty plist"
        /// The stock six-key `disabled.plist`.
        case stockDaemons = "stock daemons"
        /// The zeroed classic status-bar struct (iOS 26).
        case statusBarClassic = "fresh status bar struct"
        /// The archive that decodes as "no overrides" (iOS 27+).
        case statusBarArchive = "reset status bar archive"
    }

    /// One file the reset will write.
    ///
    /// The path is a plain `String` rather than a `TweakFileLocation` because the
    /// classic status-bar reset writes `/Library/SpringBoard/statusBarOverrides`,
    /// which the reference spells out literally and the `FileLocation` enum has
    /// no case for. It is unique per target, which is what `Identifiable` needs.
    struct Target: Identifiable, Sendable {
        let path: String
        let contents: Data
        let kind: Kind
        var id: String { path }
    }

    struct Plan {
        let targets: [Target]
        let payloads: [TweakPayload]
        /// Locations with no backup-domain prefix — refused rather than injected
        /// as a row the device never produced (the compiler's rule, same reason).
        let skipped: [(label: String, reason: String)]
        /// Whether the two `skip_setup` files join this reset — the reference's
        /// `add_skip_setup` gate, reproduced exactly. See `plan(pages:ios27:)`.
        let skipSetupAllowed: Bool
    }

    /// `default_daemons` from `_reset_tweaks`, verbatim: the contents of
    /// `/var/db/com.apple.xpc.launchd/disabled.plist` on a stock device. `true`
    /// means launchd keeps the service disabled, which is how the factory
    /// device ships for all of these except the embedded FTP proxy, which is
    /// present but explicitly not disabled.
    static let stockDisabledDaemons: [String: Bool] = [
        "com.apple.magicswitchd.companion": true,
        "com.apple.security.otpaird": true,
        "com.apple.dhcp6d": true,
        "com.apple.bootpd": true,
        "com.apple.ftp-proxy-embedded": false,
        "com.apple.relevanced": true,
    ]

    /// Build the payload set for `pages`.
    ///
    /// - Parameter ios27: which null to write. Passed in rather than read from
    ///   the device here, because the caller has already read the version for
    ///   its own format fork and re-reading it would be a second handshake — and
    ///   two reads of the same fact is how the apply path once put a 27.0
    ///   device on the 26 branch.
    ///
    /// The reference restores two files whole inside the page loop — the status
    /// bar and the daemons file — and writes every nulled file only after the
    /// loop, so both restored-whole files precede the nulls in its list. That
    /// order is kept here because it is free and a diff against the reference
    /// should not have to explain a difference. The two `skip_setup` files are
    /// appended *after* all of these — the reference calls `add_skip_setup` after
    /// the null loop, so they are last in its file list too.
    static func plan(pages: Set<ResetPage>, ios27: Bool) -> Plan {
        // `ResetPage.allCases` order, not the caller's `Set` order: `Set` has
        // none, and a payload list that reorders between two runs of the same
        // request makes the log harder to read than it needs to be.
        let ordered = ResetPage.allCases.filter { pages.contains($0) }
        let nullContents = ios27 ? TweakCompiler.serialisePlist([:]) : Data()
        let nullKind: Kind = ios27 ? .emptyPlist : .zeroBytes

        var targets: [Target] = []
        var payloads: [TweakPayload] = []
        var skipped: [(label: String, reason: String)] = []

        func append(path: String, contents: Data, kind: Kind,
                    domain: String, relativePath: String) {
            targets.append(Target(path: path, contents: contents, kind: kind))
            payloads.append(TweakPayload(domain: domain, relativePath: relativePath,
                                         contents: contents))
        }

        // A location with no prefix rule in `TweakDomainMap` is refused rather
        // than injected as a row no device ever produced (the compiler's rule,
        // same reason).
        func addNulled(_ location: TweakFileLocation) {
            guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                skipped.append((location.rawValue,
                                "no backup-domain prefix matches this location"))
                return
            }
            append(path: location.rawValue, contents: nullContents, kind: nullKind,
                   domain: dest.domain, relativePath: dest.relativePath)
        }

        // The status bar is written whole, through the same `StatusBarMechanism`
        // the apply uses, so the reset and the tweak can never disagree on which
        // file this device reads.
        func addStatusBar() {
            let mechanism: StatusBarMechanism = ios27 ? .archive : .classic
            guard let built = try? mechanism.payload(for: StatusBarOverrides()) else {
                skipped.append((mechanism.restorePath, "could not build the reset status bar payload"))
                return
            }
            append(path: mechanism.restorePath, contents: built.data,
                   kind: ios27 ? .statusBarArchive : .statusBarClassic,
                   domain: mechanism.domain, relativePath: mechanism.restorePath)
        }

        // The two restored-whole files first, in reference page order.
        for page in ordered where page == .statusBar || page == .daemons {
            switch page {
            case .statusBar:
                addStatusBar()
            case .daemons:
                let location = TweakFileLocation.disabledDaemons
                guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                    skipped.append((location.rawValue,
                                    "no backup-domain prefix matches this location"))
                    continue
                }
                append(path: location.rawValue,
                       contents: TweakCompiler.serialisePlist(stockDisabledDaemons),
                       kind: .stockDaemons,
                       domain: dest.domain, relativePath: dest.relativePath)
            default:
                break
            }
        }
        // Every nulled file after the loop, in reference page order.
        for page in ordered where page != .statusBar && page != .daemons {
            for location in page.locations { addNulled(location) }
        }

        return Plan(targets: targets, payloads: payloads, skipped: skipped,
                    skipSetupAllowed: skipSetupAllowed(pages: ordered, ios27: ios27))
    }

    /// The reference's `add_skip_setup` gate, reproduced exactly:
    ///
    /// ```python
    /// if self.pref_manager.skip_setup and (restoring_domains
    ///         or (dev_version and Version(dev_version) < Version("27.0"))):
    /// ```
    ///
    /// In the reset path `uses_domains` is set by two branches: Daemons, and the
    /// StatusBar archive reset on iOS 27 (a real domain delivery). So on **iOS 27
    /// a Springboard-only or Internal-only reset carries no `skip_setup` files at
    /// all**, and only a reset that ticks Daemons or Status Bar (or any
    /// combination containing one) picks them up. On iOS 26 the version arm is
    /// true, so they always ride along. The reference does not explain the iOS 27
    /// arm; its own comment argues the files are safe regardless ("they always
    /// carry real domains, so they can always ride the domain delivery"), which
    /// makes the flag look like a leftover from the tweak path. It is kept as
    /// written so a diff against the reference is empty — the trade-off is a
    /// Springboard-only reset on iOS 27 leaving the setup wizard state alone.
    ///
    /// Note the reference's StatusBar branch is the iOS 27 `archive` arm only;
    /// on iOS 26 the classic arm appends to `files_to_restore` directly and does
    /// not set the flag — but the version arm already makes the gate true there,
    /// so the outcome is the same.
    static func skipSetupAllowed(pages: [ResetPage], ios27: Bool) -> Bool {
        let usesDomains = pages.contains(.daemons) || (ios27 && pages.contains(.statusBar))
        return usesDomains || !ios27
    }
}

