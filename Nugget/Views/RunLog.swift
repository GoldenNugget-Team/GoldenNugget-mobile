import Foundation
import SwiftUI

/// The run log, as an observable store rather than as page state.
///
/// It used to be `@State private var logs: [String]` **on `GoldenNuggetView`**,
/// with `AppLog`'s UI handler appending to it once per line.  One log line
/// therefore invalidated the whole page: `body` re-evaluated, and with it every
/// computed value inside it — including `mediaDetail`, which read *and JSON-
/// decoded* the media manifest from disk, and `enabledDaemonCount`, which filters
/// `DaemonGroups.all` through `TweakCatalog.byID`.  A run logs hundreds of lines
/// (progress steps, wire census, delegate decisions, retries), so the page
/// re-rendered hundreds of times and touched the disk on each one.  That, not the
/// log drawing itself, is what made a run feel heavy — `TweaksView` had the same
/// shape with its own `tail`.
///
/// The split moves the invalidation to the one card that draws it: a line now
/// re-evaluates `RunLogCard` (a `LazyVStack` over the last 600 lines, inside its
/// own bounded viewport) and nothing else, because no other view reads this
/// store.
///
/// **Appends are coalesced, not queued per line.**  `append` may be called from
/// any thread (the engine's callback arrives on the main queue today, but the
/// store does not depend on that); the first append schedules **one** main-queue
/// flush and every append until that flush lands is merged into it.  A burst —
/// a backup's delegate chatter, a stalled-transfer dump — costs one main-thread
/// hop instead of one per line, and nothing is dropped.
final class RunLog: ObservableObject {
    static let shared = RunLog()

    /// What the card renders: the last `windowSize` lines, main thread only.
    @Published private(set) var lines: [String] = []

    /// The identity of `lines[0]`, so the log view can key its rows by something
    /// stable.  Keying by array offset (the obvious thing) makes every row's
    /// identity shift by one each time the window slides, and SwiftUI then
    /// re-creates all 600 rows instead of reusing them — once per appended line,
    /// which is exactly the tail end of a long run.
    @Published private(set) var firstLineId = 0

    /// Lines waiting for the next flush.  Deliberately *not* `@Published`: a
    /// write to it must not invalidate a view.  Guarded by `lock`.
    private var pending: [String] = []
    /// Whether a flush is already scheduled, so a burst schedules exactly one.
    private var flushScheduled = false
    private let lock = NSLock()

    /// The same window the old `if logs.count > 600 { removeFirst }` kept.
    private let windowSize = 600

    private init() {}

    /// Append a line.  Safe from any thread; never invalidates a view directly.
    func append(_ line: String) {
        lock.lock()
        pending.append(line)
        let needsFlush = !flushScheduled
        flushScheduled = needsFlush
        lock.unlock()
        guard needsFlush else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    /// Drop everything, for the start of a run.  Main thread.
    func clear() {
        lock.lock()
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        if !lines.isEmpty { lines.removeAll() }
    }

    /// Publish everything buffered so far, trimmed to the window.  Main thread.
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > windowSize {
            let dropped = lines.count - windowSize
            lines.removeFirst(dropped)
            firstLineId += dropped
        }
    }
}

/// The log card — the **only** view that observes `RunLog`.
///
/// The section used to be gated by the page (`if !logs.isEmpty { logSection }`),
/// which meant the page had to read the log to decide, i.e. to be invalidated by
/// it.  The gate lives here instead, so an empty log costs an empty view and a
/// busy one costs this card.
///
/// **The log scrolls inside itself.**  The rows used to be laid out straight into
/// the page's `List`, all 600 of them, which made the log taller than the
/// screen and pushed every card below it — the Apply button, the status line —
/// off the bottom, so reading the run meant scrolling the whole page past the
/// controls.  A bounded viewport with its own `ScrollView` fixes that, and has to
/// come with tailing: a run appends hundreds of lines in a few seconds, and a log
/// that stays at the top while it grows is no more readable than one that is
/// buried.  So it follows the newest line until the reader scrolls away from the
/// end, and offers a way back.
struct RunLogCard: View {
    @ObservedObject private var log = RunLog.shared
    /// Whether the viewport is parked at the newest line.
    ///
    /// Driven by the scroll geometry rather than by "did the user touch it": a
    /// drag that lands back at the end has to keep following, and a run that
    /// appends while the reader is halfway up must not yank them down.
    @State private var followsTail = true

    /// How tall the viewport is.  A phone's worth of about fifteen log lines —
    /// enough to read a step and its neighbours, small enough that the card stays
    /// a card.
    private static let viewportHeight: CGFloat = 200
    /// The tail marker, scrolled to instead of the last row: an `.id` on the last
    /// row aligns that row's *top* with the viewport's top edge, which leaves the
    /// newest line half off the bottom.
    private static let tail = "runlog.tail"

    var body: some View {
        if !log.lines.isEmpty {
            Section("Log") {
                viewport
            }
        }
    }

    private var viewport: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.id) { row in
                        Text(row.text)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id(Self.tail)
                }
                .padding(.vertical, 2)
            }
            .frame(height: Self.viewportHeight)
            // The indicator is the page's, not the log's: two nested ones is one
            // too many, and the page's says where the log sits in the whole.
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottomTrailing) {
                // Only while parked away from the end, and over the log rather
                // than under it, so it cannot push the card taller.
                if !followsTail {
                    Button {
                        followsTail = true
                        proxy.scrollTo(Self.tail, anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down.to.line.compact")
                            .font(.caption2.bold())
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thickMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            // Tailing is one hop behind an append, not one per line: the store
            // already coalesces a burst into a single `lines` change.
            .onChange(of: log.lines.count) { _, _ in
                guard followsTail else { return }
                proxy.scrollTo(Self.tail, anchor: .bottom)
            }
            .onChange(of: log.firstLineId) { _, _ in
                // The window slid, so the row ids moved and the viewport's
                // offset no longer means anything. Only matters when the reader
                // is parked somewhere: at the tail the offset is already
                // bottom-anchored.
                guard !followsTail else { return }
                proxy.scrollTo(Self.tail, anchor: .bottom)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // A row's slack: `contentSize` is the laid-out height, so the last
                // row is fully visible a few points before the geometry says
                // "at the end".
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { atEnd, _ in
                if followsTail, !atEnd { followsTail = false }
                else if !followsTail, atEnd { followsTail = true }
            }
            .task {
                // A log that was already full when this page appeared — the user
                // came back mid-run — opens at the end rather than at line one.
                guard followsTail else { return }
                proxy.scrollTo(Self.tail, anchor: .bottom)
            }
        }
    }

    /// Row identity is `firstLineId + offset`, the stable key the store exposes,
    /// rather than the array offset — see `RunLog.firstLineId`.
    private var rows: [(id: Int, text: String)] {
        log.lines.enumerated().map { (log.firstLineId + $0.offset, $0.element) }
    }
}
