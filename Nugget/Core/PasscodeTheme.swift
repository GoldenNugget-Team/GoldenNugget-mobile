import Foundation
import ImageIO
import UIKit

/// Passcode (lock screen keypad) themes, written into TelephonyUI's caches.
///
/// A port of AirCard's passcode tab: `PasscodeThemeInfo`, `KeypadLocales`,
/// `KeypadLayout`, `PasscodeThemeReader` and `AppViewModel.flashPassthm`.
///
/// ## Why this needs AirLift
///
/// The dialer keypad's artwork is read by `TelephonyUI` from
/// `/var/mobile/Library/Caches/TelephonyUI-<n>` — a cache directory in the
/// system, not a container, and not reachable by a manifest domain. So the same
/// reasoning as the Wallet page applies: there is nothing a protective backup can
/// carry, and the file has to be written where the process that draws it will look.
///
/// ## The naming contract
///
/// A theme is not a picture of a keypad. It is a *matrix* of one file per
/// (language, weight, digit, subtext) combination, and TelephonyUI picks the file
/// whose name encodes the current locale, whether the text is bold, and which
/// subtext the key shows. That is why `stage` writes the same image under many
/// names: the reader on the device asks for one specific name, and the only way to
/// cover an unknown device language is to write the variants it might ask for.
struct PasscodeThemeInfo: Identifiable {
    var id: String { filePath }
    let name: String
    let filePath: String
    let fileCount: Int
    /// One image per digit, for the preview grid.
    let keysPreview: [String: UIImage]
    /// The bytes as they were in the archive.
    ///
    /// Kept separately from the preview because a theme's real resolution is what
    /// it ships — re-encoding a downsampled preview is how a theme gets applied
    /// blurry. The reference makes the same split and is just as emphatic about
    /// never crossing it.
    let rawKeyData: [String: Data]
}

/// The locales a theme can be written for.
enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all, uk, ru, en, other, es, de, fr, pl, it, pt, tr, ja, ko, zh, ar, he

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All languages"
        case .uk: return "Ukrainian"
        case .ru: return "Russian"
        case .en: return "English"
        case .other: return "Other / fallback"
        case .es: return "Spanish"
        case .de: return "German"
        case .fr: return "French"
        case .pl: return "Polish"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .tr: return "Turkish"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .zh: return "Chinese"
        case .ar: return "Arabic"
        case .he: return "Hebrew"
        }
    }

    var code: String {
        switch self {
        case .all: return "all"
        case .uk: return "uk"
        case .ru: return "ru"
        case .en: return "en"
        case .other: return "other"
        case .es: return "es"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        case .it: return "it"
        case .pt: return "pt"
        case .tr: return "tr"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zh: return "zh"
        case .ar: return "ar"
        case .he: return "he"
        }
    }
}

/// Which text weights to write.
enum PasscodeBoldTarget: String, CaseIterable, Identifiable {
    case both, boldOnly, regularOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Regular + bold"
        case .boldOnly: return "Bold only"
        case .regularOnly: return "Regular only"
        }
    }

    /// The file name suffix, which is the part the device matches on.
    var suffix: String {
        switch self {
        case .both: return ""
        case .boldOnly: return "-bold"
        case .regularOnly: return ""
        }
    }

    var suffixes: [String] {
        self == .both ? ["", "-bold"] : [suffix]
    }
}

/// Locales and the subtexts a keypad shows in each.
enum KeypadLocales {
    /// Every locale a theme can be written for.
    static let all: [String] = [
        "en", "other", "ru", "uk", "es", "fr", "de", "it",
        "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he",
    ]

    /// Russian subtexts, which are not transliterations of the Latin ones.
    static let cyrillicRU: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "И Й К Л", "5": "М Н О П",
        "6": "Р С Т У", "7": "Ф Х Ц Ч", "8": "Ш Щ Ъ Ы", "9": "Ь Э Ю Я",
    ]

    /// Ukrainian subtexts, which differ from Russian on 4, 7 and 8.
    static let cyrillicUK: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "І Ї Й К", "5": "Л М Н О",
        "6": "П Р С Т", "7": "У Ф Х Ц", "8": "Ч Ш Щ Ь", "9": "Ю Я",
    ]
}

/// The keypad's grid, and the subtext under each digit.
enum KeypadLayout {
    static let subtexts: [String: String] = [
        "0": "+", "1": "", "2": "A B C", "3": "D E F", "4": "G H I",
        "5": "J K L", "6": "M N O", "7": "P Q R S", "8": "T U V", "9": "W X Y Z",
    ]

    /// Digits in the order the preview grid draws them.
    static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    /// A key's position in the 3×4 grid, for the preview.
    static func row(for digit: String) -> Int {
        switch digit {
        case "1", "2", "3": return 0
        case "4", "5", "6": return 1
        case "7", "8", "9": return 2
        default: return 3
        }
    }

    static func column(for digit: String) -> Int {
        switch digit {
        case "1", "4", "7": return 0
        case "2", "5", "8": return 1
        case "0": return 1
        default: return 2
        }
    }
}

/// Reads a `.passthm` archive into a previewable theme.
enum PasscodeThemeReader {
    /// Unpack and index a theme.
    ///
    /// Extraction goes through AirLift's own `al_passthm_extract` rather than
    /// ZIPFoundation: a `.passthm` is written by Passbook, which stores some
    /// entries deflated and others stored, and the reference's Rust extractor is
    /// the one known to walk both.
    ///
    /// `async` because that extractor is an `al_*` call, and every one of those
    /// blocks on its own RSD tunnel — the caller cannot read the archive on a
    /// background thread and then hand the path over, because the unpack is the
    /// slow part and it is the part that has to be awaited.
    static func inspect(url: URL) async throws -> PasscodeThemeInfo {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("passthm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        try await Airlift.extractPassthm(archivePath: url.path, destDir: stage.path)

        let files = (FileManager.default.subpaths(atPath: stage.path) ?? [])
        guard !files.isEmpty else {
            throw GoldenNuggetError("\(url.lastPathComponent) unpacked to nothing.")
        }

        var previews: [String: UIImage] = [:]
        var raw: [String: Data] = [:]
        var count = 0

        for file in files {
            guard !file.hasPrefix("."), !file.contains("__MACOSX") else { continue }
            let lower = file.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            else { continue }
            count += 1

            let name = (file as NSString).lastPathComponent
            guard let digit = digit(in: name), previews[digit] == nil else { continue }
            guard let data = try? Data(contentsOf: stage.appendingPathComponent(file)) else { continue }
            raw[digit] = data
            previews[digit] = downsample(data, maxDimension: 512)
        }

        guard !previews.isEmpty else {
            throw GoldenNuggetError("\(url.lastPathComponent) has no keypad images in it.")
        }
        return PasscodeThemeInfo(name: url.lastPathComponent,
                                 filePath: url.path,
                                 fileCount: count,
                                 keysPreview: previews,
                                 rawKeyData: raw)
    }

    /// The digit a file name belongs to.
    ///
    /// The reference's regex, in order: strip the colour and scale markers, then
    /// take the first digit after an optional leading locale. A theme that names
    /// its files `uk-4-І Ї Й К--white@3x.png` has to yield `4`, and a naive
    /// "first character that is a digit" would too — but only because the locale
    /// is alphabetic. The fallback exists for the themes that are not.
    static func digit(in filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        var cleaned = stem
        for marker in ["--white", "-white", "@3x", "@2x"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "",
                                                  options: .caseInsensitive)
        }
        let pattern = #"(?:^[a-zA-Z]+-)?([0-9*#])"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let text = cleaned as NSString
            if let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0,
                                                                        length: text.length)),
               match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    let value = text.substring(with: range)
                    if value.count == 1, value.first!.isNumber { return value }
                }
            }
        }
        return cleaned.first(where: { $0.isNumber }).map(String.init)
    }

    private static func downsample(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return UIImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }
}

/// Staging and writing a passcode theme.
enum PasscodeThemeEngine {
    /// The cache directories TelephonyUI reads, newest last.
    ///
    /// A device only has the one matching its version, so writing all three is
    /// how a single build covers iOS 18 through 27 — the extra writes are no-ops
    /// on directories that are not there.
    static let telephonyCacheRoots = [
        "/var/mobile/Library/Caches/TelephonyUI-10",
        "/var/mobile/Library/Caches/TelephonyUI-9",
        "/var/mobile/Library/Caches/TelephonyUI-8",
    ]

    /// The device's language, as a keypad locale, so its own variant is always
    /// written even when the user picked a single language.
    static func detectedLocale() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return KeypadLocales.all.contains(code) ? code : "en"
    }

    /// Write a theme's keys into every TelephonyUI cache.
    static func apply(theme: PasscodeThemeInfo,
                      language: PasscodeLanguageTarget,
                      weight: PasscodeBoldTarget,
                      pairingPath: String,
                      log: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void) async throws {
        guard !theme.rawKeyData.isEmpty else {
            throw GoldenNuggetError("\(theme.name) has no key images in it.")
        }
        let stage = try stage(theme: theme, language: language, weight: weight)

        let suffixes = weight.suffixes
        let languages = languages(for: language)
        log("\(theme.name): \(theme.rawKeyData.count) key(s) × \(languages.count) locale(s) × "
            + "\(suffixes.count) weight(s)")

        let roots = telephonyCacheRoots
        for (index, root) in roots.enumerated() {
            let label = (root as NSString).lastPathComponent
            do {
                try await Airlift.writeDir(pairingPath: pairingPath,
                                           sourceDir: stage.path,
                                           targetDir: root)
                log("  ✅ \(label)")
            } catch {
                // A directory that does not exist on this iOS version is expected,
                // not a failure — so only a total wipe-out is an error.
                log("  ⚠️ \(label): \(error.localizedDescription)")
            }
            progress(Double(index + 1) / Double(roots.count))
        }

        try? FileManager.default.removeItem(at: stage)
        log("Lock the device to see the keypad.")
    }

    /// Build the on-disk matrix a theme turns into.
    static func stage(theme: PasscodeThemeInfo,
                      language: PasscodeLanguageTarget,
                      weight: PasscodeBoldTarget) throws -> URL {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("passthm-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        let suffixes = weight.suffixes
        let languages = languages(for: language)

        for (digit, data) in theme.rawKeyData {
            let subtext = KeypadLayout.subtexts[digit] ?? ""
            for locale in languages {
                for suffix in suffixes {
                    // Digits 0 and 1 have no subtext, and the device asks for them
                    // by a name with the subtext section left empty — three dashes.
                    if digit == "0" {
                        // 0 also has a "+" variant, which is what shows on a key
                        // configured with a plus. Both are written because which
                        // one is asked for depends on the lock screen, not on us.
                        write(data, to: stage, "\(locale)-0---white\(suffix).png")
                        write(data, to: stage, "\(locale)-0-+--white\(suffix).png")
                    } else if digit == "1" {
                        write(data, to: stage, "\(locale)-1---white\(suffix).png")
                    } else {
                        write(data, to: stage, "\(locale)-\(digit)---white\(suffix).png")
                        if !subtext.isEmpty {
                            write(data, to: stage, "\(locale)-\(digit)-\(subtext)--white\(suffix).png")
                            // A locale that omits the space writes the letters
                            // run together, and the device asks for that name.
                            let tight = subtext.replacingOccurrences(of: " ", with: "")
                            if tight != subtext {
                                write(data, to: stage,
                                      "\(locale)-\(digit)-\(tight)--white\(suffix).png")
                            }
                        }
                        // The Cyrillic subtexts are their own strings, not
                        // translations of the Latin ones, so they get their own rows.
                        if locale == "ru" || language == .all,
                           let russian = KeypadLocales.cyrillicRU[digit] {
                            write(data, to: stage,
                                  "\(locale)-\(digit)-\(russian)--white\(suffix).png")
                        }
                        if locale == "uk" || language == .all,
                           let ukrainian = KeypadLocales.cyrillicUK[digit] {
                            write(data, to: stage,
                                  "\(locale)-\(digit)-\(ukrainian)--white\(suffix).png")
                        }
                    }
                }
            }
        }

        // TelephonyUI treats this marker as "use the @3x artwork". Without it the
        // theme applies and then renders at 2x, which looks like it half worked.
        try? Data().write(to: stage.appendingPathComponent("_big"))

        return stage
    }

    /// The locales to write: the choice, plus the device's own, plus the fallback.
    static func languages(for target: PasscodeLanguageTarget) -> [String] {
        if target == .all { return KeypadLocales.all }
        var result = [target.code]
        if target.code != "other" { result.append("other") }
        let detected = detectedLocale()
        if detected != "other", !result.contains(detected) { result.append(detected) }
        return result
    }

    private static func write(_ data: Data, to directory: URL, _ name: String) {
        try? data.write(to: directory.appendingPathComponent(name))
    }
}
