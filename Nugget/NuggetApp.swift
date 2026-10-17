import SwiftUI
import Minimuxer

@main
struct GoldenNuggetApp: App {
    init() {
        // Development mode's logging switch, applied at launch rather than when the
        // settings page is opened: it governs the protocol half of every run, and a
        // stored preference that only took effect once the user visited a page would
        // mean a session's minimuxer.log was recorded under the wrong setting.
        DevSettings.applyLoggingPreference()

        // AirLift's log sink, installed at launch for two reasons.  The library
        // is linked into the binary, and a launch is the only moment a static
        // archive's symbols are proven good: if the linker or the packager had
        // dropped a member that dyld needs, the app would die here rather than
        // on a Wallet page.  And the sink is a one-shot `al_log_init` — a second
        // call returns "already subscribed" and logs nothing — so it belongs
        // where it can only happen once.
        if Airlift.install() {
            AppLog.write("AirLift: log sink installed (AirTraffic escape available on iOS 27+)")
        } else {
            AppLog.write("AirLift: log sink already installed by the library")
        }
        // Referenced so the linker keeps `_ALGetGrappaToken`: the FFI looks it
        // up with `dlsym(RTLD_DEFAULT, …)` when it writes, and an unreferenced
        // symbol would be stripped and the write would fail on
        // `SyncFailed` with no token to blame.
        Airlift.installGrappaTokenProvider()

        // LocalDevVPN compatibility: only start our own WireGuard server
        // (em_proxy at 127.0.0.1:51820) when no LocalDevVPN-style tunnel
        // (NEPacketTunnelProvider with iface 10.7.1.1) is already up.
        let tunnelUp = Tunnel.isInterfaceUp()
        // Goes through the app log rather than print(): on device the console is
        // not reachable, and the tunnel verdict is the first thing a failed run
        // needs to show in goldennugget.log.
        AppLog.write("Tunnel status: \(Tunnel.describe()) — em_proxy \(tunnelUp ? "skipped (LocalDevVPN active)" : "starting")")
        if !tunnelUp {
            let emproxy = Minimuxer.shared().emproxy
            emproxy.setHandshakeClient(host: "127.0.0.1", port: 51820, enabled: false)
            Task {
                do {
                    try await emproxy.start(host: "127.0.0.1", port: 51820)
                } catch {
                    AppLog.write("em_proxy failed to start: \(error)")
                }
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}