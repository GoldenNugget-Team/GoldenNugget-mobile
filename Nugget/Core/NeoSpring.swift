import UIKit
import WebKit

/// A respring — a userspace restart — without a reboot, by the method AirCard
/// uses: NeoSpring (rooootdev/neospring, by neonmodder123 & skadz108).
///
/// ## Why this and not a command over the tunnel
///
/// The obvious implementation is `SPRestartUserspace` on
/// `com.apple.springboardservices`, and it does not work. That was tried here:
/// the tunnel finds the service, the request is sent, the channel closes about
/// 40 ms later, and the device carries on untouched. The close is the service
/// dropping an unrecognised request, not SpringBoard going down — the log reads
/// exactly like a success either way, which is what made it worth taking out.
///
/// NeoSpring needs no device service at all. It loads a payload into a
/// `WKWebView` in our own window: a few hundred full-screen layers with
/// `backdrop-filter: blur(100px)`, each pushed a pixel further along Z in a
/// perspective container, then a `setInterval` that hammers `navigator.share`
/// and allocates 10 MB of random bytes every tick. That drives the WebKit
/// content process into the same state as the respring in Apple's own
/// double-tap-to-respring, and the userspace restarts underneath us. The
/// payload is verbatim upstream, because it is a set of magic numbers and
/// nothing here has been verified with different ones.
///
/// ## What the user sees
///
/// A black screen with a blur, for a second or two, then the home screen. That
/// is the respring itself, not a failure state. Our own app is a normal app,
/// not something under SpringBoard, so it survives the restart and comes back
/// with its window intact.
enum NeoSpring {
    /// The payload, verbatim from rooootdev/neospring. Do not "tidy" it:
    /// the layer count, the 100px blur, the 100000px Z offsets and the zero
    /// interval are all load-bearing, and the inner `<\/script>` has to stay
    /// escaped or the outer `<script>` block ends early and nothing runs.
    private static let payload = """
    <!DOCTYPE html>
    <html>
        <body>
            <!-- big credit to @neonmodder123 & @skadz108 (neospring) -->
            <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
            <script>
                const frame = document.getElementById('frame');
                const funfun = `
                    <html>
                    <body>
                        <script>
                            const container = document.createElement('div');
                            container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                            document.body.appendChild(container);

                            for (let i = 0; i < 500; i++) {
                                let d = document.createElement('div');
                                d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                                container.appendChild(d);
                            }

                            setInterval(() => {
                                navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                                let x = new Uint8Array(1024 * 1024 * 10);
                                crypto.getRandomValues(x);
                            }, 0);
                        <\\/script>
                    </body>
                    </html>
                `;

                frame.srcdoc = funfun;
            </script>
        </body>
    </html>
    """

    /// Held for as long as the view is on screen. A `WKWebView` that nothing
    /// references is deallocated, and the payload dies with it — the respring
    /// would then depend on WebKit having happened to keep it alive.
    private static var active: WKWebView?

    /// Attach the payload to our key window and start the respring.
    ///
    /// - Returns: `false` when there is no window to attach to, which means
    ///   nothing was triggered — the caller has to say so rather than report a
    ///   respring that never started.
    @MainActor
    static func trigger() -> Bool {
        guard let window = keyWindow() else { return false }
        // A second respring while one is running would replace the view and
        // restart the payload's timers instead of letting the first land.
        guard active == nil else { return true }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: window.bounds, configuration: configuration)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        active = webView
        window.addSubview(webView)
        webView.loadHTMLString(payload, baseURL: nil)

        // If the respring does happen, this process outlives the old scene and
        // the view goes with it. If it somehow does not, the payload is an
        // unbounded CPU and memory loop, so take it down rather than leave the
        // phone hot with a black screen on top of the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { release() }
        return true
    }

    /// Take the view back down. Called on a timer as a backstop, and on a
    /// second trigger to refuse politely.
    @MainActor
    private static func release() {
        guard let webView = active else { return }
        active = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
            if let any = scene.windows.first { return any }
        }
        return nil
    }
}
