import Foundation

/// "Skip Setup": the two files upstream's `add_skip_setup` adds to **every**
/// apply, ported so this app can do the same once the switch in Settings is on.
///
/// Reference chain, all in `~/GoldenNugget`:
///
///   * `src/devicemanagement/device_manager.py:324-353` (`add_skip_setup`) —
///     appends the two files, cloud configuration first, and gates the whole
///     block on `pref_manager.skip_setup`;
///   * `src/restore/skip_setup27.py` — `SKIP_ALL_PANES` (the pane list; emitted
///     into `SkipSetupCatalog.swift` by `scripts/gen-skipsetup-from-goldennugget.py`)
///     and `build_cloud_config`, whose seven fixed keys are reproduced here;
///   * `src/restore/restore.py` — on iOS 26 the block rides the legacy
///     domain-delivery path, which is why the two files always carry real
///     domains even though nothing else in the apply does.
///
/// The file/row order is the reference's and is load-bearing only in the sense
/// that the directories must precede the files they contain — which is what
/// `TweakInjector` builds from the two payloads below, in this order:
///
///     SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles
///         "" · Library · Library/ConfigurationProfiles · …/CloudConfigurationDetails.plist
///     ManagedPreferencesDomain
///         "" · mobile · mobile/com.apple.purplebuddy.plist
///
/// **Deliberate divergences from the reference**, both reported as warnings on
/// every run so they cannot be mistaken for parity:
///
///   1. **No merge with the device's existing configuration.**  Upstream calls
///      `MobileConfigService.get_cloud_configuration()` and passes the result to
///      `build_cloud_config(existing, …)`; this port has no lockdown service for
///      that, so the file is written from these seven keys alone.  Any other key
///      the device was carrying in `CloudConfigurationDetails.plist` is therefore
///      not preserved.
///   2. **No `SupervisorHostCertificates`.**  Upstream generates an x509 from a
///      keybag (`pymobiledevice3.ca.create_keybag_file`) when the run is
///      supervised with an organization name; this port has no keybag generator,
///      so it writes `IsSupervised`/`OrganizationName`/`OrganizationMagic`
///      without the certificate and says so.  The app never selects that variant
///      — nothing here supervises a device — but the shape is kept so this code
///      still says plainly what it is not doing.
enum SkipSetup {

    /// Upstream's `cloud_config["SkipSetup"]` — the generated pane list.
    static var panes: [String] { SkipSetupCatalog.panes }

    /// The two payloads, in the reference's order, plus anything the caller
    /// should log about the divergences above.
    struct Build {
        let payloads: [TweakPayload]
        let warnings: [String]
    }

    static func build(supervised: Bool, organizationName: String) -> Build {
        let cloud = cloudConfiguration(supervised: supervised, organizationName: organizationName)
        let payloads = [
            TweakPayload(domain: "SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles",
                         relativePath: "Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
                         contents: xml(cloud.plist)),
            TweakPayload(domain: "ManagedPreferencesDomain",
                         relativePath: "mobile/com.apple.purplebuddy.plist",
                         contents: xml(purpleBuddy)),
        ]
        return Build(payloads: payloads, warnings: cloud.warnings)
    }

    /// `build_cloud_config(existing: [:], supervised:, organization_name:)`,
    /// without the keybag half (see divergence 2 above).
    ///
    /// The seven literals below are the function's own assignments; the pane list
    /// is generated.  `scripts/skipsetup-check.swift` compares the result against
    /// the reference's output for this device, which is the guard for both.
    static func cloudConfiguration(supervised: Bool,
                                   organizationName: String) -> (plist: [String: Any], warnings: [String]) {
        var config: [String: Any] = [
            "SkipSetup": panes,
            "AllowPairing": true,
            "ConfigurationWasApplied": true,
            "CloudConfigurationUIComplete": true,
            "IsSupervised": false,
            "ConfigurationSource": 0,
            "PostSetupProfileWasInstalled": true,
        ]
        var warnings: [String] = [
            "skip setup: the file is built from these keys alone — upstream merges it with the "
                + "device's existing CloudConfigurationDetails.plist (`build_cloud_config(existing:)`), "
                + "which this port cannot read (no MobileConfigService).",
        ]

        if supervised {
            config["IsSupervised"] = true
            let name = organizationName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                // Upstream drops the keybag fields in this case and warns nothing;
                // it is a state it does not produce on purpose.
                warnings.append("skip setup: supervised with no organization name — upstream strips "
                    + "the keybag fields here, so no certificate is written either.")
            } else {
                config["OrganizationName"] = name
                // `str(uuid4())` is lowercase, and the value round-trips into the
                // device's own state, so the case is kept as upstream writes it.
                config["OrganizationMagic"] = UUID().uuidString.lowercased()
                config["IsMDMUnremovable"] = false
                warnings.append("skip setup: SupervisorHostCertificates is NOT written — upstream "
                    + "generates an x509 from a keybag (pymobiledevice3 create_keybag_file) and this "
                    + "port has no generator, so the device gets a supervised flag with no certificate.")
            }
        }
        return (config, warnings)
    }

    /// Upstream's literal dict (`device_manager.py:344-348`).
    static var purpleBuddy: [String: Any] {
        ["SetupDone": true, "SetupFinishedAllSteps": true, "UserChoseLanguage": true]
    }

    /// `plistlib.dumps(plist)` — XML, which is the reference's default format and
    /// the one the device is given for every other injected plist here.
    ///
    /// Force-try is safe for the same reason it is in `buildMBFileBlob`: the graph
    /// is one flat dict of strings, booleans and integers, all plist-native.
    static func xml(_ plist: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
