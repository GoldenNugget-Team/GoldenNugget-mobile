// Regression harness for the two `PosterBoardConverter` predicates the
// reference changed after this port was written:
//
//   1. `planeUnits` — a legacy plane whose `index.xml` ships NEITHER
//      `unitsInPixelsInPlayer` NOR `documentWidth` used to be read as a pixel
//      canvas. `fitScale` then divides the plane's **point-space** `bounds` by
//      the pixel scale and emits a 3x `scale()`, so a 390x844 canvas "becomes"
//      130x281 points and the converted wallpaper arrives zoomed. The reference
//      flipped the fallback to `false` (2880cd7); the rebuild path already
//      classifies a missing flag as a non-pixel logical poster.
//
//   2. `solidBackgroundColor` — the sweep used to return the FIRST match. The
//      topmost colour is the last one in document order, and the first match is
//      routinely the root element's opacity-0 placeholder rather than the fill
//      anyone sees, so a colour-only plane got rendered in the wrong colour
//      (e674cb9).
//
// Neither needs a device, and both are pure string/plist decisions, so this
// harness concatenates the shipping source rather than re-implementing it —
// the code under test is the code that runs.
//
// Run:
//   mkdir -p /tmp/pbconv2 \
//     && cat Nugget/Core/PosterBoardConverter.swift scripts/converter-units-check.swift \
//        > /tmp/pbconv2/main.swift \
//     && xcrun swiftc -O -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
//          -target arm64-apple-ios26.0 -swift-version 5 /tmp/pbconv2/main.swift \
//          -o /tmp/pbconv2/check \
//     && /tmp/pbconv2/check
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// ZIPFoundation is only reached by the archive-reading paths this harness does
// not call, and the module is a Linux-built xcframework the SDK search path here
// does not carry. Stubbed so the harness compiles as a single concatenation —
// the predicates under test are pure string/plist work and never touch a zip, so
// nothing below is reachable from a passing run.
let defaultReadChunkSize = 65_536

struct Entry {
    let path: String
    let isDirectory: Bool
}

enum ArchiveAccessMode { case read }

struct Archive: Sequence {
    init(url: URL, accessMode: ArchiveAccessMode) throws {}
    func iterate(_ body: (Entry) throws -> Void) throws {}
    func extract(_ entry: Entry, bufferSize: Int,
                  _ body: (Data) throws -> Void) throws -> Bool { return false }
    /// Empty on purpose: every archive path is unreachable from this harness.
    func makeIterator() -> AnyIterator<Entry> { AnyIterator { nil } }
}

struct GoldenNuggetError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

var passCount = 0
var failCount = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passCount += 1
        print("  ok   \(label)")
    } else {
        failCount += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : ": \(extra)")")
    }
}

// MARK: - 1. planeUnits

print("== a plane whose index carries neither units nor documentWidth is points ==")

// The legacy third-party shape: the CAML is authored in the logical screen
// space and the index says nothing at all.
check("an empty index is points, not pixels",
      PosterBoardConverter.planeUnits([:], logicalWidth: 390) == false)

// The reference's own regression case is a 390x844 point canvas. `fitScale`
// would divide those bounds by 3 and emit scale(3) — the zoom.
check("a bare index on a 390-wide screen is points",
      PosterBoardConverter.planeUnits(["someUnrelatedKey": "x"], logicalWidth: 390) == false)

print("\n== the authoritative and inferred cases are unchanged ==")

// `unitsInPixelsInPlayer` wins whenever it is present, either way.
check("an explicit true is pixels",
      PosterBoardConverter.planeUnits(["unitsInPixelsInPlayer": true], logicalWidth: 390))
check("an explicit false is points",
      PosterBoardConverter.planeUnits(["unitsInPixelsInPlayer": false], logicalWidth: 390) == false)

// The iOS 17 "flow" canvas: 3174 wide against a 390 logical width.
check("a document far wider than the screen is pixels",
      PosterBoardConverter.planeUnits(["documentWidth": 3174], logicalWidth: 390))
check("a document barely wider than the screen is points",
      PosterBoardConverter.planeUnits(["documentWidth": 391], logicalWidth: 390) == false)
check("a document at the screen width is points",
      PosterBoardConverter.planeUnits(["documentWidth": 390], logicalWidth: 390) == false)

// The explicit flag outranks the width inference: a pixel canvas whose width
// happens to sit below the threshold still reads as pixels.
check("the explicit flag outranks the width inference",
      PosterBoardConverter.planeUnits(["unitsInPixelsInPlayer": true,
                                      "documentWidth": 390], logicalWidth: 390))

// A `documentWidth` that is not a number must not become a pixel verdict.
check("a non-numeric documentWidth falls back to points",
      PosterBoardConverter.planeUnits(["documentWidth": "3174"], logicalWidth: 390) == false)

// With no logical width to compare against, there is nothing to infer from.
check("no logical width and no flag is points",
      PosterBoardConverter.planeUnits(["documentWidth": 3174], logicalWidth: 0) == false)

print("\n== the zoom itself: a bare-index plane gets no fit transform ==")
// The end-to-end shape of the bug, stated on the tag rather than on the
// predicate: `fitScale` is what turns the unit decision into a `transform=`.
// The two calls differ **only** in `unitsInPixels`, which is exactly what
// `planeUnits` decides — so this is the regression, isolated.
let pointSpaceTag = "<CALayer bounds=\"0 0 390 844\" contentsFormat=\"RGBA8\" "
    + "geometryFlipped=\"0\" hidden=\"0\" name=\"Background\">"
let pixelSpaceTag = "<CALayer bounds=\"0 0 3174 3174\" contentsFormat=\"RGBA8\" "
    + "geometryFlipped=\"0\" hidden=\"0\" name=\"Background\">"

let pointsScale = PosterBoardConverter.fitScale(tag: pointSpaceTag, docWidth: 390, docHeight: 844,
                                                unitsInPixels: false, pixelScale: 3)
check("a plane read as points is not rescaled (scale == 1)",
      abs(pointsScale - 1.0) < 0.0001, "scale was \(pointsScale)")
check("no transform is added to a plane read as points",
      !PosterBoardConverter.addingScale(pointSpaceTag, scale: pointsScale).contains("transform="),
      PosterBoardConverter.addingScale(pointSpaceTag, scale: pointsScale))

// The pixel canvas it *should* still rescale: 3174 points across a 390 screen.
let pixelScale = PosterBoardConverter.fitScale(tag: pixelSpaceTag, docWidth: 390, docHeight: 844,
                                               unitsInPixels: true, pixelScale: 3)
check("a plane read as pixels is still rescaled", abs(pixelScale - 1.0) > 0.0001,
      "scale was \(pixelScale)")

// And the wiring: `planeUnits` feeding `fitScale` is what removed the 3x. The
// old fallback made a bare index claim pixels, which is the zoom.
let bareIndexVerdict = PosterBoardConverter.planeUnits([:], logicalWidth: 390)
check("a bare index no longer routes a point-space plane into the rescale",
      PosterBoardConverter.fitScale(tag: pointSpaceTag, docWidth: 390, docHeight: 844,
                                    unitsInPixels: bareIndexVerdict, pixelScale: 3) == 1.0)

// MARK: - 2. solidBackgroundColor

print("\n== the solid background colour is the last match in document order ==")

// The two sweeps run in a fixed order — every `backgroundColor="…"` attribute
// first, then every `<backgroundColor … value="…">` element — and each keeps its
// own LAST match. They are **independent passes over the whole document**, not
// one positional walk, so the element sweep's verdict is final whenever the
// document has any element fill at all. Pinned because that is the shape the
// reference has: "attribute beats element" is the docstring's shorthand, while
// the code's actual rule is "sweep, then take the last thing the second sweep
// saw".
//
// The practical consequence, and the shape this whole path exists for: a legacy
// plane carrying the root's opacity-0 magenta placeholder resolves to magenta
// unless the document has no element fill at all.
let placeholderPresent = """
<caml>
  <sublayers>
    <CALayer name="Under" backgroundColor="0.2 0.4 0.6 1"/>
  </sublayers>
  <backgroundColor opacity="0" value="1 0 1"/>
</caml>
"""
check("a document with any element fill resolves to that element's colour",
      PosterBoardConverter.solidBackgroundColor(of: placeholderPresent)?.r == 255
      && PosterBoardConverter.solidBackgroundColor(of: placeholderPresent)?.b == 255,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: placeholderPresent)))")

// A sublayer attribute alone resolves — but ONLY when the document has no
// `<backgroundColor>` element at all. The two sweeps are independent passes, not
// one positional walk, so any element match overwrites the attribute's verdict
// no matter where the two sit in the text. That is the reference's rule and this
// port reproduces it verbatim; asserted so the asymmetry is on record rather than
// discovered later as a bug.
let attributeOnly = """
<caml>
  <sublayers>
    <CALayer name="Background" backgroundColor="0.2 0.4 0.6 1"/>
  </sublayers>
</caml>
"""
check("an attribute-only document resolves (0.2/0.4/0.6 -> 51/102/153)",
      PosterBoardConverter.solidBackgroundColor(of: attributeOnly)?.r == 51
      && PosterBoardConverter.solidBackgroundColor(of: attributeOnly)?.g == 102
      && PosterBoardConverter.solidBackgroundColor(of: attributeOnly)?.b == 153,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: attributeOnly)))")

let elementBeatsAttribute = """
<caml>
  <backgroundColor opacity="0" value="1 0 1"/>
  <sublayers>
    <CALayer name="Background" backgroundColor="0.2 0.4 0.6 1"/>
  </sublayers>
</caml>
"""
check("any element match overwrites the attribute's verdict (two independent sweeps)",
      PosterBoardConverter.solidBackgroundColor(of: elementBeatsAttribute)?.r == 255,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: elementBeatsAttribute)))")

// Two real sublayers: the later one is visually on top, so it is the colour the
// plane reads as.
let stacked = """
<caml>
  <sublayers>
    <CALayer name="Under" backgroundColor="1 0 0 1"/>
    <CALayer name="Over" backgroundColor="0 0 1 1"/>
  </sublayers>
</caml>
"""
check("the LAST attribute match wins (later in document order is on top)",
      PosterBoardConverter.solidBackgroundColor(of: stacked)?.b == 255
      && PosterBoardConverter.solidBackgroundColor(of: stacked)?.r == 0,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: stacked)))")

// An attribute sweep that matches nothing must not clear an element verdict.
let elementOnly = """
<caml>
  <CALayer>
    <backgroundColor opacity="1" value="0 1 0"/>
    <sublayers/>
  </CALayer>
</caml>
"""
check("an element-only plane still resolves", PosterBoardConverter.solidBackgroundColor(of: elementOnly)?.g == 255)

// Two element fills: the last one wins.
let twoElements = """
<caml>
  <backgroundColor opacity="0" value="1 0 1"/>
  <sublayers>
    <backgroundColor opacity="1" value="0 0 1"/>
  </sublayers>
</caml>
"""
check("the LAST element match wins",
      PosterBoardConverter.solidBackgroundColor(of: twoElements)?.b == 255
      && PosterBoardConverter.solidBackgroundColor(of: twoElements)?.r == 0,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: twoElements)))")

// Nothing to find is still nil — the loop rewrite must not invent a colour.
check("a plane with no colour resolves to nil",
      PosterBoardConverter.solidBackgroundColor(of: "<caml><CALayer/></caml>") == nil)

// A colour that does not parse is skipped, not returned, and the sweep keeps
// going: a later valid one still resolves.
let oneBad = """
<caml>
  <CALayer backgroundColor="not a colour"/>
  <CALayer backgroundColor="0 0 0 1"/>
</caml>
"""
check("an unparsable match is skipped and the sweep continues",
      PosterBoardConverter.solidBackgroundColor(of: oneBad)?.r == 0
      && PosterBoardConverter.solidBackgroundColor(of: oneBad)?.g == 0
      && PosterBoardConverter.solidBackgroundColor(of: oneBad)?.b == 0,
      "got \(String(describing: PosterBoardConverter.solidBackgroundColor(of: oneBad)))")

print("\n\(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? 0 : 1)