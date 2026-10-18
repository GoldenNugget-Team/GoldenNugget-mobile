#!/usr/bin/env python3
"""Run real minimuxer endpoint refresh logic with controlled routes/TCP probes.

Requires macOS and Swift. Only scanner input and TCP reachability are doubled;
the connection manager, endpoint, and network observer run their shipping code.
No pairing keys or device connection are needed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor/MinimuxerSources"

SUPPORT = r'''
import Foundation
protocol DeviceGatewayAPI: AnyObject, Sendable {
    var servicePort: UInt16 { get }
    var pairingFileType: String { get }
    func setDeviceEndpointIp(_ ip: String?)
}
final class Gateway: DeviceGatewayAPI, @unchecked Sendable {
    let servicePort: UInt16 = 49152
    let pairingFileType = "rppairing"
    var ip: String?
    func setDeviceEndpointIp(_ ip: String?) { self.ip = ip }
}
protocol NetworkObserverAPI {}
enum MinimuxerConstants { static let defaultTCPProbeTimeoutMs = 3000 }
func verboseLog(_ message: @autoclosure () -> String) {}
func debugLog(_ message: @autoclosure () -> String) {}
final class UsbmuxdProxyServer {
    var attached: String?
    func notifyDeviceAttached(tunnelPeerIp: String) { attached = tunnelPeerIp }
    func notifyDeviceDetached() { attached = nil }
}
enum TestScanner {
    nonisolated(unsafe) static var interfaces: Set<NetInfo> = []
    static func scan(quiet: Bool = false) -> Set<NetInfo> { interfaces }
}
enum NetworkUtils {
    nonisolated(unsafe) static var reachable: Set<String> = []
    static func testTCP(ip: String, port: UInt16, timeoutMs: Int) -> Bool {
        precondition(port == 49152, "probe must use the active pairing protocol's port")
        return reachable.contains(ip)
    }
}
final class Config: @unchecked Sendable {
    var peer = "10.7.0.1"
    var mode = DeviceConnectionMode.localVPN
    var overrideReachable = false
    var binding: ConnectionConfigBinding {
        ConnectionConfigBinding(
            setTunnelIfaceIp: { _ in }, setTunnelPeerIp: { _ in },
            setTunnelPeerSubnetMask: { _ in }, setTunnelPeerReachable: { _ in },
            setTunnelIfaceSubnetMask: { _ in }, getRemoteServerIp: { "10.8.0.1" },
            setRemoteReachable: { _ in }, getOverrideTunnelPeerIp: { self.peer },
            setOverrideTunnelPeerReachable: { self.overrideReachable = $0 },
            getConnectionMode: { self.mode })
    }
}
@main struct Check {
    static func main() async throws {
        let gateway = Gateway()
        let manager = DeviceConnectionManager(gateway: gateway)
        let endpoint = DeviceEndpoint(gateway: gateway)
        let proxy = UsbmuxdProxyServer()
        let observer = NetworkObserverService(connectionManager: manager,
                                              endpoint: endpoint, proxyServer: proxy)
        let config = Config()
        await manager.bindConnectionConfig(config.binding)
        func expect(_ ip: String?, _ label: String) async {
            let actual = try? await endpoint.ip()
            precondition(actual == ip && gateway.ip == ip && proxy.attached == ip, label)
            print("PASS: \(label)")
        }
        NetworkUtils.reachable = ["10.7.0.1"]
        await observer.refreshEndpoint()
        await expect("10.7.0.1", "configured peer works without discovered routes")
        let discovered = await manager.vpnIface
        precondition(discovered == nil && config.overrideReachable)
        await observer.refreshEndpoint()
        await expect("10.7.0.1", "unchanged refresh preserves endpoint")
        NetworkUtils.reachable = []
        await observer.refreshEndpoint()
        await expect(nil, "unreachable configured peer clears endpoint and attachment")
        NetworkUtils.reachable = ["10.7.0.1"]
        await observer.refreshEndpoint()
        await expect("10.7.0.1", "peer recovers without a route change")
        config.peer = "10.9.0.1"
        NetworkUtils.reachable = ["10.9.0.1"]
        await observer.refreshEndpoint()
        await expect("10.9.0.1", "changing configured peer updates endpoint")

        let local = IPv4Info(host: "10.7.0.0", mask: "255.255.255.255",
                             hostRaw: 0x0a070000, maskRaw: 0xffffffff)
        let peer = IPv4Info(host: "10.7.0.1", mask: "255.255.255.255",
                            hostRaw: 0x0a070001, maskRaw: 0xffffffff)
        let tunnel = try TunnelNetInfo(name: "utun999", interfaceIndex: 65534,
            interfaceAddresses: IPAddresses(v4: [local]),
            linkLayerDestinationIP: IP(v4: peer), routes: RouteSnapshot.captureRoutes())
        TestScanner.interfaces = [tunnel]
        NetworkUtils.reachable = ["10.7.0.1"]
        await observer.refreshEndpoint()
        await expect(nil, "unreachable override does not fall back to another reachable peer")
        config.peer = ""
        await observer.refreshEndpoint()
        await expect("10.7.0.1", "automatic discovery still works without an override")
        TestScanner.interfaces = []
        await observer.refreshEndpoint()
        await expect(nil, "loss of automatically discovered tunnel clears endpoint")
        config.mode = .remoteServer
        NetworkUtils.reachable = ["10.8.0.1"]
        await observer.refreshEndpoint()
        await expect("10.8.0.1", "remote server mode still works")
    }
}
'''


def main():
    api = (VENDOR / "MinimuxerApi.swift").read_text()
    source = api[api.index("public enum DeviceConnectionMode"):api.index("public protocol MinimuxerAPI")]
    source += api[api.index("public enum LocalInterfaceType"):api.index("public protocol NetworkObserverAPI")]
    for name in ["Services/NetworkIfaceScanner.swift", "Services/DeviceConnectionManager.swift",
                 "Services/DeviceEndpoint.swift", "Services/NetworkObserverService.swift",
                 "MinimuxerInternalError.swift"]:
        body = (VENDOR / name).read_text()
        body = "\n".join(line for line in body.splitlines()
                         if line not in ("internal import MinimuxerCommon", "internal import DeviceGatewayAPI"))
        # Inject controlled OS inputs without replacing the implementation under test.
        body = body.replace("NetworkIfaceScanner.scan(", "TestScanner.scan(")
        source += "\n" + body
    with tempfile.TemporaryDirectory(prefix="goldennugget-tunnel-") as folder:
        swift = Path(folder) / "Check.swift"
        swift.write_text(SUPPORT + source)
        binary = Path(folder) / "check"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
