// GENERATED FILE — do not edit by hand.
//
// Source of truth: GoldenNugget's `src/tweaks/daemons_tweak.py` and the
// group tables in `src/gui/ios/daemons.py`.  Regenerate with:
//
//     scripts/gen-daemons-from-goldennugget.py [--goldennugget <path>]
//
// Daemons are not in `registry.py` -- upstream registers them in
// `load_daemons()` as a single `AdvancedPlistTweak` over the launchd
// `disabled.plist`, and builds the per-group switches in the GUI. One
// spec per group is what lets them ride the port's Apply, autosave and
// preset paths, all of which work off the catalog.

import Foundation

/// One switch on the Daemons page: a named group of launchd labels that
/// are disabled together.
///
/// `showsSwitch` is false for the six interface-visible groups upstream
/// gives no switch of its own (AppleAds, CrashReports, Diagnostics,
/// Feedback, SettingsStats, Shazam). They stay in the catalog -- they are
/// part of `INTERFACE_DAEMONS` and the Recommended set turns them on --
/// but the page must not offer a per-group switch for them.
struct DaemonGroup: Sendable {
    let name: String
    let title: String
    let labels: [String]
    let section: DaemonSection
    let isRecommended: Bool
    let showsSwitch: Bool
}

/// The two groups of switches on the Daemons page, in the reference's order.
enum DaemonSection: String, CaseIterable, Identifiable, Sendable {
    case disable = "Daemons to Disable"
    case analytics = "Analytics, Data Tracking & Logging"
    var id: String { rawValue }
}

enum DaemonGroups {
    static let all: [DaemonGroup] = [
        DaemonGroup(
            name: "thermalmonitord",
            title: "Disable thermalmonitord",
            labels: ["com.apple.thermalmonitord"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "OTA",
            title: "Disable OTA",
            labels: ["com.apple.mobile.softwareupdated", "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd", "com.apple.mobile.NRDUpdated"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "UsageTrackingAgent",
            title: "Disable UsageTrackingAgent",
            labels: ["com.apple.UsageTrackingAgent"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "GameCenter",
            title: "Disable Game Center",
            labels: ["com.apple.gamed"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "ATWAKEUP",
            title: "Disable ATWAKEUP",
            labels: ["com.apple.atc.atwakeup"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Tips",
            title: "Disable Tips Services",
            labels: ["com.apple.tipsd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "VPN",
            title: "VPN Icon",
            labels: ["com.apple.racoon"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "ChineseLAN",
            title: "Disable Chinese WLAN Service",
            labels: ["com.apple.wapic", "com.apple.wifi.wapic"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "HealthKit",
            title: "Disable HealthKit",
            labels: ["com.apple.healthd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "AirPrint",
            title: "Disable AirPrint",
            labels: ["com.apple.printd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "AssistiveTouch",
            title: "Disable Assistive Touch",
            labels: ["com.apple.assistivetouchd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "iCloud",
            title: "Disable iCloud",
            labels: ["com.apple.itunescloudd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "InternetTethering",
            title: "Disable Internet Tethering (Hotspot)",
            labels: ["com.apple.MobileInternetSharing"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "PassBook",
            title: "Disable Passbook",
            labels: ["com.apple.passd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Spotlight",
            title: "Disable Spotlight",
            labels: ["com.apple.searchd", "com.apple.corespotlightservice", "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater", "com.apple.spotlight.IndexAgent"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "NanoTimeKit",
            title: "Disable NanoTimeKit (Apple Watch Face Sync)",
            labels: ["com.apple.nanotimekitcompaniond"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "VoiceControl",
            title: "Disable Voice Control",
            labels: ["com.apple.assistant_service", "com.apple.assistantd", "com.apple.voiced"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "FollowUp",
            title: "Follow Up",
            labels: ["com.apple.followupd"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Location",
            title: "Location Services",
            labels: ["com.apple.locationd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "WifiAnalytics",
            title: "Disable Wi-Fi Analytics",
            labels: ["com.apple.wifianalyticsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "AnalyticsHelper",
            title: "Disable System Analytics",
            labels: ["com.apple.analyticsd", "com.apple.analyticsd.admin", "com.apple.analyticsd.events"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "CallAnalytics",
            title: "Disable Call Analytics (RTC Reporting)",
            labels: ["com.apple.rtcreportingd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "CoreDuet",
            title: "Disable CoreDuet (Battery/Usage Statistics)",
            labels: ["com.apple.coreduetd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Insight",
            title: "Disable Insight",
            labels: ["com.apple.insightd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Metrics",
            title: "Disable Metrics",
            labels: ["com.apple.metricsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "MediaExperience",
            title: "Disable Media Experience Analytics",
            labels: ["com.apple.mediaremoted"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Symptomsd",
            title: "Disable Symptom Diagnostics",
            labels: ["com.apple.symptomsd", "com.apple.symptomsd-app"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "StatisticalDiagnostic",
            title: "Disable Statistical Diagnostics",
            labels: ["com.apple.StatisticalDiagnosticService"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "WirelessDiagnostics",
            title: "Disable Wireless Diagnostics",
            labels: ["com.apple.wirelessdiagnostics"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "DuetHeuristic",
            title: "Disable Duet Heuristic",
            labels: ["com.apple.DuetHeuristic-BM", "com.apple.DuetHeuristic-BM.Baseband"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "DuetExpert",
            title: "Disable Duet Expert",
            labels: ["com.apple.duetexpertd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Decisiond",
            title: "Disable Decisiond",
            labels: ["com.apple.decisiond"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Triald",
            title: "Disable Triald (A/B Experiment Telemetry)",
            labels: ["com.apple.triald"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "Sociald",
            title: "Disable Sociald",
            labels: ["com.apple.sociald"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true
        ),
        DaemonGroup(
            name: "AppleAds",
            title: "AppleAds",
            labels: ["com.apple.promotedcontentd", "com.apple.adprivacyd", "com.apple.adservicesd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
        DaemonGroup(
            name: "CrashReports",
            title: "CrashReports",
            labels: ["com.apple.ReportCrash", "com.apple.ReportCrash.Jetsam", "com.apple.ReportMemoryException", "com.apple.OTACrashCopier", "com.apple.analyticsd", "com.apple.wifianalyticsd", "com.apple.aslmanager", "com.apple.coresymbolicationd", "com.apple.crash_mover", "com.apple.crashreportcopymobile", "com.apple.DumpBasebandCrash", "com.apple.DumpPanic", "com.apple.logd", "com.apple.logd.admin", "com.apple.logd.events", "com.apple.logd.watchdog", "com.apple.logd_helper", "com.apple.logd_reporter", "com.apple.logd_reporter.report_statistics", "com.apple.system.logger", "com.apple.hangreporter", "com.apple.hangtracerd", "com.apple.spindump", "com.apple.tailspind", "com.apple.rtcreportingd", "com.apple.syslogd", "com.apple.signpost.signpost_reporter", "com.apple.pluginkit.pkreporter", "com.apple.ProxiedCrashCopier", "com.apple.ProxiedCrashCopier.ProxyingDevice", "com.apple.ReportSystemMemory"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
        DaemonGroup(
            name: "Diagnostics",
            title: "Diagnostics",
            labels: ["com.apple.diagnosticd", "com.apple.diagnosticextensionsd", "com.apple.diagnosticservicesd", "com.apple.diagnosticspushd", "com.apple.symptomsd-diag", "com.apple.sysdiagnose", "com.apple.sysdiagnose.darwinos", "com.apple.sysdiagnose_helper"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
        DaemonGroup(
            name: "Feedback",
            title: "Feedback",
            labels: ["com.apple.feedbackd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
        DaemonGroup(
            name: "SettingsStats",
            title: "SettingsStats",
            labels: ["com.apple.settings-statsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
        DaemonGroup(
            name: "Shazam",
            title: "Shazam",
            labels: ["com.apple.shazamd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: false
        ),
    ]

    /// The one-tap "Recommended" set: pure analytics, tracking and
    /// logging, nothing boot-critical.  Upstream's comment on
    /// `RECOMMENDED_ANALYTICS` says the same.
    static let recommended: [DaemonGroup] = all.filter(\.isRecommended)

    static let byName: [String: DaemonGroup] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// Every launchd label the reference will let a preset carry.  Mirrors
    /// `INTERFACE_KEYS`: a label outside this set must never reach the
    /// plist, because disabling those daemons broke whole apps on 26.5.
    static let allowedKeys: Set<String> = [
        "com.apple.DuetHeuristic-BM",
        "com.apple.DuetHeuristic-BM.Baseband",
        "com.apple.DumpBasebandCrash",
        "com.apple.DumpPanic",
        "com.apple.MobileInternetSharing",
        "com.apple.OTACrashCopier",
        "com.apple.OTATaskingAgent",
        "com.apple.ProxiedCrashCopier",
        "com.apple.ProxiedCrashCopier.ProxyingDevice",
        "com.apple.ReportCrash",
        "com.apple.ReportCrash.Jetsam",
        "com.apple.ReportMemoryException",
        "com.apple.ReportSystemMemory",
        "com.apple.StatisticalDiagnosticService",
        "com.apple.UsageTrackingAgent",
        "com.apple.adprivacyd",
        "com.apple.adservicesd",
        "com.apple.analyticsd",
        "com.apple.analyticsd.admin",
        "com.apple.analyticsd.events",
        "com.apple.aslmanager",
        "com.apple.assistant_service",
        "com.apple.assistantd",
        "com.apple.assistivetouchd",
        "com.apple.atc.atwakeup",
        "com.apple.coreduetd",
        "com.apple.corespotlightservice",
        "com.apple.coresymbolicationd",
        "com.apple.crash_mover",
        "com.apple.crashreportcopymobile",
        "com.apple.decisiond",
        "com.apple.diagnosticd",
        "com.apple.diagnosticextensionsd",
        "com.apple.diagnosticservicesd",
        "com.apple.diagnosticspushd",
        "com.apple.duetexpertd",
        "com.apple.feedbackd",
        "com.apple.followupd",
        "com.apple.gamed",
        "com.apple.hangreporter",
        "com.apple.hangtracerd",
        "com.apple.healthd",
        "com.apple.insightd",
        "com.apple.itunescloudd",
        "com.apple.locationd",
        "com.apple.logd",
        "com.apple.logd.admin",
        "com.apple.logd.events",
        "com.apple.logd.watchdog",
        "com.apple.logd_helper",
        "com.apple.logd_reporter",
        "com.apple.logd_reporter.report_statistics",
        "com.apple.mediaremoted",
        "com.apple.metricsd",
        "com.apple.mobile.NRDUpdated",
        "com.apple.mobile.softwareupdated",
        "com.apple.nanotimekitcompaniond",
        "com.apple.passd",
        "com.apple.pluginkit.pkreporter",
        "com.apple.printd",
        "com.apple.promotedcontentd",
        "com.apple.racoon",
        "com.apple.rtcreportingd",
        "com.apple.searchd",
        "com.apple.settings-statsd",
        "com.apple.shazamd",
        "com.apple.signpost.signpost_reporter",
        "com.apple.sociald",
        "com.apple.softwareupdateservicesd",
        "com.apple.spindump",
        "com.apple.spotlight.IndexAgent",
        "com.apple.spotlightknowledged",
        "com.apple.spotlightknowledged.updater",
        "com.apple.symptomsd",
        "com.apple.symptomsd-app",
        "com.apple.symptomsd-diag",
        "com.apple.sysdiagnose",
        "com.apple.sysdiagnose.darwinos",
        "com.apple.sysdiagnose_helper",
        "com.apple.syslogd",
        "com.apple.system.logger",
        "com.apple.tailspind",
        "com.apple.thermalmonitord",
        "com.apple.tipsd",
        "com.apple.triald",
        "com.apple.voiced",
        "com.apple.wapic",
        "com.apple.wifi.wapic",
        "com.apple.wifianalyticsd",
        "com.apple.wirelessdiagnostics",
    ]

    /// `DANGEROUS_KEYS` upstream, which is empty by design: entries are
    /// deleted from the reference rather than blocked at runtime.  Kept so a
    /// future upstream entry shows up as a diff instead of silently
    /// becoming writable.
    static let dangerousKeys: Set<String> = [
    ]

    /// `TweakID.ClearScreenTimeAgentPlist`: a `NullifyFileTweak`, i.e. a
    /// 0-byte file written over the plist rather than a serialised dict.
    static let screenTime = DaemonNullify(
        id: "ClearScreenTimeAgentPlist",
        title: "Disable Screen Time Agent",
        path: "/var/mobile/Library/Preferences/com.apple.ScreenTimeAgent.plist"
    )
}

/// A file the port overwrites with zero bytes rather than serialising.
struct DaemonNullify: Sendable {
    let id: String
    let title: String
    let path: String
}

extension TweakCatalog {
    /// The daemon groups as tweak specs, so Apply, autosave and preset
    /// import all work on them unchanged.
    ///
    /// `multiValues` carries the group's labels mapped to `false`: a group is
    /// "on" when the user wants it disabled, and the compiler writes the
    /// labels of every on-group into the launchd `disabled.plist`.
    static let daemonSpecs: [TweakSpec] = DaemonGroups.all.map { group in
        TweakSpec(
            id: "Daemon.\(group.name)",
            section: .daemons,
            title: group.title,
            location: .disabledDaemons,
            key: "",
            value: .bool(false),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 1.0,
            step: 1.0,
            minVersion: nil,
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Disables \(group.labels.count) launchd "
                + "\(group.labels.count == 1 ? "daemon" : "daemons"): "
                + group.labels.joined(separator: ", ") + ".",
            multiValues: Dictionary(
                uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(false)) }
            )
        )
    }

    /// The ScreenTime nullify, which is not a daemon group and so has no
    /// `multiValues`: it truncates a file instead of writing a dict.
    static let screenTimeSpec = TweakSpec(
        id: "\(DaemonGroups.screenTime.id)",
        section: .daemons,
        title: "\(DaemonGroups.screenTime.title)",
        location: .screentime,
        key: "",
        value: .bool(false),
        kind: .toggle,
        minValue: 0.0,
        maxValue: 1.0,
        step: 1.0,
        minVersion: nil,
        maxVersion: nil,
        iphoneOnly: false,
        ipadOnly: false,
        disabled: false,
        detail: "Writes a 0-byte file over "
            + "\(DaemonGroups.screenTime.path).",
        multiValues: nil
    )
}
