// Regression harness for the tunnel-crawl verdict in Nugget/Core/StallGuard.swift.
//
// The rule is "the tunnel is stuck", and it has to accept every shape of stuck
// while leaving healthy and recovering streams alone.  Two of those shapes are
// easy to miss, and both were missed in production:
//
//   A  STATIC hole   the device retransmits the same out-of-window segment, so
//                    `seq` never moves, `expected` never moves, the gap is
//                    byte-for-byte constant and only the counter climbs.
//                    A growth requirement rejects exactly this shape.
//   D  trickle       the hole closes, but below the rate floor (3.9 KB/s).  Not
//                    delivery worth keeping.
//
// Run:  xcrun swiftc -O -o /tmp/crawl-verdict-harness scripts/crawl-verdict-harness.swift \
//         && /tmp/crawl-verdict-harness
//
// Numbers are taken from the 2026-09-19 goldennugget.log runs; `pollSeconds` is 5 s in the
// real guard, and the streams below step at the same rate.
//
// Expected output (current rule):
//   A new: VERDICT   (old: no verdict — the bug this harness exists for)
//   B new: VERDICT
//   C new: no verdict
//   D new: VERDICT   (below the floor is a crawl by definition)
//   E new: no verdict
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// Replays StallGuard's crawl decision against three synthetic poll streams whose
// numbers are taken from the 2026-09-19 goldennugget.log runs.  Purpose: show that the
// OLD term (gap must grow, +8 KB) rejects the static-gap shape that wedged a run
// at 52 % for 200 s, and that the NEW term (gap must not be closing) accepts both
// shapes while still leaving a healthy stream alone.

struct Sample { let at: Double; let outOfOrder: Int; let expected: UInt64?; let seq: UInt64? }

func gapOf(_ s: Sample) -> UInt64? {
    guard let e = s.expected, let q = s.seq, q > e else { return nil }
    return q - e
}

/// Mirrors the decision block: window trim, then the verdict terms.
func decide(_ polls: [Sample], label: String,
            crawlSeconds: Double, floor: Double, minGap: UInt64,
            useOldGrowthTerm: Bool) -> String? {
    var delivery: [Sample] = []
    for s in polls {
        // healthy instant rate clears the window
        if let prev = delivery.last,
           let pe = prev.expected, let e = s.expected {
            let dt = s.at - prev.at
            let moved = e > pe ? e - pe : 0
            let instant = dt > 0 ? Double(moved) / dt : 0
            if instant >= floor { delivery.removeAll() }
        }
        if s.expected != nil { delivery.append(s) }
        let horizon = s.at - crawlSeconds * 3
        while let oldest = delivery.first, oldest.at < horizon { delivery.removeFirst() }

        if let first = delivery.first, let last = delivery.last {
            let span = last.at - first.at
            let segments = last.outOfOrder - first.outOfOrder
            if span >= crawlSeconds, segments >= 8,
               let gap = gapOf(s), gap >= minGap, let startGap = gapOf(first) {
                let startExpected = first.expected ?? 0
                let endExpected = last.expected ?? 0
                let delivered = endExpected > startExpected ? endExpected - startExpected : 0
                let rate = Double(delivered) / span
                if rate < floor {
                    if useOldGrowthTerm {
                        // OLD: require the backlog to have GROWN by >= 8 KB.
                        if gap > startGap, gap - startGap >= 8 * 1024 {
                            return "\(label): VERDICT (rate \(Int(rate / 1024)) KB/s, gap \(gap / 1024) KB) at t=\(Int(s.at))s"
                        }
                    } else {
                        // NEW: require the backlog to NOT be closing.
                        let recoverable = UInt64(floor * crawlSeconds)
                        if startGap <= gap + recoverable {
                            return "\(label): VERDICT (rate \(Int(rate / 1024)) KB/s, gap \(gap / 1024) KB) at t=\(Int(s.at))s"
                        }
                    }
                }
            }
        }
    }
    return "\(label): no verdict in \(Int(polls.last?.at ?? 0))s"
}

let crawlSeconds = 15.0
let floor = 16 * 1024.0
let minGap: UInt64 = 128 * 1024

/// Runs an array of (expected, seq, outOfOrder-delta) steps at 5 s per poll,
/// exactly the guard's `pollSeconds`.
func stream(_ steps: Int, expectedStart: UInt64, expectedStep: UInt64,
            seqStart: UInt64, seqStep: UInt64, oooStep: Int) -> [Sample] {
    var expected = expectedStart, seq = seqStart, ooo = 0
    var out: [Sample] = []
    for i in 0..<steps {
        out.append(Sample(at: Double(i) * 5, outOfOrder: ooo, expected: expected, seq: seq))
        expected &+= expectedStep
        seq &+= seqStep
        ooo += oooStep
    }
    return out
}

print("— shape A: STATIC hole (device retransmits the same segment; the 52 % run)")
let staticHole = stream(80, expectedStart: 10_000_000, expectedStep: 0,
                        seqStart: 12_621_440, seqStep: 0, oooStep: 14)
print("   " + (decide(staticHole, label: "old", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: true) ?? "?"))
print("   " + (decide(staticHole, label: "new", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: false) ?? "?"))

print("— shape B: GROWING hole (device keeps pushing behind the loss; the earlier runs)")
let growingHole = stream(80, expectedStart: 10_000_000, expectedStep: 0,
                         seqStart: 12_621_440, seqStep: 70_000, oooStep: 14)
print("   " + (decide(growingHole, label: "old", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: true) ?? "?"))
print("   " + (decide(growingHole, label: "new", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: false) ?? "?"))

print("— shape C: HEALTHY stream (delivering fast, one reorder per poll)")
let healthy = stream(80, expectedStart: 10_000_000, expectedStep: 500_000,
                     seqStart: 10_000_020, seqStep: 500_000, oooStep: 1)
print("   " + (decide(healthy, label: "old", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: true) ?? "?"))
print("   " + (decide(healthy, label: "new", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: false) ?? "?"))

print("— shape D: SLOW TRICKLE — hole closing at 3.9 KB/s, BELOW the 16 KB/s floor")
let trickle = stream(80, expectedStart: 10_000_000, expectedStep: 20_000,
                     seqStart: 12_621_440, seqStep: 0, oooStep: 2)
print("   " + (decide(trickle, label: "old", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: true) ?? "?"))
print("   " + (decide(trickle, label: "new", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: false) ?? "?"))

print("— shape E: REAL RECOVERY — hole closing at 41 KB/s, ABOVE the floor")
let recovery = stream(80, expectedStart: 10_000_000, expectedStep: 204_800,
                      seqStart: 12_621_440, seqStep: 0, oooStep: 2)
print("   " + (decide(recovery, label: "old", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: true) ?? "?"))
print("   " + (decide(recovery, label: "new", crawlSeconds: crawlSeconds, floor: floor,
                      minGap: minGap, useOldGrowthTerm: false) ?? "?"))
