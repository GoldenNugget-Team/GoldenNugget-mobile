import Foundation

/// How a PosterBoard selection reaches the device.
///
/// There are two, and they are not two implementations of one thing — they are two
/// different mechanisms that happen to install the same wallpapers, so the choice
/// belongs to the user and the UI has to say what it costs.
///
///  - `.backup` is this port's original path: fetch the store's database, compile
///    the packs into payloads, and ride them through a protective backup and a
///    restore. It is the *reference's* mechanism, it works on every device the
///    rest of the app works on, and it ends in a reboot.
///  - `.airlift` is the AirCard path: open an AirTraffic tunnel over the pairing
///    record this app already holds and write straight into PosterBoard's data
///    container. No backup, no reboot — a respring is enough — but it needs
///    iOS 26.2+, LocalDevVPN, an unlocked device, and it cannot do a store reset.
///
/// AirLift is the default. The backup path is this port's original mechanism, not
/// a better one: it costs a full protective backup and a reboot, and it only has
/// something left to do that AirLift cannot — the store reset. A user who wants
/// neither pays nothing for either default, so the cheaper one is the default.
enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case airlift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: return "Protective backup"
        case .airlift: return "AirLift (AirTraffic)"
        }
    }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .airlift: return "bolt.horizontal.circle.fill"
        }
    }

    /// What the apply will and will not do, in the user's terms.
    var summary: String {
        switch self {
        case .backup:
            return "Fetches the store database, then carries the wallpapers through a "
                + "protective backup. Works on every supported device, ends in a reboot."
        case .airlift:
            return "Writes into PosterBoard's container over a tunnel — no backup, and a "
                + "respring instead of a reboot. Needs iOS 26.2 or newer, LocalDevVPN and "
                + "an unlocked device."
        }
    }

    /// Whether a reset can be honoured in this mode.
    ///
    /// A reset is a store operation: it clears what PosterBoard has indexed. The
    /// AirLift path only ever adds a descriptor directory, so a reset selected
    /// there is not silently dropped — the apply says it cannot and stops before
    /// touching the device.
    var supportsReset: Bool {
        self == .backup
    }
}

/// The selected mode, persisted the same way `autoRefresh` is.
enum PosterBoardApplyModeSettings {
    static let key = "PosterBoardApplyMode"

    /// AirLift unless something says otherwise.
    ///
    /// The stored value is the only thing that can move this off AirLift, and a
    /// device that has never touched the picker has nothing stored — so the
    /// default is what such a device gets.
    static var current: PosterBoardApplyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .airlift }
            return PosterBoardApplyMode(rawValue: raw) ?? .airlift
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
