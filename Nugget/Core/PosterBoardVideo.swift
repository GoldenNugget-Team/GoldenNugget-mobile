import AVFoundation
import Foundation
import UIKit
import VideoToolbox

/// How a video's frames are interpolated between keyframes
/// (`CAKeyframeAnimation.calculationMode`) — the reference's two options.
enum PosterBoardCalculationMode: String, CaseIterable, Identifiable {
    case linear
    case discrete

    var id: String { rawValue }

    var title: String { self == .linear ? "Linear" : "Discrete" }
}

/// A video wallpaper, as the page has assembled it.
struct PosterBoardVideoPlan {
    /// The picked video, copied into the app's container.
    var video: URL
    /// The freeze frame.  Required for the live-photo (non-looping) method —
    /// the reference raises rather than shipping a descriptor with no thumbnail.
    var thumbnail: URL?
    /// `loop_video`: CoreAnimation frame list (true) or a live photo (false).
    var loop = true
    var reverse = false
    /// `use_foreground`: promote the floating layer to the background, which
    /// hides the clock.
    var foreground = false
    var calculationMode: PosterBoardCalculationMode = .linear

    var name: String { video.lastPathComponent }
}

/// `src/controllers/video_handler.py`, ported.
///
/// Two ways to put a video on the Lock Screen, and the reference implements both:
///
///   * **live photo** (`loop_video == false`) — the video goes into a Photos
///     poster descriptor, together with a freeze frame; iOS animates it on
///     raise.  The video rides inside a `.aar` archive whose layout
///     `src/controllers/aar/aar.py` builds by hand.
///   * **CoreAnimation loop** (`loop_video == true`) — the video is decoded to
///     JPEG frames and referenced by a `main.caml` keyframe animation, which
///     loops indefinitely.  This is the one with a hard cost: up to 400 frames
///     at the video's own resolution.
///
/// **What differs from the reference, and why:**
///
///   * Frames are decoded with `AVAssetReader` instead of OpenCV; OpenCV does
///     not exist on iOS, and this app is the device.  The stored orientation is
///     used, as OpenCV's does — a video carrying a rotation transform will
///     therefore render in its stored orientation, and that is logged rather
///     than silently "fixed" (changing it would change the caml's bounds away
///     from the JPEG dimensions, which is what the animation relies on).
///   * The video never goes through memory.  The reference reads the whole file
///     into `bytes` and hands it to `wrap_in_aar`; a phone video is not a
///     quantity to hold twice, so the `.aar` is written by streaming the file
///     behind its header.
enum PosterBoardVideo {
    /// The reference's `FRAME_LIMIT`, and the reason it exists: every frame is a
    /// JPEG the device decodes per animation step.
    static let frameLimit = 400

    /// `video_handler.create_caml`'s JPEG quality.  OpenCV's `imwrite` default is
    /// 95, which is what the reference relies on.
    static let jpegQuality: CGFloat = 0.95

    /// Both halves of `create_*_files`, into `outputDirectory`.
    ///
    /// Off the main thread on purpose. Decoding up to 400 frames and encoding
    /// each as a JPEG is minutes of work on a phone, and the compile step this
    /// belongs to is called from a `Task` a view's `body` started — i.e. from
    /// the main actor. Everything inside is synchronous once it is going, so the
    /// hop has to be made here rather than awaited around.
    static func generate(plan: PosterBoardVideoPlan,
                         outputDirectory: URL,
                         log: @escaping @Sendable (String) -> Void) async throws {
        try await Task.detached(priority: .utility) {
            if plan.loop {
                try await generateLoop(plan: plan, outputDirectory: outputDirectory, log: log)
            } else {
                try await generateLivePhoto(plan: plan, outputDirectory: outputDirectory, log: log)
            }
        }.value
    }

    // MARK: - CoreAnimation loop

    /// `create_video_loop_files`.
    private static func generateLoop(plan: PosterBoardVideoPlan,
                                     outputDirectory: URL,
                                     log: @escaping @Sendable (String) -> Void) async throws {
        let root = outputDirectory.appendingPathComponent("descriptor/VideoCAML", conformingTo: .data)
        try write(PosterBoardResources.videoLoopDescriptor, into: root)

        // The reference's path is fixed: the descriptor skeleton's own wallpaper
        // directory, whose `.ca` is what gets replaced.
        let wallpaper = root.appendingPathComponent(
            "versions/1/contents/9183.Custom-810w-1080h@2x~ipad.wallpaper", conformingTo: .data)
        let floating = wallpaper.appendingPathComponent(
            "9183.Custom_Floating-810w-1080h@2x~ipad.ca", conformingTo: .data)
        let background = wallpaper.appendingPathComponent(
            "9183.Custom_Background-810w-1080h@2x~ipad.ca", conformingTo: .data)

        let ca: URL
        if plan.foreground {
            // Retitle the floating layer to the background one: the wallpaper
            // then covers the clock.
            try? FileManager.default.removeItem(at: background)
            try FileManager.default.moveItem(at: floating, to: background)
            ca = background
        } else {
            ca = background
        }

        log("  → video loop: decoding \(plan.name) into \(ca.lastPathComponent)")
        try await writeCAML(video: plan.video,
                            caDirectory: ca,
                            calculationMode: plan.calculationMode.rawValue,
                            reverse: plan.reverse,
                            log: log)
    }

    /// `create_caml`: decode every frame, then write the frame list around them.
    private static func writeCAML(video: URL,
                                  caDirectory: URL,
                                  calculationMode: String,
                                  reverse: Bool,
                                  log: @escaping @Sendable (String) -> Void) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GoldenNuggetError("\(video.lastPathComponent) carries no video track.")
        }
        // `naturalSize`, **not** the size after `preferredTransform`: the frames
        // below come out of a reader in their stored orientation, and OpenCV's
        // decoder — the reference's — does not apply the transform either. The
        // caml's frame bounds has to match the JPEGs it points at.
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let width = Int(abs(naturalSize.width.rounded()))
        let height = Int(abs(naturalSize.height.rounded()))
        guard width > 0, height > 0 else {
            throw GoldenNuggetError("\(video.lastPathComponent) reports a "
                + "\(width)×\(height) frame — nothing to decode.")
        }
        if transform != .identity {
            log("  ⚠️ \(video.lastPathComponent) carries a rotation transform; frames are "
                + "decoded in their stored orientation, exactly as the reference's decoder "
                + "produces them, so the wallpaper may be rotated on the Lock Screen.")
        }

        let fps = try await framesPerSecond(of: track)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let estimate = max(1, Int((seconds * fps).rounded()))
        guard estimate <= frameLimit else {
            throw GoldenNuggetError("\(video.lastPathComponent) is about \(estimate) frames; "
                + "a CoreAnimation wallpaper is limited to \(frameLimit). Trim the video, or "
                + "use the live-photo method (turn Looping off).")
        }
        let duration = Double(estimate) / fps

        // The document is the logical screen, **not** the frame size. The
        // reference's `create_caml` grew these four parameters for exactly this
        // reason (743d363): PosterKit's depth effect parallaxes planes whose
        // bounds and origin differ from the document, and a document sized to the
        // video — with the layer dead-centre at scale 1.0 — gives it nothing to
        // travel against, which reads as a flat wallpaper on iOS 27.
        //
        // `cover` scales the frames to fill the document; the reference's own
        // default `bounds_scale` is 1.0 and its offsets are 0, so the defaults
        // reproduce it exactly, and a caller wanting travel passes more.
        let screen = Self.screenSize(log: log)
        let docWidth = screen.width
        let docHeight = screen.height
        let cover = max(Double(docWidth) / Double(width), Double(docHeight) / Double(height))
        let layerScale = cover * Self.depthScale
        let centerX = Double(docWidth) / 2
        let centerY = Double(docHeight) / 2
        // The layer is published by name, and `index.xml` has to name the same
        // one — the reference passes the same `layer_name` to both writers.
        let layerName = "Chip"

        // Only the frames are cleared. The `.ca` directory itself comes from the
        // bundled descriptor and carries `index.xml`/`main.caml` — which are
        // rewritten below anyway, but nothing else in it is ours to delete.
        let assets = caDirectory.appendingPathComponent("assets", conformingTo: .data)
        try? FileManager.default.removeItem(at: assets)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var caml = PosterBoardTemplates.camlHeader(width: width, height: height,
                                                   docWidth: docWidth, docHeight: docHeight,
                                                   centerX: centerX, centerY: centerY,
                                                   layerScale: layerScale, layerName: layerName,
                                                   calculationMode: calculationMode,
                                                   duration: duration,
                                                   reverse: reverse ? 1 : 0)
        var written = 0
        try decodeFrames(asset: asset, track: track) { frame in
            guard written < frameLimit else { return false }
            let jpeg = try Self.jpeg(frame)
            try jpeg.write(to: assets.appendingPathComponent("\(written).jpg"))
            caml += PosterBoardTemplates.camlFrame(index: written)
            written += 1
            return true
        }
        guard written > 0 else {
            throw GoldenNuggetError("\(video.lastPathComponent) decoded no frames.")
        }
        caml += PosterBoardTemplates.camlFooter()
        try caml.write(to: caDirectory.appendingPathComponent("main.caml"),
                       atomically: true, encoding: .utf8)
        try PosterBoardTemplates.camlIndex(docWidth: docWidth, docHeight: docHeight,
                                           layerName: layerName)
            .write(to: caDirectory.appendingPathComponent("index.xml"),
                   atomically: true, encoding: .utf8)
        log("  → \(written) frame(s), \(width)×\(height) frames in a \(docWidth)×\(docHeight) "
            + "document, layer \(layerName) at scale \(String(format: "%.4f", layerScale)), "
            + "\(String(format: "%.2f", fps)) fps, "
            + "duration \(String(format: "%.3f", duration)) s")
    }

    /// The document size, in points: the device's own screen, which is the one
    /// number the background and foreground packages were built for.
    ///
    /// Read from a `UIScreen` reached through a window scene rather than
    /// `UIScreen.main` — deprecated in iOS 26, and this app targets 26. Falls
    /// back to the reference's own 390x844 default (a 6.1" iPhone) rather than
    /// guessing: the reference is a desktop app that has to assume a screen, and
    /// a build that cannot reach a scene has no better answer than the one it
    /// uses. The fallback is logged, because it silently changes the document
    /// every frame is laid out in.
    private static func screenSize(log: @escaping @Sendable (String) -> Void)
        -> (width: Int, height: Int) {
        guard let bounds = activeScreenBounds(), !bounds.isEmpty else {
            log("  ⚠️ no window scene is reachable; falling back to the reference's "
                + "390x844 document. The frames will be laid out for a screen this "
                + "device does not have.")
            return (390, 844)
        }
        let width = max(1, Int(bounds.width.rounded()))
        let height = max(1, Int(bounds.height.rounded()))
        log("  → document \(width)×\(height) points "
            + "(the device screen; the reference assumes a 390x844 iPhone)")
        return (width, height)
    }

    /// The bounds of a screen this app is actually on, or nil when no scene can
    /// be reached (a unit-test host, a background extension).
    private static func activeScreenBounds() -> CGRect? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        // `.foregroundActive` first: a scene that is on screen but not active
        // (say, a Slide Over companion) is not the one whose size a wallpaper
        // document should match.
        let ordered = scenes.sorted { lhs, rhs in
            let rank: (UIScene.ActivationState) -> Int = {
                switch $0 {
                case .foregroundActive: return 0
                case .foregroundInactive: return 1
                default: return 2
                }
            }
            return rank(lhs.activationState) < rank(rhs.activationState)
        }
        if let screen = ordered.first(where: { !$0.screen.bounds.isEmpty })?.screen {
            return screen.bounds
        }
        return scenes.first?.screen.bounds
    }

    /// `create_caml`'s `bounds_scale`, kept at the reference's default.
    ///
    /// 1.0 is `cover`: the frames exactly fill the document, centred. A value
    /// above 1 makes the animated layer larger than the document, which is what
    /// gives the depth pass travel to parallax against — the reference exposes it
    /// for that, and the Odyssey's `spartanbg` ships bounds 1852x4104 inside a
    /// 390x844 document. Nothing in this port drives it yet: the page has no
    /// control for it, and inventing a default that is not the reference's would
    /// change how every video wallpaper looks on a device that has never run
    /// one. It is a named constant so the value is one edit away, not a literal
    /// buried in the geometry.
    static let depthScale: Double = 1.0

    // MARK: - Live photo

    /// `create_live_photo_files`.
    private static func generateLivePhoto(plan: PosterBoardVideoPlan,
                                          outputDirectory: URL,
                                          log: @escaping @Sendable (String) -> Void) async throws {
        let root = outputDirectory.appendingPathComponent(
            "video-descriptor/\(PosterBoardResources.livePhotoIdentifier)", conformingTo: .data)
        try write(PosterBoardResources.livePhotoDescriptor, into: root)

        let contents = root.appendingPathComponent(
            "versions/0/contents/0EFB6A0F-7052-4D24-8859-AB22BADF2E93", conformingTo: .data)
        let layerStack = contents.appendingPathComponent("output.layerStack", conformingTo: .data)
        let segmentation = contents.appendingPathComponent("input.segmentation", conformingTo: .data)

        // The reference converts anything that is not already a .mov; a .mov is
        // used as it stands. Spelled as a statement rather than a ternary:
        // `try await` inside a conditional expression has to be marked on the
        // whole expression, and the branch is clearer as a branch.
        let converted: URL?
        if plan.video.pathExtension.lowercased() == "mov" {
            converted = nil
        } else {
            converted = try await exportAsMOV(plan.video)
        }
        let movie = converted ?? plan.video
        defer { if let converted { try? FileManager.default.removeItem(at: converted) } }

        try FileManager.default.createDirectory(at: layerStack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: segmentation.appendingPathComponent("asset.resource", conformingTo: .data),
            withIntermediateDirectories: true)
        let settling = layerStack.appendingPathComponent("portrait-layer_settling-video.MOV")
        try? FileManager.default.removeItem(at: settling)
        try FileManager.default.copyItem(at: movie, to: settling)
        log("  → live photo: \(plan.name) → portrait-layer_settling-video.MOV "
            + "(\(ByteCountFormatter.string(fromByteCount: fileSize(settling), countStyle: .file)))")

        // The .aar is a container of exactly two members: the descriptor's
        // contents.plist and the video.
        try wrapInAAR(contentsPlist: PosterBoardResources.livePhotoContentsPlist,
                      video: settling,
                      output: segmentation.appendingPathComponent("segmentation.data.aar"))

        guard let thumbnail = plan.thumbnail else {
            throw GoldenNuggetError("A live-photo wallpaper needs a freeze frame (.heic). "
                + "Pick one on the Video tab, or turn Looping on.")
        }
        // The reference writes the picked bytes over all three slots without
        // looking at what they are; the descriptor's assets are HEIC, so the
        // picker asks for HEIC.
        let thumbBytes = try Data(contentsOf: thumbnail, options: .mappedIfSafe)
        let slots = ["input.segmentation/asset.resource/Adjusted.HEIC",
                     "input.segmentation/asset.resource/proxy.heic",
                     "output.layerStack/portrait-layer_background.HEIC"]
        for slot in slots {
            let destination = contents.appendingPathComponent(slot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try thumbBytes.write(to: destination)
        }
    }

    // MARK: - `.aar`

    /// `src/controllers/aar/aar.py`, ported.
    ///
    /// An `AA01` archive with two members whose names are baked into their
    /// headers, so both headers are literals and only the payload sizes vary.
    /// The size field is a 2-byte blob while it fits, and the member's subtype
    /// byte flips to `B` (a 4-byte blob) when it does not — which also grows the
    /// header by two and has to be reflected in its own length field.
    static func wrapInAAR(contentsPlist: Data, video: URL, output: URL) throws {
        var first = Self.hex(
            "4141303125005459503146504154500E00636F6E74656E74732E706C697374444154418E13")
        var second = Self.hex(
            "4141303129005459503146504154501200736574746C696E674566666563742E6D6F7644415441F4B8")

        patchSizeField(&first, size: contentsPlist.count, longHeaderLength: 0x27)
        patchSizeField(&second, size: Int(fileSize(video)), longHeaderLength: 0x2B)

        try? FileManager.default.removeItem(at: output)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw GoldenNuggetError("Could not create \(output.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(first))
        try handle.write(contentsOf: contentsPlist)
        try handle.write(contentsOf: Data(second))
        // Streamed, not read: the video is already on disk twice at this point
        // (the descriptor's copy and this one) and a third copy in memory is the
        // difference between working and being killed on a phone.
        let source = try FileHandle(forReadingFrom: video)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 18), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
    }

    /// The reference's size patch, including the 64 KB boundary.
    ///
    /// `header[-2:] = pack('<H', size)` grows to four bytes in the long case,
    /// which is why the byte three from the end — the member's subtype — becomes
    /// `B` (a 4-byte blob) and the header's own length field at index 4 has to be
    /// bumped by two to match.
    private static func patchSizeField(_ header: inout [UInt8],
                                       size: Int,
                                       longHeaderLength: UInt8) {
        if size <= 0xFFFF {
            header[header.count - 2] = UInt8(size & 0xFF)
            header[header.count - 1] = UInt8((size >> 8) & 0xFF)
        } else {
            // `header[-3]`, spelled as the measurement it is.
            header[header.count - 3] = 0x42
            header.removeLast(2)
            header[4] = longHeaderLength
            header.append(contentsOf: [
                UInt8(size & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 24) & 0xFF),
            ])
        }
    }

    /// Bytes from a hex string, for the two `.aar` headers — the reference spells
    /// them as `bytearray.fromhex(...)` and they stay literal here too.
    private static func hex(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex,
              let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex) {
            bytes.append(UInt8(value[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    // MARK: - Decoding

    /// Every decoded frame, in order, via `AVAssetReader`.
    ///
    /// Sequential decoding rather than `AVAssetImageGenerator`: the generator
    /// seeks to each requested time, so a 400-frame wallpaper would be 400 seeks.
    /// The callback returns `false` to stop early.
    private static func decodeFrames(asset: AVURLAsset,
                                     track: AVAssetTrack,
                                     consume: (CGImage) throws -> Bool) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw GoldenNuggetError("This video's frames cannot be decoded on this device.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw GoldenNuggetError("Frame decoding failed: "
                + (reader.error?.localizedDescription ?? "no reason given"))
        }
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr,
                  let image else { continue }
            if try !consume(image) { break }
        }
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw GoldenNuggetError("Frame decoding failed: "
                + (reader.error?.localizedDescription ?? "no reason given"))
        }
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: jpegQuality) else {
            throw GoldenNuggetError("A decoded frame could not be encoded as JPEG.")
        }
        return data
    }

    /// `nominalFrameRate`, with the two fallbacks a track can need.
    ///
    /// `load(…)` rather than the synchronous properties: those are still
    /// reachable but deprecated since iOS 16, and this is their last caller.
    private static func framesPerSecond(of track: AVAssetTrack) async throws -> Double {
        let nominal = Double(try await track.load(.nominalFrameRate))
        if nominal > 0 { return nominal }
        let minimum = CMTimeGetSeconds(try await track.load(.minFrameDuration))
        if minimum > 0 { return 1 / minimum }
        return 30
    }

    // MARK: - MOV conversion

    /// `convert_to_mov` — ffmpeg's `-c:v copy -c:a copy -f mov`, as
    /// `AVAssetExportPresetPassthrough`: rewrapping the container without
    /// touching a frame, which is what "copy" means for both.
    private static func exportAsMOV(_ video: URL) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard-\(UUID().uuidString).mov")
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw GoldenNuggetError("\(video.lastPathComponent) cannot be rewrapped as a .mov.")
        }
        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw GoldenNuggetError("Could not rewrap \(video.lastPathComponent) as a .mov: "
                + error.localizedDescription)
        }
        return output
    }

    // MARK: - Small helpers

    /// Write an embedded resource tree under `root`.
    private static func write(_ files: [String: Data], into root: URL) throws {
        let fm = FileManager.default
        for (relative, data) in files.sorted(by: { $0.key < $1.key }) {
            let destination = URL(fileURLWithPath: root.path + "/" + relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: destination)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
