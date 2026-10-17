import Foundation
import UIKit

/// Apple Wallet card skins, written straight into Passbook through AirLift.
///
/// A port of AirCard's card tab (`CardItem`, `ImageEngine.prepareAllCardSkins` and
/// `AppViewModel.flashCards`).
///
/// ## Why a card skin cannot go through a backup
///
/// A card's artwork is not a preference. It lives *inside* the pass, at
/// `/var/mobile/Library/Passes/Cards/<id>.pkpass`, which is a Passbook data
/// container — not a manifest domain, so there is nothing to declare and nothing
/// for `mobilebackup2` to carry. Every other feature in this app replaces the
/// device's own files through a protective backup; a card skin is the case where
/// that mechanism has nothing to work with, and AirLift's container write is the
/// only way to reach it.
///
/// ## The cache, and why it has to be invalidated by hand
///
/// Passbook caches a card's rendered layers under `<id>.cache` and
/// `<id>.pkcache`. Writing the artwork is not enough — the cache still holds the
/// old rendering, and Wallet shows *that* until the leaves are gone. The
/// reference overwrites `FrontFace`, `Preview` and `PlaceHolder` with the bytes
/// `corrupted`, which is not a valid cache and makes Passbook re-render. It is a
/// deliberate act of vandalism rather than a deletion, because a delete through
/// this tunnel is not offered by the FFI.
struct WalletCard: Identifiable, Hashable, Codable {
    /// The pass identifier, exactly as Passbook writes it.
    let id: String
    var isSelected = true
    /// The skin as a 1536×969 PNG. Held as `Data` rather than a `UIImage` so a
    /// card list survives a launch without re-decoding, and so the exact bytes
    /// that were previewed are the bytes that get written.
    var imageData: Data?

    var hasImage: Bool { imageData != nil }

    /// Clean an identifier out of a log line, a filename or a paste.
    ///
    /// A port of `CardItem.cleanCardId`, and deliberately strict: it returns nil
    /// for a bare UUID, because the identifiers Passbook logs for "a card was
    /// added" are sometimes a UUID and sometimes a hash, and a UUID would produce
    /// a write to a path that does not exist while looking perfectly plausible.
    static func cleanIdentifier(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if value.contains("/") {
            value = (value as NSString).lastPathComponent
        }
        for ext in [".pkpass", ".cache", ".pkcache"] where value.hasSuffix(ext) {
            value = String(value.dropLast(ext.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard (20...64).contains(value.count), !value.contains("/") else { return nil }
        if value.count == 36, value.filter({ $0 == "-" }).count == 4 {
            return nil
        }
        return value
    }
}

/// Turns one image into the set of files a Wallet card is made of.
enum WalletSkinEngine {
    /// Prepare a card image for storage: normalised, capped, and exactly
    /// 1536×969 — the size Wallet's own preview uses.
    static func prepareForStorage(_ image: UIImage) -> Data? {
        let normalized = normalize(image, maxDimension: 2560)
        return resize(normalized, to: CGSize(width: 1536, height: 969))
    }

    /// Every file name Passbook looks for, at both scales plus the vector forms.
    ///
    /// The four PNG names are the same image written four times on purpose:
    /// `cardBackgroundCombined` is what Wallet shows, `background` and `strip` are
    /// what the lock-screen and notification presentations read, and `diffuse` is
    /// the blurred backdrop. A pass that has only some of them renders with the
    /// stock artwork for the rest, which reads as "it half worked".
    ///
    /// The `.pdf` copies exist for the transit cards (Suica, PASMO, ICOCA), which
    /// are vectors and ignore the raster sizes entirely.
    static func allSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalize(image, maxDimension: 2560)
        var skins: [String: Data] = [:]

        if let threeX = resize(normalized, to: CGSize(width: 1536, height: 969)) {
            for name in ["cardBackgroundCombined@3x.png", "diffuse@3x.png",
                         "background@3x.png", "strip@3x.png"] {
                skins[name] = threeX
            }
        }
        if let twoX = resize(normalized, to: CGSize(width: 1024, height: 646)) {
            for name in ["cardBackgroundCombined@2x.png", "diffuse@2x.png",
                         "background@2x.png", "strip@2x.png"] {
                skins[name] = twoX
            }
        }

        let bounds = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            normalized.draw(in: bounds)
        }
        for name in ["cardBackgroundCombined.pdf", "background.pdf", "strip.pdf"] {
            skins[name] = pdf
        }
        return skins
    }

    /// Fix orientation and cap the long edge.
    ///
    /// A photo straight off the camera is 48 megapixels, and decoding one into a
    /// bitmap is a Jetsam crash rather than a slow render — this is the same
    /// downsample the reference does before anything else touches the pixels.
    static func normalize(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded(.down)),
                            height: max(1, (size.height * scale).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Aspect-fill into a target size, which is what a card background wants.
    static func resize(_ image: UIImage, to targetSize: CGSize) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaled.width) / 2,
                             y: (targetSize.height - scaled.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return rendered.pngData()
    }
}

/// Writing card skins, and finding out which cards exist in the first place.
enum WalletEngine {
    /// Where Passbook keeps the passes, and where it caches their renderings.
    private static var cardsRoot: String { "/var/mobile/Library/Passes/Cards" }

    /// The cache leaves that have to be broken for a new skin to show.
    private static let cacheLeaves = ["FrontFace", "Preview", "PlaceHolder"]

    /// Write one card's skin and invalidate its caches.
    ///
    /// Two writes, deliberately: the artwork first, then the cache vandalism.
    /// Doing them in one pass would leave a window where the new artwork is in
    /// place and the old rendering is still on top of it.
    static func apply(cards: [WalletCard],
                      pairingPath: String,
                      log: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void) async throws {
        let withImages = cards.filter { $0.isSelected && $0.imageData != nil }
        guard !withImages.isEmpty else {
            throw GoldenNuggetError("No card has a skin selected.")
        }

        let total = Double(withImages.count)
        var written = 0
        for (index, card) in withImages.enumerated() {
            let identifier = WalletCard.cleanIdentifier(card.id) ?? card.id
            log("[\(index + 1)/\(withImages.count)] \(identifier)")

            guard let data = card.imageData, let image = UIImage(data: data) else {
                log("  ⚠️ unreadable skin, skipped")
                continue
            }
            let skins = WalletSkinEngine.allSkins(from: image)
            guard !skins.isEmpty else {
                log("  ⚠️ no skin could be generated, skipped")
                continue
            }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("card-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            for (name, bytes) in skins {
                try? bytes.write(to: stage.appendingPathComponent(name))
            }

            do {
                try await Airlift.writeDir(
                    pairingPath: pairingPath,
                    sourceDir: stage.path,
                    targetDir: "\(cardsRoot)/\(identifier).pkpass"
                )
            } catch {
                log("  ❌ artwork: \(error.localizedDescription)")
                continue
            }
            log("  ✅ artwork written (\(skins.count) file(s))")

            do {
                try await invalidateCache(identifier: identifier,
                                          pairingPath: pairingPath)
                log("  ✅ pass cache invalidated")
            } catch {
                // The artwork is already in place; a stale cache is a cosmetic
                // failure the user can clear by force-quitting Wallet, so it is
                // reported and the card still counts.
                log("  ⚠️ cache not invalidated: \(error.localizedDescription) — "
                    + "force-quit Wallet to see the new skin")
            }

            written += 1
            progress(Double(index + 1) / total)
        }

        guard written > 0 else {
            throw GoldenNuggetError("No card skin was written. The device has to be unlocked "
                + "with LocalDevVPN up.")
        }
        log("Applied \(written)/\(withImages.count) card skin(s). Force-quit Wallet to see them.")
    }

    /// Replace Passbook's cached renderings with bytes it cannot use.
    private static func invalidateCache(identifier: String, pairingPath: String) async throws {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        for leaf in cacheLeaves {
            try? Data("corrupted".utf8).write(to: stage.appendingPathComponent(leaf))
        }
        // Both spellings exist: which one a device has depends on its iOS
        // version, and writing a cache that is not there is a no-op rather than
        // an error — so this is a best-effort loop by design.
        for ext in [".cache", ".pkcache"] {
            try? await Airlift.writeDir(
                pairingPath: pairingPath,
                sourceDir: stage.path,
                targetDir: "\(cardsRoot)/\(identifier)\(ext)"
            )
        }
    }

    /// Pull card identifiers out of Passbook's syslog chatter.
    ///
    /// There is no other way to learn which card is in the reader: the hardware
    /// does not announce itself, Passbook logs it, and the log is a live stream
    /// over the tunnel rather than a file that can be read after the fact. The
    /// caller keeps the stream open while the user brings a card up.
    static func scanCards(pairingPath: String,
                          onFound: @escaping @Sendable (String) -> Void) async throws -> () -> Void {
        let stop = try await Airlift.streamSyslog(pairingPath: pairingPath) { line in
            for candidate in identifiers(in: line) {
                onFound(candidate)
            }
        }
        return stop
    }

    /// Every plausible card identifier in one log line.
    ///
    /// Passbook's wording differs per iOS version, so this matches on the
    /// `Passes/Cards/<id>.pkpass` path and on bare quoted tokens, and hands both
    /// to `cleanIdentifier` rather than trying to know the sentence.
    static func identifiers(in line: String) -> [String] {
        var found: [String] = []

        if let cardsRange = line.range(of: "Passes/Cards/") {
            let tail = line[cardsRange.upperBound...]
            let end = tail.firstIndex { $0 == "/" || $0 == " " || $0 == "\"" || $0 == "'" }
            let token = String(tail[..<(end ?? tail.endIndex)])
            if let cleaned = WalletCard.cleanIdentifier(token) { found.append(cleaned) }
        }

        for raw in quoted(in: line) {
            if let cleaned = WalletCard.cleanIdentifier(raw) { found.append(cleaned) }
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    private static func quoted(in line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inside = false
        for character in line {
            if character == "\"" || character == "'" {
                if inside, !current.isEmpty { tokens.append(current) }
                current = ""
                inside.toggle()
            } else if inside {
                current.append(character)
            }
        }
        return tokens
    }
}

/// The card list, kept in `<Documents>/wallet-cards.json`.
///
/// It is on disk rather than in `UserDefaults` for one reason: a skin is up to a
/// megabyte of PNG, and `UserDefaults` is the wrong place for a megabyte per card
/// — it is read into memory on every launch, whether or not the page is opened.
/// JSON in Documents is read when the Wallet page appears and written when a
/// skin is picked.
///
/// The list is saved rather than the *card* being a live object: a card is
/// identified by a string Passbook logged once, and if the app is relaunched
/// without the card against the reader there is no way to rediscover it. Keeping
/// the identifier is what lets the apply run unattended later.
enum WalletCardStore {
    private static var url: URL {
        URL.documents.appendingPathComponent("wallet-cards.json")
    }

    static func load() -> [WalletCard] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WalletCard].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ cards: [WalletCard]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(cards) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
