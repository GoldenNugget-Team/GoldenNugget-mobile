import CryptoKit
import Foundation
import ImageIO
import UIKit

/// One downloadable wallpaper, normalised across both community sources.
///
/// The reference's `wallpaper_api.Wallpaper`, field for field: the two catalogs
/// disagree on almost everything (`authors` vs `creator`, `url` vs `file`, an
/// embedded `base_url` vs a fixed one), so the dataclass is the boundary where
/// that stops mattering.  `description` is carried but not shown — the desktop
/// card is preview, name and author, and neither catalog's text is reliably
/// worth a fourth line on a phone card.
struct Wallpaper: Identifiable, Hashable, Sendable {
    let name: String
    let author: String
    let details: String
    let previewURL: URL?
    let downloadURL: URL
    /// `WallpaperSource`'s raw value, so a merged list can still say where an
    /// entry came from and the "All" merge can prefer one source over the other.
    let sourceID: String

    /// The download URL, which is unique per wallpaper within a catalog.
    ///
    /// Not the name: "All" deliberately shows one entry per name, but a single
    /// source can list the same pack twice under two files, and two cards with
    /// the same identity in one `LazyVGrid` is a runtime warning and a row that
    /// renders wrong.
    var id: String { downloadURL.absoluteString }

    /// What a card shows under the name. Empty when the catalog has no author,
    /// which is most of CaPlayground's entries.
    var byline: String { author.isEmpty ? sourceLabel : author }

    var sourceLabel: String {
        WallpaperSource(rawValue: sourceID)?.label ?? sourceID
    }
}

/// The catalog sources the desktop dialog offers.
///
/// `all` is not a source in the reference either — it is the dialog's own
/// dropdown value, and `_fetch_wallpapers` expands it into the two real ids with
/// Cowabunga pinned to its `Custom` category.  Expanding it here instead means
/// the view has no special case for it.
enum WallpaperSource: String, CaseIterable, Identifiable, Sendable {
    case all
    case cowabunga
    case caplayground

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .cowabunga: "Cowabunga"
        case .caplayground: "CaPlayground"
        }
    }

    /// Cowabunga splits its catalog per category; CaPlayground serves one file
    /// for everything, which is why the reference disables the category dropdown
    /// rather than hiding it (`_populate_categories`).
    var categories: [WallpaperCategory] {
        self == .cowabunga ? WallpaperCategory.allCases : []
    }

    /// What a single fetch of this source asks for.
    ///
    /// `all` expands to two requests — Cowabunga `Custom` first, so the merge's
    /// name dedup lets it win, exactly as `_fetch_wallpapers` does.
    var requests: [(source: WallpaperSource, category: WallpaperCategory?)] {
        switch self {
        case .all: [(.cowabunga, .custom), (.caplayground, nil)]
        case .cowabunga: [(.cowabunga, nil)]
        case .caplayground: [(.caplayground, nil)]
        }
    }
}

/// Cowabunga's two published categories (`wallpaper_api.COWABUNGA_CATEGORIES`).
enum WallpaperCategory: String, CaseIterable, Identifiable, Sendable {
    case custom = "Custom"
    case apple = "Apple"

    var id: String { rawValue }

    /// What the dropdown shows. The label and the file's own category name are the
    /// same string in the reference's mapping, so there is nothing to translate;
    /// `label` exists so both pickers in the view read the same way.
    var label: String { rawValue }

    /// The file name behind the label, from the reference's mapping.
    var fileName: String {
        switch self {
        case .custom: "wallpapers-custom.json"
        case .apple: "wallpapers-apple.json"
        }
    }
}

/// The catalog fetch, the on-disk cache and the `.tendies` download.
///
/// The reference splits this over `controllers/wallpaper_api.py` (catalogs,
/// cache paths, `download_file`) and the dialog itself (concurrency, progress,
/// the merge).  What is here is the same split: everything a view needs to draw
/// a catalog lives here, and the view owns only what it is a view's job to own —
/// which cards are on screen, what is downloading, what the user typed.
///
/// Nothing in this file knows about the device.  A wallpaper is a file that gets
/// imported into this app's container; delivering it to the phone is
/// PosterBoard's job and happens on its own page.
enum WallpaperCatalog {
    /// The SerStars/nugget-wallpapers repo behind cowabun.ga and Pocket Poster.
    static let cowabungaBase = "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/"

    /// The CAPlayground/wallpapers repo behind the CaPlayground site. One file,
    /// and it embeds its own `base_url` for the relative `file`/`preview` paths.
    static let caplaygroundJSON =
        "https://raw.githubusercontent.com/CAPlayground/wallpapers/main/wallpapers.json"

    /// How long a cached catalog is served without asking the network again
    /// (`CATALOG_TTL`). Fifteen minutes: long enough that coming back to the page
    /// is instant, short enough that a newly published pack shows up on a shift.
    static let catalogTTL: TimeInterval = 15 * 60

    /// Previews fetched at once (`PREVIEW_CONCURRENCY`).
    ///
    /// The cap is the reference's and for the reference's reason: a fast scroll
    /// through a few hundred cards would otherwise queue hundreds of image
    /// requests, and the connection they share is the same one the `.tendies`
    /// download needs.
    static let previewConcurrency = 10

    static var session: URLSession { .shared }

    // MARK: - Cache

    /// `{Caches}/wallpaper_cache`, with the two subdirectories the reference
    /// creates up front (`wallpaper_cache_root`).
    ///
    /// Caches and not Documents: these are re-downloadable, and iOS is entitled
    /// to reclaim them under pressure.  A reclaimed preview costs one request.
    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("wallpaper_cache", isDirectory: true)
        for sub in ["catalog", "previews"] {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        return root
    }

    /// `<source>_<md5(category)>.json` — the reference's `_catalog_cache_path`,
    /// hash and all.  The category is hashed rather than sanitised into the name
    /// because the reference hashes it, and a cache written by either build has
    /// to be readable by the other.
    static func catalogCacheURL(source: WallpaperSource, category: WallpaperCategory?) -> URL {
        let key = md5Hex(category?.rawValue ?? "")
        return cacheRoot.appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("\(source.rawValue)_\(key).json")
    }

    /// Where a preview lives, `previews/<md5(url)>.gif` (`cached_preview_path`).
    ///
    /// The `.gif` extension is the reference's and is kept deliberately: these
    /// files really are GIFs, several of them animated, and the extension is what
    /// makes them openable by drag-and-drop out of the container.
    static func previewCacheURL(for url: URL) -> URL {
        cacheRoot.appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent(md5Hex(url.absoluteString) + ".gif")
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Catalog

    /// What a load produced: the wallpapers, and whatever failed on the way.
    ///
    /// A partial list is the normal case for "All", not an error — the reference
    /// keeps whichever source answered and reports the other's failure in the
    /// status line.  Collapsing that to one `Result` would mean a CaPlayground
    /// outage hides Cowabunga too.
    struct Load: Sendable {
        let wallpapers: [Wallpaper]
        let failures: [String]
        /// Whether the answer came from the cache rather than the network.
        let fromCache: Bool
    }

    /// Fetch (or read) one source's catalog.
    ///
    /// Cache first, then network, and the raw bytes are cached **before** being
    /// parsed — so a catalog whose shape this build cannot parse still costs one
    /// request per TTL instead of one per visit.  That is the reference's order
    /// in `_fetch_wallpapers`.
    static func fetch(source: WallpaperSource, category: WallpaperCategory?) async throws -> Load {
        let cacheURL = catalogCacheURL(source: source, category: category)
        if let cached = try? Data(contentsOf: cacheURL),
           let modified = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
           Date().timeIntervalSince(modified) < catalogTTL,
           let wallpapers = try? parse(cached, source: source) {
            return Load(wallpapers: wallpapers, failures: [], fromCache: true)
        }

        let url = try catalogURL(source: source, category: category)
        var request = URLRequest(url: url)
        // GitHub's raw host answers a conditional request with 304, and the
        // catalog is a few hundred kilobytes of JSON — worth the header even
        // though the TTL means this path is rare.
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoldenNuggetError("\(source.label) answered HTTP \(http.statusCode) for its catalog")
        }
        try? data.write(to: cacheURL, options: .atomic)
        return Load(wallpapers: try parse(data, source: source), failures: [], fromCache: false)
    }

    /// The file a source's catalog lives in.
    ///
    /// Cowabunga only publishes a category file when a category is named — which
    /// is why `fetch(source: .cowabunga, category: nil)` (the "All" expansion
    /// passes a category, the single-source path does not) is a caller error the
    /// reference raises too (`fetch_url`: `Unknown category`).
    static func catalogURL(source: WallpaperSource,
                           category: WallpaperCategory?) throws -> URL {
        switch source {
        case .cowabunga:
            guard let category else {
                throw GoldenNuggetError("Cowabunga publishes its catalog per category; "
                    + "pick Custom or Apple.")
            }
            guard let url = URL(string: cowabungaBase + category.fileName) else {
                throw GoldenNuggetError("Cowabunga's catalog URL is malformed")
            }
            return url
        case .caplayground:
            guard let url = URL(string: caplaygroundJSON) else {
                throw GoldenNuggetError("CaPlayground's catalog URL is malformed")
            }
            return url
        case .all:
            throw GoldenNuggetError("'All' is not a catalog; it expands to the two sources")
        }
    }

    /// Parse a fetched catalog into the normalised shape.
    ///
    /// Both parsers, because the two payloads are genuinely different documents:
    /// Cowabunga's is a flat array keyed `name`/`authors`/`url`/`preview`, while
    /// CaPlayground's is an object with `base_url` and a `wallpapers` array keyed
    /// `name`/`creator`/`file`/`preview`.  A relative `url`/`file`/`preview` is
    /// resolved against that base — Cowabunga's fixed one, CaPlayground's own.
    static func parse(_ data: Data, source: WallpaperSource) throws -> [Wallpaper] {
        let object = try JSONSerialization.jsonObject(with: data)
        switch source {
        case .cowabunga:
            guard let items = object as? [[String: Any]] else {
                throw GoldenNuggetError("Cowabunga's catalog is not a list of wallpapers")
            }
            return items.compactMap { item in
                wallpaper(item: item,
                          authorKey: "authors",
                          downloadKey: "url",
                          base: URL(string: cowabungaBase),
                          source: source)
            }
        case .caplayground:
            // A dict carries `base_url`; a bare array falls back to Cowabunga's
            // base, which is what the reference does for either shape.
            let base = (object as? [String: Any])
                .flatMap { $0["base_url"] as? String }
                .flatMap(URL.init(string:)) ?? URL(string: cowabungaBase)
            let entries = (object as? [String: Any])?["wallpapers"] as? [[String: Any]]
                ?? (object as? [[String: Any]])
                ?? []
            return entries.compactMap { item in
                wallpaper(item: item,
                          authorKey: "creator",
                          downloadKey: "file",
                          base: base,
                          source: source)
            }
        case .all:
            throw GoldenNuggetError("'All' has no catalog of its own to parse")
        }
    }

    /// One entry from either catalog, or nil when it cannot be downloaded.
    ///
    /// A row with no usable download URL is dropped rather than shown disabled:
    /// neither catalog is hand-curated, and a card that cannot be tapped is a
    /// card the user has to read past to find one that works.
    private static func wallpaper(item: [String: Any], authorKey: String, downloadKey: String,
                                  base: URL?, source: WallpaperSource) -> Wallpaper? {
        guard let raw = item[downloadKey] as? String, !raw.isEmpty,
              let download = resolve(raw, against: base) else { return nil }
        let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Wallpaper(name: (name?.isEmpty == false ? name! : "Untitled"),
                         author: (item[authorKey] as? String) ?? "",
                         details: (item["description"] as? String) ?? "",
                         previewURL: (item["preview"] as? String).flatMap { resolve($0, against: base) },
                         downloadURL: download,
                         sourceID: source.rawValue)
    }

    /// An absolute URL is kept as it is; anything else is joined to the base.
    /// Mirrors the reference's `if not url.startswith("https://")`.
    private static func resolve(_ raw: String, against base: URL?) -> URL? {
        if raw.hasPrefix("https://") { return URL(string: raw) }
        guard let base else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    /// Load a whole selection: every source it expands to, merged.
    ///
    /// The merge is the reference's `_merge_dedupe` — by lowercased name, with
    /// Cowabunga first so it wins a duplicate, because it is the faster of the
    /// two hosts and its metadata is the one the desktop card shows.
    static func load(source: WallpaperSource, category: WallpaperCategory?) async -> Load {
        var merged: [Wallpaper] = []
        var seen: Set<String> = []
        var failures: [String] = []
        var cached = true

        for (requestSource, requestCategory) in source.requests {
            let resolvedCategory = requestCategory ?? (source == .cowabunga ? category : nil)
            do {
                let result = try await fetch(source: requestSource, category: resolvedCategory)
                cached = cached && result.fromCache
                for wallpaper in result.wallpapers {
                    let key = wallpaper.name.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    merged.append(wallpaper)
                }
            } catch {
                failures.append("\(requestSource.label): \(error.localizedDescription)")
            }
        }

        return Load(wallpapers: merged, failures: failures, fromCache: cached && failures.isEmpty)
    }

    // MARK: - Previews

    /// The bytes for a preview: the cached file if it is there, else a download.
    ///
    /// Cached previews have no TTL in the reference and get none here — unlike a
    /// catalog, a preview is addressed by content path and never changes meaning,
    /// so a stale one is still the right picture.
    static func previewData(for url: URL) async -> Data? {
        let destination = previewCacheURL(for: url)
        if let cached = try? Data(contentsOf: destination), !cached.isEmpty {
            return cached
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        try? data.write(to: destination, options: .atomic)
        return data
    }

    /// `previewData` behind the concurrency cap, for a card that just appeared.
    ///
    /// On-demand rather than per-catalog on purpose: these catalogs hold hundreds
    /// of entries, and the reference only ever asks for the previews whose cards
    /// are in the viewport. Fetching all of them would be hundreds of requests for
    /// images nobody scrolls to.
    static func preview(for url: URL) async -> Data? {
        await PreviewGate.shared.withPermit { await previewData(for: url) }
    }

    // MARK: - Download

    /// Fetch the `.tendies` and leave it in a temporary file, ready to import.
    ///
    /// Returns a URL rather than `Data` because a pack is a ZIP holding a video
    /// wallpaper's frames and can be tens of megabytes — the reference streams
    /// it to disk for the same reason (`download_file`).
    ///
    /// The file is in the temporary directory, so the caller owns it: the import
    /// copies what it keeps into `PosterBoardImports`, and anything left behind
    /// is reclaimed by iOS.
    static func download(_ wallpaper: Wallpaper) async throws -> URL {
        let (data, response) = try await session.data(from: wallpaper.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoldenNuggetError("\(wallpaper.name): the server answered HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw GoldenNuggetError("\(wallpaper.name): the download came back empty")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitised(wallpaper.name)).tendies")
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// The reference's `_save_tandie` name filter: alphanumerics, space, dash
    /// and underscore. Anything else in a catalog name is a path character or a
    /// control byte, and this string is about to become a file name.
    static func sanitised(_ name: String) -> String {
        let allowed = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        let trimmed = allowed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return trimmed.isEmpty ? "wallpaper" : trimmed
    }
}

/// Holds preview requests to `WallpaperCatalog.previewConcurrency` at a time.
///
/// The reference does this with a queue in front of `QNetworkAccessManager`
/// (`PREVIEW_CONCURRENCY`, "everything past this waits in a queue so fast long
/// scrolls can't pile up hundreds of background image requests").  The reason it
/// is a gate rather than a task group here is that the callers arrive one card at
/// a time, as cards scroll into view — there is no list to chunk, so the cap has
/// to be a thing tasks wait on.
actor PreviewGate {
    static let shared = PreviewGate()

    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func withPermit<T>(_ body: () async -> T) async -> T {
        if inFlight >= WallpaperCatalog.previewConcurrency {
            await withCheckedContinuation { waiting.append($0) }
        }
        inFlight += 1
        let result = await body()
        inFlight -= 1
        if waiting.isEmpty {
            // Nobody left to hand the permit to.
        } else {
            waiting.removeFirst().resume()
        }
        return result
    }
}

/// A decoded preview: its frames, and how long each one is held.
///
/// The delays live here rather than on the images because a `UIImage` cannot
/// carry one: `UIImage.animatedImage(with:duration:)` builds an animation that
/// plays on a clock of its own, which cannot be paused when a download starts and
/// cannot wait for the card to appear. The reference pauses every preview while a
/// `.tendies` comes down (`_pause_previews`), and a grid of GIFs still spinning
/// through a 40 MB transfer is exactly what makes a phone feel busy when it is.
struct WallpaperFrames {
    let images: [UIImage]
    /// One entry per image: how long that frame is shown, in seconds.
    let delays: [TimeInterval]

    /// The length of one loop. Zero for a still image, which never advances.
    var duration: TimeInterval { delays.reduce(0, +) }

    var isAnimated: Bool { images.count > 1 }

    /// The frame to show `elapsed` seconds into the loop.
    ///
    /// An absolute time rather than a frame counter, so a card that appears
    /// mid-loop starts wherever the animation is instead of restarting — and a
    /// card that scrolls back into view picks the same frame as its neighbour
    /// rather than a second set of them all restarting together.
    func frame(at elapsed: TimeInterval) -> UIImage? {
        guard let first = images.first else { return nil }
        guard isAnimated, duration > 0 else { return first }
        var position = elapsed.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }
        for (index, delay) in delays.enumerated() {
            if position < delay { return images[index] }
            position -= delay
        }
        return first
    }
}

/// Turns preview bytes into frames a card can cycle.
///
/// ImageIO, and downscale-then-decode rather than decode-then-resize: these are
/// wallpaper loops published at phone-and-tablet resolution, and a hundred full
/// size frames of one is tens of megabytes. The caps below are what a card
/// actually shows — a quarter of a phone's width, 24 frames, 260 px on the long
/// edge — and they are what make a screenful of them affordable.
enum WallpaperFrameDecoder {
    /// Longest edge of a decoded frame, in pixels.
    static let maxPixelSize = 260
    /// Frames kept from one animation.
    static let maxFrames = 24
    /// Floor and ceiling on a frame's own delay.
    ///
    /// A GIF with a zero delay plays as fast as the compositor will manage, which
    /// on a scrolling grid reads as a stutter rather than an animation. A second
    /// is the ceiling: the desktop card effectively shows a still for anything
    /// slower, and one frame held that long is not worth a loop.
    static let delayRange: ClosedRange<TimeInterval> = 0.01...1.0

    /// Decode off the main thread: a 24-frame downscale is tens of milliseconds
    /// of ImageIO, which is a visible hitch when ten cards decode at once.
    static func decode(_ data: Data) async -> WallpaperFrames? {
        await Task.detached(priority: .utility) { decodeSync(data) }.value
    }

    static func decodeSync(_ data: Data) -> WallpaperFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary

        var images: [UIImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<min(count, maxFrames) {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                continue
            }
            let delay = delay(of: source, at: index)
            images.append(UIImage(cgImage: cgImage))
            delays.append(delay)
        }
        guard !images.isEmpty else { return nil }
        // A single frame is a still, and a still's duration is zero so
        // `frame(at:)` hands back the same image for every instant.
        if images.count == 1 { delays = [0] }
        return WallpaperFrames(images: images, delays: delays)
    }

    /// One frame's own delay, read from the GIF properties and clamped.
    ///
    /// `Unclamped` first, then the plain value: browsers and ImageIO disagree
    /// about which one is written, and a file with only the clamped field is
    /// common enough that reading only that one leaves a chunk of the catalog
    /// animating at whatever the encoder chose.
    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let fallback: TimeInterval = 0.1
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return fallback }
        let raw = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif[kCGImagePropertyGIFDelayTime] as? Double
            ?? fallback
        return min(max(raw, delayRange.lowerBound), delayRange.upperBound)
    }
}
