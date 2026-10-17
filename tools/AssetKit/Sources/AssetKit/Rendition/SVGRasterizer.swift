import Foundation

/// Produces PNG bytes from an SVG source at a requested pixel size.
///
/// xcasset-compiler does not ship its own SVG renderer. SVG is a large spec
/// (gradients, masks, filters, CSS, embedded raster images, text) and any
/// vendored renderer would either re-implement a substantial chunk of it or
/// drop support for constructs real asset catalogs use. Pushing the choice
/// to the caller via this protocol keeps the library dependency-light and
/// lets sophisticated consumers (xtool, app-specific tooling) supply
/// whichever rasteriser fits their platform footprint.
///
/// The default implementation is `RsvgConvertRasterizer`, which shells out
/// to `rsvg-convert` from the `librsvg2-tools` package. It works on every
/// host that ships librsvg (essentially every Linux distro and macOS via
/// Homebrew). Replace it by passing a different `SVGRasterizer` to
/// `XCAssetCompiler.init`.
public protocol SVGRasterizer: Sendable {
    /// Rasterises `svgData` to a PNG image of exactly `pixelWidth × pixelHeight`
    /// pixels. Throws if rasterisation fails for any reason; the caller wraps
    /// the underlying error into `XCAssetCompilerError.svgRasterizationFailed`
    /// before surfacing it to the user.
    func rasterize(svgData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data
}

/// Default `SVGRasterizer` implementation: shells out to `rsvg-convert`.
///
/// `rsvg-convert` ships with librsvg, which is available on essentially
/// every mainstream platform (`apt install librsvg2-tools`, `dnf install
/// librsvg2-tools`, `brew install librsvg`). librsvg has full SVG support
/// including gradients, masks, filters, and CSS, so the rasterised output
/// is faithful to what designers produce in tools like Sketch or Figma.
///
/// Output bytes are deterministic per librsvg version on a given host. The
/// resulting compiled `Assets.car` is NOT byte-equal across hosts running
/// different librsvg versions for SVG-bearing catalogs; the vector
/// rendition (DWAR-wrapped XML) remains byte-equal regardless.
public struct RsvgConvertRasterizer: SVGRasterizer {
    /// Absolute path to the `rsvg-convert` binary. Defaults to letting
    /// `/usr/bin/env` resolve it from `PATH`; override if your install
    /// puts the binary somewhere `PATH` does not cover.
    public var executablePath: String

    public init(executablePath: String = "/usr/bin/env") {
        self.executablePath = executablePath
    }

    public func rasterize(svgData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        // When executablePath is /usr/bin/env, prepend "rsvg-convert" so env
        // resolves it from PATH; otherwise the caller has already given us
        // the full path and we just pass the format/size flags.
        var arguments: [String] = []
        if (executablePath as NSString).lastPathComponent == "env" {
            arguments.append("rsvg-convert")
        }
        arguments.append(contentsOf: [
            "--format=png",
            "--width=\(pixelWidth)",
            "--height=\(pixelHeight)",
        ])
        // We always pass both --width and --height matching the SVG's
        // intrinsic aspect ratio (pixel dims = intrinsic × scale factor),
        // so rsvg-convert produces exactly the requested pixel grid. No
        // aspect-ratio flag is needed; passing one would also be version-
        // sensitive across librsvg releases.
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RasterizationError(
                "Could not launch rsvg-convert via \(executablePath); "
                + "install librsvg2-tools (Linux) or `brew install librsvg` (macOS), "
                + "or supply an alternative SVGRasterizer. Underlying error: \(error)"
            )
        }

        // Stream the SVG bytes into stdin on a background queue so we can
        // drain stdout concurrently. Sequential write-then-read deadlocks
        // once the SVG exceeds the OS pipe buffer (~64 KiB on Linux,
        // smaller on macOS): rsvg-convert blocks writing PNG bytes into a
        // full stdout pipe nobody is reading, while we block writing the
        // tail of the SVG into a full stdin pipe nobody is draining.
        let stdinHandle = stdinPipe.fileHandleForWriting
        let writeErrorBox = ErrorBox()
        let writeSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writeSemaphore.signal() }
            do {
                try stdinHandle.write(contentsOf: svgData)
                try stdinHandle.close()
            } catch {
                writeErrorBox.set(error)
                try? stdinHandle.close()
            }
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        writeSemaphore.wait()
        process.waitUntilExit()

        if let writeError = writeErrorBox.get() {
            throw RasterizationError("Failed to stream SVG to rsvg-convert: \(writeError)")
        }

        guard process.terminationStatus == 0 else {
            throw RasterizationError("rsvg-convert exited \(process.terminationStatus): \(String(decoding: stderr, as: UTF8.self))")
        }
        return stdout
    }

    /// Internal error type thrown by rasteriser steps. The catalog compiler
    /// catches anything thrown by a `SVGRasterizer.rasterize` call and wraps
    /// the description into `XCAssetCompilerError.svgRasterizationFailed`,
    /// so the specific shape of this type is implementation detail.
    private struct RasterizationError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// Lock-protected box for passing an Error across the stdin-writer
    /// thread boundary without tripping Swift 6's sendability checks.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ error: Error) { lock.lock(); defer { lock.unlock() }; self.error = error }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }
}
