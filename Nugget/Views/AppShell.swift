import SwiftUI
import UIKit

/// The app's shell: a sidebar next to a detail column.
///
/// It is a `NavigationSplitView` on purpose, and the reason is the iPad itself —
/// this app runs in a window whose width the system picks (Slide Over 320,
/// Split View, iPadOS 26's free resizing), so the navigation has to survive a
/// window that is a third of the screen.  A split view does that **by itself**:
/// in a compact width it collapses to one column with the sidebar reachable from
/// the detail's bar, and in a regular width both columns are on screen at once.
/// A plain `NavigationStack` can only do the second of those.
///
/// The home page stays the **root of the detail column** rather than becoming one
/// of the sidebar's selections.  That is what keeps it alive: a split view
/// destroys the detail view when the selection changes, and the home page owns
/// the run (Apply, progress, log) and the launch bootstrap — losing it mid-run
/// would drop the progress and re-run the auto-start.  Selecting a destination
/// pushes onto the detail stack instead, so home is never removed, only covered.
enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case tweaks
    case posterBoard
    case wallpaperDownloads
    case statusBar
    case wallet
    case passcode
    case daemons
    case media
    case files
    case settings

    var id: String { rawValue }

    /// Whether this destination gets a row of its own in the sidebar/menu.
    ///
    /// The wallpaper downloader is the one that does not.  It is a **sub-page of
    /// PosterBoard**, not a section of its own: it edits the very selection the
    /// PosterBoard page shows and the home page's `Apply` delivers, so a second
    /// entry point to it in the sidebar is a duplicate row one level above the
    /// page that owns it, and the page it duplicates is the one whose contents
    /// (`Wallpaper packs`) it fills.  `PosterBoardView` pushes it with a
    /// `NavigationLink` in that section, which is also where the desktop build
    /// reaches its downloader from (`wallpaper_downloader.py`).
    ///
    /// The case itself stays — a destination has to exist to be pushed — only its
    /// row goes, so the two shells (sidebar on a tablet, sheet on a phone) both
    /// stop offering it without either needing to know about the other.
    var showsInSidebar: Bool { self != .wallpaperDownloads }

    var title: String {
        switch self {
        case .home: "GoldenNugget"
        case .tweaks: "Tweaks"
        case .posterBoard: "PosterBoard"
        case .wallpaperDownloads: "Download Wallpapers"
        case .statusBar: "Status Bar"
        case .wallet: "Wallet"
        case .passcode: "Passcode"
        case .daemons: "Daemons"
        case .media: "Media"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .tweaks: "slider.horizontal.3"
        case .posterBoard: "photo.artframe"
        case .wallpaperDownloads: "square.and.arrow.down"
        case .statusBar: "antenna.radiowaves.left.and.right"
        case .wallet: "creditcard.fill"
        case .passcode: "lock.rectangle"
        case .daemons: "server.rack"
        case .media: "photo.on.rectangle"
        case .files: "folder"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    /// Which of the two shells below is in charge.
    ///
    /// `.compact` is the iPhone, and it is the entire reason this view has two
    /// bodies instead of one.
    @Environment(\.horizontalSizeClass) private var width
    /// Drives the device-identity poll: read on the way to the foreground, stopped
    /// on the way out.  Owned here because this is the one view that outlives every
    /// destination — the split view replaces the detail on each selection, and a
    /// poll bound to a page would stop and restart as the user moves around.
    @Environment(\.scenePhase) private var scenePhase

    /// The one-time setup gate.
    ///
    /// Observed rather than a second `@AppStorage` on the same key: the store is
    /// the flag, so finishing the guide has to lift the gate in the same run that
    /// set it. A mirror would have made the two disagree for exactly one frame —
    /// the frame where the user is looking at the button they just pressed.
    @ObservedObject private var firstRun = FirstRunSettings.shared

    /// The detail stack.  The single source of truth for what is showing: empty
    /// means home, which is also why the menu's "current" is `path.last ?? .home`
    /// and there is no second variable to keep in sync.
    @State private var path: [AppDestination] = []
    /// Regular widths only.  See `regular`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The compact shell's menu, presented as a sheet.
    @State private var menuPresented = false

    /// Owned here, above whichever shell is showing, because two columns need it at
    /// once: the home page counts and applies it, and Tweaks/Daemons edit it.  It
    /// was `@State` on the home page, which worked only while that page was the one
    /// thing in the hierarchy — a split view replaces the detail on every selection
    /// change, and the selection would have gone with it.
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
            if firstRun.isComplete {
                if width == .compact { compactShell } else { regularShell }
            } else {
                FirstRunView()
            }
        }
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
        }
    }

    // MARK: - Compact (iPhone)

    /// A plain stack with the menu in a sheet, because a split view cannot do this
    /// job in one column.
    ///
    /// In a compact width a `NavigationSplitView` shows its **first** column at
    /// launch and pushes the second on top. The first column is the sidebar, so
    /// the app opens on a menu with Home buried behind it — and no amount of
    /// `columnVisibility` changes that: with room for one column there is nothing
    /// to select between, and `.detailOnly` and `.prominentDetail` are both
    /// dropped on the floor. Reversing the columns would fix the launch and put
    /// the menu on the *right* in a regular width, which is worse.
    ///
    /// So the split view stays where it works — a tablet — and the phone gets the
    /// arrangement the phone idiom is built on: content at the root, menu behind a
    /// burger. It also settles the leading controls: a sheet cannot leave a
    /// back-chevron behind, so there is exactly one button at the top left instead
    /// of the system's toggle and a custom burger arguing over the same slot.
    @ViewBuilder
    private var compactShell: some View {
        NavigationStack(path: $path) {
            detail
        }
        .environment(\.showSidebar) { menuPresented = true }
        .sheet(isPresented: $menuPresented) {
            NavigationStack {
                AppDestinationList(current: path.last ?? .home) { destination in
                    menuPresented = false
                    path = destination == .home ? [] : [destination]
                }
                .navigationTitle("GoldenNugget")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { menuPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
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
            NavigationStack(path: $path) { detail }
        }
        .navigationSplitViewStyle(.prominentDetail)
    }

    /// The pages, shared by both shells.  The order of the arguments is the
    /// explicit initializer's, not the property declaration order.
    @ViewBuilder
    private var detail: some View {
        GoldenNuggetView(tweakSelection: $tweakSelection,
                         posterBoardSelection: $posterBoardSelection,
                         statusBarSelection: $statusBarSelection,
                         didAutoStart: $didAutoStart,
                         autoImportDisabled: $autoImportDisabled)
            .navigationDestination(for: AppDestination.self) { destination in
                switch destination {
                case .home:
                    // Unreachable: home is the stack's root, so the path never
                    // carries it.  The switch still has to be exhaustive.
                    EmptyView()
                case .tweaks:
                    TweaksView(selection: $tweakSelection)
                case .posterBoard:
                    PosterBoardView(selection: $posterBoardSelection)
                case .wallpaperDownloads:
                    WallpaperDownloadsView(selection: $posterBoardSelection)
                case .statusBar:
                    StatusBarView(selection: $statusBarSelection)
                case .wallet:
                    WalletView()
                case .passcode:
                    PasscodeThemeView()
                case .daemons:
                    DaemonsView(selection: $tweakSelection)
                case .media:
                    MediaView()
                case .files:
                    FilesView()
                case .settings:
                    SettingsView()
                }
            }
    }
}

/// Carries the menu-opening action down to the pages that draw the burger.
///
/// A closure and not a `Bool`: the pages must not be able to *set* the menu's
/// visibility, only ask for it.  `defaultValue` is a no-op rather than a crash so
/// a page previewed or rendered outside the shell draws its bar instead of
/// trapping.
private struct ShowSidebarKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showSidebar: () -> Void {
        get { self[ShowSidebarKey.self] }
        set { self[ShowSidebarKey.self] = newValue }
    }
}

/// Puts the burger in the bar, but only where the system draws no toggle itself.
///
/// In a regular width the split view's prominent-detail style already puts a
/// sidebar toggle in the leading slot, and that is the one that is correct: it
/// agrees with the system about whether the column is up, and it comes with the
/// edge swipe. A hand-rolled button next to it is where the duplicate leading
/// controls came from.
///
/// A `ViewModifier` struct rather than a bare `View` extension because reading
/// `@Environment` needs somewhere to hang it; an extension method on `View` has
/// no `self` to hold the property wrapper.
struct GoldenSidebarButton: ViewModifier {
    @Environment(\.showSidebar) private var showSidebar
    @Environment(\.horizontalSizeClass) private var width

    @ViewBuilder
    func body(content: Content) -> some View {
        if width == .compact {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showSidebar) {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Menu")
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func goldenSidebarButton() -> some View { modifier(GoldenSidebarButton()) }
}

/// The list of destinations, used as the sidebar column in a regular width and as
/// the sheet's contents in a compact one.
///
/// A `List` of buttons rather than a `List` of `NavigationLink`s, because the
/// selection target is a `NavigationStack` *path* in the other column, not the
/// split view's own: a link would push onto this list and replace it.
private struct AppDestinationList: View {
    let current: AppDestination
    let select: (AppDestination) -> Void

    var body: some View {
        List {
            // Filtered, not a hardcoded list: `allCases` is the enum's own
            // exhaustiveness check, and dropping the row in `showsInSidebar`
            // keeps the "every destination needs a title and an icon" obligation
            // on the enum while letting one of them stay reachable only from the
            // page that owns it.
            ForEach(AppDestination.allCases.filter(\.showsInSidebar)) { destination in
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
