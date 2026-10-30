import SwiftUI
import UIKit

/// The app's shell: a **sidebar** on a tablet, a **tab bar** on a phone.
///
/// Each is the platform's own idiom, and each is there for the reason its device
/// has it. A tablet gets the sidebar: `NavigationSplitView` keeps every section
/// one tap away and handles a window whose width iOS picks itself (Slide Over
/// 320, Split View, iPadOS 26's free resizing) — in a narrow window it collapses
/// to one column without being told. A phone gets the tab bar, because that is
/// what the platform's apps use and what a thumb reaches: the four pages a
/// session actually visits stay permanently on screen and everything else lives
/// one tap further, behind **More**.
///
/// **The home page is never pushed away.** On a tablet it is the detail column's
/// root, so selecting a destination covers it rather than destroying it; on a
/// phone it is a tab root, and `TabView` keeps every tab's view alive. Either
/// way the run (Apply, progress, log) and the launch bootstrap survive a trip to
/// another section.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case tweaks
    case posterBoard
    case media
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .tweaks: "Tweaks"
        // The page calls itself PosterBoard; the tab is named for what a user
        // picks there, because "PosterBoard" means nothing on a phone.
        case .posterBoard: "Wallpapers"
        case .media: "Media"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .tweaks: "slider.horizontal.3"
        case .posterBoard: "photo.artframe"
        case .media: "photo.on.rectangle"
        case .more: "ellipsis.circle"
        }
    }
}

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case tweaks
    case presets
    case community
    case posterBoard
    case templates
    case wallpaperDownloads
    case statusBar
    case wallet
    case passcode
    case media
    case files
    case settings

    var id: String { rawValue }

    func allowed(by policy: HotLoadPolicy) -> Bool {
        switch self {
        case .posterBoard, .wallpaperDownloads: return policy.hiddenFeatures["PosterBoard"] == nil
        case .templates: return policy.hiddenFeatures["Templates"] == nil
        case .statusBar: return policy.hiddenFeatures["Status Bar"] == nil
        case .tweaks: return !["Liquid Glass", "Springboard", "Internal"].allSatisfy { policy.hiddenFeatures[$0] != nil }
        default: return true
        }
    }

    /// Whether the shells may offer this destination at all.
    ///
    /// Two questions in one place, because both shells ask both: the HotLoad
    /// policy can hide a feature for a device/version pair, and Airlift's
    /// availability gate makes the two RemotePairing-dependent pages pointless
    /// on a device that cannot use them. A row that opens a page saying "not
    /// available" is worse than no row.
    func isAvailable(policy: HotLoadPolicy, device: DeviceIdentity) -> Bool {
        guard allowed(by: policy) else { return false }
        if self == .wallet || self == .passcode {
            return !AirliftAvailability.isHidden(deviceVersion: device.version,
                                                 buildVersion: device.buildVersion)
        }
        return true
    }

    /// The phone tab this destination is the root of, if it is one.
    ///
    /// Four pages earn a tab: the two the app exists for (home, which carries
    /// Apply, and Tweaks), the wallpaper page — the other half of what Apply
    /// delivers — and Media. Everything else is one tap further, behind More.
    var tab: AppTab? {
        switch self {
        case .home: .home
        case .tweaks: .tweaks
        case .posterBoard: .posterBoard
        case .media: .media
        default: nil
        }
    }

    /// Whether this destination gets a row of its own in the tablet's sidebar.
    ///
    /// The wallpaper downloader is the one that does not.  It is a **sub-page of
    /// PosterBoard**, not a section of its own: it edits the very selection the
    /// PosterBoard page shows and the home page's `Apply` delivers, so a second
    /// entry point to it in the sidebar is a duplicate row one level above the
    /// page that owns it, and the page it duplicates is the one whose contents
    /// (`Wallpaper packs`) it fills.  `PosterBoardView` pushes it with a
    /// `NavigationLink` in that section, which is also where the desktop build
    /// reaches its downloader from (`wallpaper_downloader.py`).
    var showsInSidebar: Bool { self != .wallpaperDownloads }

    /// Whether the phone's **More** list offers this destination.
    ///
    /// Exactly the pages that are not tabs, minus the wallpaper downloader for
    /// the same reason it has no sidebar row.
    var isInMoreMenu: Bool { tab == nil && showsInSidebar }

    var title: String {
        switch self {
        case .home: "GoldenNugget"
        case .tweaks: "Tweaks"
        case .presets: "Presets"
        case .community: "Community Catalog"
        case .posterBoard: "PosterBoard"
        case .templates: "Templates"
        case .wallpaperDownloads: "Download Wallpapers"
        case .statusBar: "Status Bar"
        case .wallet: "Wallet"
        case .passcode: "Passcode"
        case .media: "Media"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .tweaks: "slider.horizontal.3"
        case .presets: "tray.2"
        case .community: "square.grid.2x2"
        case .posterBoard: "photo.artframe"
        case .templates: "slider.horizontal.below.rectangle"
        case .wallpaperDownloads: "square.and.arrow.down"
        case .statusBar: "antenna.radiowaves.left.and.right"
        case .wallet: "creditcard.fill"
        case .passcode: "lock.rectangle"
        case .media: "photo.on.rectangle"
        case .files: "folder"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    /// Which shell is showing.  `.compact` is the phone (and an iPad window
    /// narrowed to one), where the tab bar takes over from the sidebar.
    @Environment(\.horizontalSizeClass) private var width
    /// Drives the device-identity poll: read on the way to the foreground, stopped
    /// on the way out.  Owned here because this is the one view that outlives every
    /// destination — a stack replaces its pushed page on each selection, and a
    /// poll bound to a page would stop and restart as the user moves around.
    @Environment(\.scenePhase) private var scenePhase

    /// The one-time setup gate.
    ///
    /// Observed rather than a second `@AppStorage` on the same key: the store is
    /// the flag, so finishing the guide has to lift the gate in the same run that
    /// set it. A mirror would have made the two disagree for exactly one frame —
    /// the frame where the user is looking at the button they just pressed.
    @ObservedObject private var hotload = HotLoadService.shared
    @ObservedObject private var device = DeviceIdentityMonitor.shared

    @ObservedObject private var firstRun = FirstRunSettings.shared

    /// The tablet's detail stack.  The single source of truth for what is
    /// showing: empty means home, which is also why the sidebar's "current" is
    /// `path.last ?? .home`.
    @State private var path: [AppDestination] = []
    /// Regular widths only.  See `regularShell`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// The phone's selected tab.
    @State private var tab: AppTab = .home
    /// The More tab's stack.  Bound (unlike the four page tabs) because the
    /// shell has to be able to push a page into it: `open(_:)` sends Settings
    /// and the rest here from anywhere in the app.
    @State private var morePath: [AppDestination] = []

    /// Owned here, above whichever shell is showing, because the two platforms
    /// disagree about view lifetime and the selection must not depend on which
    /// one is in charge: on a tablet the detail view is replaced on every
    /// selection, and on a phone the tabs are kept alive but the page that edits
    /// it must still outlive the page that applies it.  A selection owned by a
    /// page would be destroyed by the act of walking over to press Apply.
    @State private var tweakSelection = TweakSelection()
    /// The PosterBoard page's selection, hoisted for exactly the same reason and with a
    /// sharper edge: the wallpapers and the reset choice are edited on one page and
    /// delivered by the **Apply on the home page**, so as page state they would be
    /// destroyed by the very act of walking over to press it.
    @State private var posterBoardSelection = PosterBoardSelection()
    /// The status-bar page's selection. Hoisted for the same reason, and for a
    /// stronger one: it is edited on the status bar page and delivered by the
    /// **Apply on the home page**, so as page state it would be destroyed by the
    /// act of walking over to press it.
    @State private var statusBarSelection = StatusBarSelection()
    /// The templates page's selection, hoisted for the same reason.  It is
    /// delivered by the same Apply, and a template's option values are the most
    /// expensive thing on any page to rebuild — a picker and a colour per
    /// template, none of which the device knows anything about.
    @State private var templateSelection = TemplateSelection()
    /// Launch auto-start bookkeeping, hoisted for the same reason as the
    /// selection: the flags guard a process-wide singleton
    /// (`startMinimuxer`'s lock rejects *concurrent* attempts only), so they
    /// have to outlive the view that reads them.  See `GoldenNuggetView`.
    @State private var didAutoStart = false
    /// "Reset pairing file" saying no, and **persisted on purpose**.
    ///
    /// It used to be `@State` alongside `didAutoStart`, which made the reset only
    /// half-work: `resetPairing()` cleared the record in memory and in
    /// `UserDefaults` but left `Documents/pairingfile.mobiledevicepairing` in
    /// place, and the restore path reads that file *first*.  So the next launch
    /// — which started again from "the user has not said no" — picked the
    /// record straight back up and re-paired a device the user had just
    /// unpaired, with nothing in the log to say why.
    ///
    /// Persisting the flag makes the reset stick without **deleting** anything:
    /// the record stays on disk untouched, and only the automatic load of it is
    /// suppressed.  That is deliberate — the pairing file may be the user's only
    /// copy, and a button labelled "Reset pairing file" must not destroy it.
    /// A successful import clears the flag again (see `loadPairingFile`), so
    /// importing after a reset restores the normal launch behaviour.
    @AppStorage(PairingRecord.Key.autoImportDisabled) private var autoImportDisabled = false

    var body: some View {
        Group {
            // The gate, not a sheet and not a pushed page: the app cannot do
            // anything at all until both prerequisites are in place, so the shell
            // behind it would be a menu of things that each fail identically.
            // A sheet would leave that same shell one swipe away.
            if hotload.currentPolicy.gateReason != nil {
                HotLoadGateView(policy: hotload.currentPolicy)
            } else if firstRun.isComplete {
                if width == .compact { compactShell } else { regularShell }
            } else {
                FirstRunView()
            }
        }
        // One way for any page to reach another, whichever shell is showing.
        // Provided above the shells so a page pressed in either one asks the
        // shell, not a hardcoded `NavigationLink` that would push a second copy
        // of a page which already owns a tab.
        .environment(\.openDestination, open)
        // The native screens resolve every colour and text style from the system,
        // so the app follows the device appearance.
        // The device line and the version bounds it gates refresh themselves, and
        // the two ends of the app's life are the moments that matter: coming back
        // from the background is when a rebooted or swapped device is most stale,
        // and going out is when nothing should be talking to lockdown at all.
        // `.task(id:)` rather than an `onChange` because the id covers the first
        // appearance too — the app opens into `.active` and must start polling
        // without waiting for a change that may never come.
        //
        // The id carries the gate's state as well: while the guide is up there is
        // no pairing and no tunnel, so a lockdown poll can only log a device that
        // is not there yet — and finishing the guide has to start it, which a
        // scenePhase-only id would not notice until the next foreground.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            async let rules: Void = hotload.refresh(force: false)
            async let update: Void = AppUpdateService.shared.refresh()
            _ = await (rules, update)
        }
        .task(id: firstRun.isComplete ? scenePhase : nil) {
            guard scenePhase == .active, firstRun.isComplete else {
                DeviceIdentityMonitor.shared.stop()
                return
            }
            DeviceIdentityMonitor.shared.start()
        }
        // The imported packs and the two picked files come back at launch, not when the
        // PosterBoard page is first opened: the Apply that delivers them is on the home
        // page, and a selection that is only loaded by *visiting* its editor is a
        // selection that can be missing while the button is pressed.
        .task {
            posterBoardSelection.loadFromDisk()
            statusBarSelection.loadFromDisk()
            // No device version here on purpose: this runs at launch, possibly
            // before the tunnel is up, and a template that declares a version
            // range would then be dropped for the whole session.  The Templates
            // page re-reads with the version once it has one.
            templateSelection.loadFromDisk()
        }
    }

    // MARK: - Compact (iPhone)

    /// The platform's tab bar: four page tabs and one More list.
    ///
    /// Each tab owns a `NavigationStack`, so the page's own title bar and any
    /// sub-page it pushes (`PosterBoard` → `Download Wallpapers`) stay inside the
    /// tab instead of replacing the tab bar. The four page stacks keep their own
    /// path internally — `TabView` keeps the views alive, so a page the user
    /// pushed is still there after a detour — and only More's path is bound,
    /// because that is the one the shell pushes into itself.
    @ViewBuilder
    private var compactShell: some View {
        TabView(selection: $tab) {
            Tab(value: AppTab.home) {
                stack { homePage }
            } label: {
                Label(AppTab.home.title, systemImage: AppTab.home.systemImage)
            }
            Tab(value: AppTab.tweaks) {
                stack { page(for: .tweaks) }
            } label: {
                Label(AppTab.tweaks.title, systemImage: AppTab.tweaks.systemImage)
            }
            Tab(value: AppTab.posterBoard) {
                stack { page(for: .posterBoard) }
            } label: {
                Label(AppTab.posterBoard.title, systemImage: AppTab.posterBoard.systemImage)
            }
            Tab(value: AppTab.media) {
                stack { page(for: .media) }
            } label: {
                Label(AppTab.media.title, systemImage: AppTab.media.systemImage)
            }
            Tab(value: AppTab.more) {
                NavigationStack(path: $morePath) {
                    MoreView()
                        .navigationDestination(for: AppDestination.self) { page(for: $0) }
                }
            } label: {
                Label(AppTab.more.title, systemImage: AppTab.more.systemImage)
            }
        }
    }

    /// A tab's stack, with the destination routes every stack needs.
    ///
    /// The routes are attached to each stack rather than to one: a page that
    /// pushes another (`PosterBoard` → `Download Wallpapers`) must resolve it in
    /// its own stack, and a stack without the routes would push an empty page.
    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationDestination(for: AppDestination.self) { page(for: $0) }
        }
    }

    // MARK: - Regular (iPad)

    /// A tablet, where the two columns genuinely fit and the split view earns its
    /// keep: it survives a window a third of the screen by itself, which a plain
    /// stack cannot.
    ///
    /// `.prominentDetail` is what makes the sidebar start out of the way. The
    /// binding alone did not: `.detailOnly` is only the *preference*, and the
    /// style decides what is presented at launch.
    @ViewBuilder
    private var regularShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppDestinationList(current: path.last ?? .home) { destination in
                path = destination == .home ? [] : [destination]
                // Picking a destination from a sidebar that is showing over the
                // detail would otherwise leave it covering the page just chosen,
                // which is the opposite of what a tap on a list means.  Reachable
                // again from the system's toggle and the edge swipe.
                if columnVisibility != .detailOnly { columnVisibility = .detailOnly }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                homePage
                    .navigationDestination(for: AppDestination.self) { page(for: $0) }
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
    }

    // MARK: - Pages

    /// The home page, as both shells' root.  The order of the arguments is the
    /// explicit initializer's, not the property declaration order.
    private var homePage: some View {
        GoldenNuggetView(tweakSelection: $tweakSelection,
                         posterBoardSelection: $posterBoardSelection,
                         statusBarSelection: $statusBarSelection,
                         templateSelection: $templateSelection,
                         didAutoStart: $didAutoStart,
                         autoImportDisabled: $autoImportDisabled)
    }

    /// One destination → its page.  Used by every stack, including the tab roots,
    /// so a feature the HotLoad policy hides says so in place of the page rather
    /// than disappearing from a tab bar that cannot hide it.
    @ViewBuilder
    private func page(for destination: AppDestination) -> some View {
        if !destination.allowed(by: hotload.currentPolicy) {
            ContentUnavailableView("Feature unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("This feature is hidden by HotLoad safety "
                                                     + "rules. See Settings for rule status."))
        } else {
            switch destination {
            case .home:
                // Unreachable: home is every stack's root, so a path never
                // carries it.  The switch still has to be exhaustive.
                EmptyView()
            case .tweaks:
                TweaksView(selection: $tweakSelection)
            case .presets:
                PresetManagerView(selection: $tweakSelection)
            case .community:
                CommunityCatalogView()
            case .posterBoard:
                PosterBoardView(selection: $posterBoardSelection)
            case .templates:
                TemplatesView(selection: $templateSelection)
            case .wallpaperDownloads:
                WallpaperDownloadsView(selection: $posterBoardSelection)
            case .statusBar:
                StatusBarView(selection: $statusBarSelection)
            case .wallet:
                WalletView()
            case .passcode:
                PasscodeThemeView()
            case .media:
                MediaView()
            case .files:
                FilesView()
            case .settings:
                SettingsView()
            }
        }
    }

    /// Send the user to a page from anywhere: a tab on a phone, a push on a
    /// tablet.
    ///
    /// The home page uses this for its Media row. As a `NavigationLink` it would
    /// have pushed a second copy of the Media page inside the home tab — a page
    /// that owns a tab of its own — so on a phone the row would look like it
    /// worked while the tab bar still pointed at Home.
    private func open(_ destination: AppDestination) {
        guard width == .compact else {
            path = destination == .home ? [] : [destination]
            return
        }
        if let target = destination.tab {
            tab = target
        } else {
            // Everything else lives behind More, which owns the stack these
            // pages are pushed onto.
            tab = .more
            morePath = [destination]
        }
    }
}

/// Carries `RootView`'s page-switching action down the view tree.
///
/// A closure rather than a binding to the tab or the path: a page may ask to
/// show another page, never to decide how the shell gets there.
private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (AppDestination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openDestination: (AppDestination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

/// The phone's fifth tab: every page that is not a tab, one tap from the bar.
///
/// It exists because a tab bar holds five items and the four page tabs are
/// spoken for. Grouping is the reason it is a list of sections rather than a
/// flat dump of nine rows: the sections say what kind of thing each page
/// changes, and a reader who does not recognize a name can still guess where it
/// belongs.
private struct MoreView: View {
    @ObservedObject private var hotload = HotLoadService.shared
    @ObservedObject private var device = DeviceIdentityMonitor.shared

    /// The sections in display order, with the pages that belong to each.
    private static let sections: [(title: String, pages: [AppDestination])] = [
        ("Library", [.presets, .community, .templates]),
        ("Personalize", [.statusBar, .wallet, .passcode]),
        ("Device", [.files]),
        ("App", [.settings]),
    ]

    var body: some View {
        List {
            // A section whose every row is hidden disappears with its rows: a
            // header over nothing reads like a bug, and the HotLoad policy can
            // hide a whole group at once.
            ForEach(Self.sections, id: \.title) { section in
                let pages = section.pages.filter {
                    $0.isAvailable(policy: hotload.currentPolicy, device: device.current)
                }
                if !pages.isEmpty {
                    Section(section.title) {
                        ForEach(pages) { destination in
                            NavigationLink(value: destination) {
                                Label(destination.title, systemImage: destination.systemImage)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The list of destinations, used as the tablet's sidebar column.
///
/// A `List` of buttons rather than a `List` of `NavigationLink`s, because the
/// selection target is a `NavigationStack` *path* in the other column, not the
/// split view's own: a link would push onto this list and replace it.
private struct AppDestinationList: View {
    @ObservedObject private var hotload = HotLoadService.shared
    @ObservedObject private var device = DeviceIdentityMonitor.shared
    let current: AppDestination
    let select: (AppDestination) -> Void

    var body: some View {
        List {
            // Filtered, not a hardcoded list: `allCases` is the enum's own
            // exhaustiveness check, and dropping the row in `showsInSidebar`
            // keeps the "every destination needs a title and an icon" obligation
            // on the enum while letting one of them stay reachable only from the
            // page that owns it.
            ForEach(AppDestination.allCases.filter { destination in
                destination.showsInSidebar
                    && destination.isAvailable(policy: hotload.currentPolicy, device: device.current)
            }) { destination in
                Button { select(destination) } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                        .fontWeight(destination == current ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(destination == current
                                   ? Color.accentColor.opacity(0.15)
                                   : Color.clear)
            }
        }
        .listStyle(.sidebar)
    }
}
