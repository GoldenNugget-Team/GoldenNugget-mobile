import Foundation
import SwiftUI

/// Whether every apply adds the two skip-setup files ahead of the tweaks.
///
/// This used to sit beside a `supervised` flag and an organization name, in a
/// store called `SupervisionSettings` and on a page called Supervision. Both are
/// gone: the page only ever *recorded* the intent, and it recorded it wrongly.
/// Upstream (`src/restore/skip_setup27.py` `build_cloud_config`) turns the pair
/// into a Setup cloud configuration carrying `IsSupervised`, `OrganizationName`,
/// a fresh `OrganizationMagic` and `SupervisorHostCertificates` — the public half
/// of a generated keybag x509, which is what makes a supervised device accept
/// profiles at all. This port never wrote the certificates, so a device it
/// "supervised" was in a state the reference never produces on purpose, and the
/// reference's own README warns that a half-applied supervision state is worse
/// than none. Rather than keep a switch that cannot deliver what it claims, the
/// supervised half is gone and what remains is the one part that was true on its
/// own: the two files, written as the un-supervised variant.
final class SkipSetupSettings: ObservableObject {
    static let shared = SkipSetupSettings()

    /// Upstream's `pref_manager.skip_setup`: when it is on, **every** apply adds
    /// the two skip-setup files ahead of the tweaks (`device_manager.add_skip_setup`
    /// → `SkipSetup.build`).
    ///
    /// **Upstream defaults this to `True`** (`preference_manager.py:19`, and its
    /// Nugget GUI reads `settings.value("skip_setup", True)`), and so does this
    /// now. It used to default to `False` here on purpose: the feature had not
    /// been through a device run, and defaulting it on would have added two
    /// files to every apply — including the first run that had to prove the rest
    /// of the pipeline. That is no longer the reason to hold it back, and the
    /// file set now matches the reference's without anyone having to remember
    /// a switch.
    ///
    /// What it costs, and it is a real cost, not a caveat to be filed: the files
    /// only ride an apply that restores through a backup. The AirLift path
    /// returns before the payload stage, so with skip setup on and no tweaks
    /// ticked, a wallpapers-only run delivers no files at all — which
    /// `GoldenNuggetEngine` reports as "nothing to apply" rather than passing for
    /// a run that did something.
    ///
    /// As with any `@AppStorage` default, this only decides the value where
    /// there is no stored one. A device that had the switch off keeps it off.
    @AppStorage("SkipSetupEnabled") private var skipSetup: Bool = true

    private init() {}

    var skipSetupEnabled: Bool { skipSetup }

    func setSkipSetup(_ on: Bool) { skipSetup = on }
}
