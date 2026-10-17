import Foundation

/// Minimal model of an Icon Composer `.icon` bundle's `icon.json`.
///
/// A `.icon` is a layered stack -- gradients, shadows, translucency and
/// per-appearance layer visibility -- that CoreUI compiles into iconstack
/// renditions (part 245/246, layout 1019). Reproducing that stack on Linux is
/// out of scope here: the fields a flat fallback needs are only the PNGs the
/// stack is built from and which appearance each one belongs to.
///
/// Local addition (upstream AssetKit 1.0.0 has no Icon Composer support at
/// all). The rest of `icon.json` (`fill`, `shadow`, `translucency`,
/// `supported-platforms`) is intentionally ignored, so a catalog with a `.icon`
/// primary still compiles into a valid classic `.appiconset`-shaped car.
struct IconBundleContents: Codable, Sendable {
    struct Specialization: Codable, Sendable {
        var appearance: String?
        var value: Bool?
    }

    struct Layer: Codable, Sendable {
        var imageName: String?
        var name: String?
        var hiddenSpecializations: [Specialization]?

        enum CodingKeys: String, CodingKey {
            case imageName = "image-name"
            case name
            case hiddenSpecializations = "hidden-specializations"
        }

        /// A layer is visible for an appearance unless a matching
        /// `hidden-specializations` entry marks it hidden. A specialization
        /// with no `appearance` applies to the base appearance; one whose
        /// `appearance` is `dark` applies only to the dark appearance. A layer
        /// with no specializations is visible in every appearance.
        func isVisible(appearance: String?) -> Bool {
            guard let hidden = hiddenSpecializations, !hidden.isEmpty else { return true }
            let match = hidden.last { $0.appearance == appearance }
            return !(match?.value ?? false)
        }
    }

    struct Group: Codable, Sendable {
        var layers: [Layer]?
    }

    var groups: [Group]?

    /// All `image-name`s referenced by the stack, in declaration order.
    var imageNames: [String] {
        (groups ?? []).flatMap { ($0.layers ?? []).compactMap(\.imageName) }
    }

    /// The artwork shown in the base (light) appearance, or `nil` when the
    /// stack declares none.
    func baseImageName() -> String? {
        firstVisible(in: nil)
    }

    /// The artwork shown in the `luminosity = dark` appearance, or `nil` when
    /// the stack declares none.
    func darkImageName() -> String? {
        firstVisible(in: "dark")
    }

    private func firstVisible(in appearance: String?) -> String? {
        for group in groups ?? [] {
            for layer in group.layers ?? [] {
                if let imageName = layer.imageName, layer.isVisible(appearance: appearance) {
                    return imageName
                }
            }
        }
        return nil
    }
}

/// Synthesizes a classic `.appiconset`-shaped `LoadedAppIcon` from an Icon
/// Composer `.icon` bundle.
///
/// actool writes the iconstack renditions; this fallback instead expands the
/// bundle's base and dark artwork across the standard iphone/ipad/marketing
/// matrix and lets the appiconset renderer downscale each slot. The result is
/// a car with a correctly named `AppIcon` facet, both appearances, and the
/// loose PNGs SpringBoard falls back to -- without CoreUI's iconstack layout.
enum FlatIconSynthesis {
    /// Telegram's BlackIcon matrix, copied from `ScrappedIcon.appiconset`:
    /// every slot a classic iOS app icon is looked up under.
    static let matrix: [(idiom: Idiom, points: Double, scale: Int)] = [
        (.iphone, 20, 2), (.iphone, 20, 3),
        (.iphone, 29, 2), (.iphone, 29, 3),
        (.iphone, 40, 2), (.iphone, 40, 3),
        (.iphone, 60, 2), (.iphone, 60, 3),
        (.ipad, 20, 1), (.ipad, 20, 2),
        (.ipad, 29, 1), (.ipad, 29, 2),
        (.ipad, 40, 1), (.ipad, 40, 2),
        (.ipad, 76, 1), (.ipad, 76, 2),
        (.ipad, 83.5, 2),
        (.marketing, 1024, 1),
    ]

    static func appIcon(
        name: String,
        directory: URL,
        contents: IconBundleContents
    ) throws -> LoadedAppIcon {
        guard let baseImage = contents.baseImageName() else {
            throw XCAssetCompilerError.iconBundleMissingArtwork(asset: name)
        }
        let darkImage = contents.darkImageName()
        let basePath = "Assets/\(baseImage)"
        // A dark-only stack (no base artwork) still needs a base appearance,
        // so the dark file doubles as the base when the light half is missing.
        let baseExists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(basePath).path)
        let effectiveBase = baseExists ? basePath : "Assets/\(darkImage ?? baseImage)"

        var images: [AppIconContents.Image] = []
        for slot in matrix {
            let size = "\(formatSize(slot.points))x\(formatSize(slot.points))"
            let scale = scale(for: slot.scale)
            images.append(AppIconContents.Image(
                idiom: slot.idiom,
                size: size,
                scale: scale,
                filename: effectiveBase,
                role: nil,
                subtype: nil,
                appearances: nil
            ))
            if let darkImage, darkImage != baseImage || !baseExists {
                images.append(AppIconContents.Image(
                    idiom: slot.idiom,
                    size: size,
                    scale: scale,
                    filename: "Assets/\(darkImage)",
                    role: nil,
                    subtype: nil,
                    appearances: [.dark]
                ))
            }
        }

        return LoadedAppIcon(
            name: name,
            directory: directory,
            contents: AppIconContents(
                images: images,
                info: CatalogContents.Info(version: 1, author: "assetkit")
            ),
            resampleToPointSize: true
        )
    }

    private static func scale(for factor: Int) -> Scale {
        switch factor {
        case 3: return .x3
        case 2: return .x2
        default: return .x1
        }
    }

    static func formatSize(_ n: Double) -> String {
        let rounded = n.rounded()
        if abs(n - rounded) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%g", n)
    }
}
