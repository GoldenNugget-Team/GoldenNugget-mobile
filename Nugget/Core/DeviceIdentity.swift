import Foundation
import Minimuxer
import SwiftUI

/// The two device facts the tweak registry's compatibility bounds need.
///
/// GoldenNugget reads them off lockdown (`get_current_device_version` /
/// `get_current_device_model`) and hands them to
/// `gui/ios/compat.py:is_tweak_compatible`.  This is the same pair, read the
/// same way — `ProductVersion` and `ProductType` through
/// `getLockdownValue`, which is the call `Vendor/MinimuxerSources/Services/
/// Mounter.swift` already uses for `ProductVersion`.
struct DeviceIdentity: Equatable, Sendable {
    /// Lockdown `ProductVersion`, e.g. `27.0`.
    let version: String
    /// Lockdown `ProductType`, e.g. `iPad16,2`.
    let productType: String

    /// The reference's device test (`src/gui/ios/tweaks.py:107`):
    /// `model.startswith("iPhone")`.
    var isIPhone: Bool { productType.hasPrefix("iPhone") }

    var describe: String {
        if productType.isEmpty && version.isEmpty { return "unknown device" }
        if productType.isEmpty { return "iOS \(version)" }
        if version.isEmpty { return productType }
        return "\(productType) / iOS \(version)"
    }

    /// Used when the read fails.  An empty version deliberately *disables* the
    /// registry's version bounds rather than failing them: the reference's
    /// `if device_version and spec.min_version` does the same, so a device we
    /// cannot identify shows the full list instead of an empty one.
    static let unknown = DeviceIdentity(version: "", productType: "")

    static func read() async -> DeviceIdentity {
        guard let gateway = Minimuxer.shared().ideviceGateway else { return .unknown }
        let version = ((try? await gateway.getLockdownValue(key: "ProductVersion")) ?? nil) ?? ""
        let productType = ((try? await gateway.getLockdownValue(key: "ProductType")) ?? nil) ?? ""
        return DeviceIdentity(version: version, productType: productType)
    }
}

/// The auto-refreshing copy of `DeviceIdentity`, shared by every page that draws it.
///
/// Each page used to read lockdown once, in its own `.task`, when it appeared, and
/// keep the result for as long as it stayed in the hierarchy.  That snapshot goes
/// stale in two ways, and neither is cosmetic.  The first read of a session races
/// minimuxer's start and comes back `.unknown`, so a page opened before the tunnel
/// was up said "unknown device" until it was left and re-entered — the refresh
/// button on the home header exists because of it.  And a device that reboots into
/// a new iOS, or is swapped for another one under a live tunnel, is still described
/// by whatever was read at launch.  An empty version is the worse of the two states:
/// it *disables* the registry's version bounds (`TweakSpec.isCompatible` skips them,
/// as the reference does) and it parses to major 0, which is how a 27.0 device
/// ended up on the engine's iOS 26 branch and died with `205 — No keybag in manifest`.
///
/// So the read is owned here and keeps being made — one poll for the whole app
/// rather than one per page, because the four pages that draw the device line are
/// siblings in the same hierarchy and four loops would be four sets of RSD traffic
/// to keep in step.  `current` is written **only when the value actually changes**:
/// a `@Published` write per tick would redraw the header, the tweaks list and the
/// status line for nothing, and the tweaks page is a hundred rows filtered by
/// exactly this value.
///
/// `read()` stays the one-shot, caller-owned read and is still what a *run* uses:
/// `applyTweaks` deliberately re-reads the device at the start of a run rather than
/// trusting the value a page was drawn with, and the cache is a UI convenience, not
/// an input to a restore.
final class DeviceIdentityMonitor: ObservableObject {
    static let shared = DeviceIdentityMonitor()

    /// What the pages draw.  Main actor only, and only ever a change.
    @Published private(set) var current: DeviceIdentity = .unknown

    /// The running poll, or `nil` when it is stopped.  Main actor only.
    private var loop: Task<Void, Never>?

    /// How often the poll reads.
    ///
    /// Thirty seconds, not the five the tunnel status uses, because an RSD read is
    /// not a property fetch: `syncGetLockdownValue` opens the tunnel, resolves the
    /// RSD port, connects a service stream, runs the `RSDCheckin` handshake, asks one
    /// key and closes — and there are two keys per poll.  At thirty seconds that is
    /// traffic an idle tunnel was not making before, and it buys the thing that
    /// matters: a device that was swapped, rebooted or re-paired under a live tunnel
    /// renames itself within half a minute instead of at the next launch.
    static let interval: Duration = .seconds(30)

    private init() {}

    /// Start polling.  Idempotent — a call while the loop is running is a no-op, so
    /// a page that starts it on every appear cannot double the rate.
    ///
    /// The first read is immediate rather than one interval in: coming back from the
    /// background is exactly when a stale version is most visible, and `stop()` on
    /// the way out means `start()` is a fresh loop.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: DeviceIdentityMonitor.interval)
            }
        }
    }

    /// Stop polling, so a backgrounded app is not asking lockdown anything.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One read, published only if it differs from what is already there.
    ///
    /// Reports whether it changed, for a caller that has to react to one rather
    /// than merely redraw: the Tweaks page re-applies the autosave bootstrap
    /// against a device it has not seen before, because the version decides which
    /// stored tweaks apply to it.  Nothing does that in reaction to a *poll's*
    /// change — see `GoldenNuggetView` — so the return value is only true for the
    /// read a caller asked for.
    @discardableResult
    func refresh() async -> Bool {
        let read = await DeviceIdentity.read()
        return await MainActor.run { publishOnMainActor(read) }
    }

    /// Publish a value the caller has already read — the home page's bounded wait
    /// for the device to answer lockdownd produces one, and reading it again would
    /// be a second handshake for an answer already in hand.
    ///
    /// Deduplicates like `refresh`, so the "only ever a change" invariant that keeps
    /// the poll from redrawing the pages holds for this path too.
    @discardableResult
    func publish(_ read: DeviceIdentity) async -> Bool {
        await MainActor.run { publishOnMainActor(read) }
    }

    /// The one place `current` is written, and the one place a change is logged.
    ///
    /// Logging here rather than at the call sites is what makes the log mean
    /// something: it records the transitions, not every read.  A device that answers
    /// once and stays the same produces one line, not one per tick.
    @discardableResult
    private func publishOnMainActor(_ read: DeviceIdentity) -> Bool {
        guard read != current else { return false }
        current = read
        if read == .unknown {
            GoldenNuggetEngine.shared.log("device identity unavailable — the device has not answered lockdown yet")
        } else {
            GoldenNuggetEngine.shared.log("device identity: \(read.describe)")
        }
        return true
    }
}
