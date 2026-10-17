#!/usr/bin/env python3
"""Turn `goldennugget.log` into the cost budget for one or more applies.

Why a log parser rather than an in-app screen: the numbers that matter are
produced by stages that run for minutes, and the way they get off the device is
a log file (the pasteboard route). A screen would only work while the app is
open; this works on the file afterwards, and it is diffable between two runs —
which is the entire point, because every optimisation in
`docs/backup-efficiency-plan.md` is judged by comparing two of these tables.

What it reads (all of it already in the log, no extra plumbing):

  ⏱ <stage>: <n>s                          per-stage wall clock (StageTimer)
  cost: … [bytes=… offered=… kept=… …]     what crossed the link (delegate)
  Pruned Manifest.db: N of M row(s) kept   prune output
  AFC media: …                             the media stage
  restore verified: …                      the device's own completion figure
  <label> attempt N/M                      a retry — i.e. a second walk
  baseline: …                              the incremental-pull decisions (§P2)

Usage:
  scripts/backup-cost-report.py ~/Downloads/goldennugget.log
  scripts/backup-cost-report.py run1.log run2.log      # one table per run set
  cat goldennugget.log | scripts/backup-cost-report.py -
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

STAGE_RE = re.compile(r"⏱ (?P<label>.+?): (?P<secs>\d+(?:\.\d+)?)s(?: |$)")
COST_RE = re.compile(
    r"cost: .*?\[bytes=(?P<bytes>\d+) total=(?P<total>\d+) offered=(?P<offered>\d+) "
    r"kept=(?P<kept>\d+) drained=(?P<drained>\d+) stored=(?P<stored>\d+)\]"
)
PRUNE_RE = re.compile(r"Pruned Manifest\.db: (?P<kept>\d+) of (?P<rows>\d+) row\(s\) kept "
                      r"\((?P<less>\d+) named by the keep-set but payload-less, "
                      r"(?P<outside>\d+) outside the keep-set\), "
                      r"(?P<orphans>\d+) orphan payload file\(s\) removed")
AFC_RE = re.compile(r"AFC media: (?P<files>\d+) file\(s\)(?:, (?P<size>.+?))?$")
AFC_SKIP_RE = re.compile(r"AFC media: (?P<files>\d+) file\(s\) already stored, "
                         r"(?P<bytes>\d+) byte\(s\) not transferred")
RESTORE_RE = re.compile(r"restore verified: the device reported (?P<pct>\d+)%")
RETRY_RE = re.compile(r"attempt (?P<n>\d+)/(?P<of>\d+) ")
BASELINE_RE = re.compile(r"baseline: (?P<what>.*)")
RUN_RE = re.compile(r"⏱ RUN (?P<what>.+?): ")


def human(n: int) -> str:
    """1024-based, one decimal. Deliberately not ByteCountFormatter's output —
    that one is locale-dependent, which is why the log also carries raw bytes."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0
    return f"{n} B"


@dataclass
class Run:
    """One apply (or reset) — everything between two `RUN …` stage timers."""

    label: str = "(unknown run)"
    line_no: int = 0
    run_seconds: float | None = None
    stages: list[tuple[str, float]] = field(default_factory=list)
    costs: list[dict] = field(default_factory=list)
    prunes: list[dict] = field(default_factory=list)
    afc: list[str] = field(default_factory=list)
    afc_files: int = 0
    afc_bytes: int = 0
    afc_skipped_files: int = 0
    afc_skipped_bytes: int = 0
    restore_pct: int | None = None
    retries: int = 0
    baseline: list[str] = field(default_factory=list)

    @property
    def seconds(self) -> float:
        return sum(s for _, s in self.stages)


def parse(lines: list[str]) -> list[Run]:
    runs: list[Run] = []
    current: Run | None = None

    for index, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        if not line:
            continue

        # A `RUN …` timer opens a new run. Everything before the first one is
        # setup (tunnel, readiness) and is reported as its own "pre-run" bucket,
        # because "the run took 90 s" and "getting to the run took 40 s" are
        # different problems.
        stage = STAGE_RE.search(line)
        stage_label = None
        stage_secs = None
        if stage and " elapsed — " not in line:
            stage_label = stage.group("label")
            stage_secs = float(stage.group("secs"))

        # The `RUN …` timer is the run's own wall clock, not one of its stages:
        # counting it as a stage makes it the longest one every time and the
        # verdict line then says nothing. It is reported as the total instead.
        opened = False
        if "⏱ RUN " in line:
            match = RUN_RE.search(line)
            current = Run(label=f"RUN {match.group('what')}" if match else "RUN (unknown)",
                          line_no=index, run_seconds=stage_secs)
            runs.append(current)
            opened = True
        elif current is None:
            current = Run(label="pre-run (tunnel / readiness)")
            runs.append(current)

        if stage_label and not opened:
            current.stages.append((stage_label, stage_secs))

        match = COST_RE.search(line)
        if match:
            current.costs.append({k: int(v) for k, v in match.groupdict().items()})

        match = PRUNE_RE.search(line)
        if match:
            current.prunes.append({k: int(v) for k, v in match.groupdict().items()})

        match = AFC_SKIP_RE.search(line)
        if match:
            current.afc_skipped_files += int(match.group("files"))
            current.afc_skipped_bytes += int(match.group("bytes"))
            current.afc.append(line.strip())

        match = AFC_RE.search(line)
        if match:
            current.afc_files = max(current.afc_files, int(match.group("files")))
            current.afc.append(line.strip())

        match = RESTORE_RE.search(line)
        if match:
            current.restore_pct = int(match.group("pct"))

        if RETRY_RE.search(line):
            current.retries += 1

        match = BASELINE_RE.search(line)
        if match:
            current.baseline.append(match.group("what"))

    return runs


def report(run: Run, width: int = 78) -> str:
    out: list[str] = []
    out.append("")
    out.append(f"── {run.label}  (log line {run.line_no}) " + "─" * max(0, width - len(run.label) - 20))

    if run.stages:
        out.append("  stage                                   seconds")
        for label, secs in sorted(run.stages, key=lambda item: -item[1]):
            out.append(f"    {label[:38]:<38}  {secs:8.1f}")
        out.append(f"    {'TOTAL (stages)':<38}  {run.seconds:8.1f}")
        if run.run_seconds is not None:
            out.append(f"    {'run wall clock':<38}  {run.run_seconds:8.1f}"
                       + f"   (unaccounted {run.run_seconds - run.seconds:.1f}s)")

    if run.costs:
        out.append("")
        out.append("  exchange cost")
        for cost in run.costs:
            out.append(
                f"    wire {human(cost['bytes']):>10}  "
                f"offered {cost['offered']:>6}  kept {cost['kept']:>5}  "
                f"drained {cost['drained']:>6}  stored {human(cost['stored']):>10}"
            )
        wires = sum(c["bytes"] for c in run.costs)
        offered = sum(c["offered"] for c in run.costs)
        drained = sum(c["drained"] for c in run.costs)
        out.append(f"    {'total':<15} {human(wires):>10}  "
                   f"offered {offered:>6}  drained {drained:>6}")
        if offered and drained:
            out.append(f"    drain share: {100.0 * drained / offered:.1f}% of the offered files "
                       f"were transferred and thrown away")

    if run.prunes:
        out.append("")
        out.append("  prune")
        for prune in run.prunes:
            out.append(f"    kept {prune['kept']} of {prune['rows']} row(s); "
                       f"{prune['less']} payload-less, {prune['outside']} outside the keep-set, "
                       f"{prune['orphans']} orphan payload file(s) removed")

    if run.afc:
        out.append("")
        out.append("  AFC media")
        if run.afc_files:
            out.append(f"    surveyed {run.afc_files} file(s)")
        if run.afc_skipped_files:
            out.append(f"    skipped   {run.afc_skipped_files} file(s) / "
                       f"{human(run.afc_skipped_bytes)} already stored (no transfer)")
        for line in run.afc[:6]:
            out.append(f"    {line[:100]}")

    if run.baseline:
        out.append("")
        out.append("  baseline (incremental pull)")
        for line in run.baseline:
            out.append(f"    {line[:100]}")

    out.append("")
    out.append(f"  restore: " + (f"device reported {run.restore_pct}%"
                                if run.restore_pct is not None
                                else "no completion line — the run did not reach the device's end"))
    out.append(f"  retries: {run.retries}"
               + ("  (each one repeats a handshake, and a backup retry repeats the walk)"
                  if run.retries else ""))

    # One verdict line, because the whole point of the table is to say where the
    # time went without the reader having to sort the column themselves.
    if run.stages:
        worst = max(run.stages, key=lambda item: item[1])
        share = 100.0 * worst[1] / run.seconds if run.seconds else 0.0
        out.append("")
        out.append(f"  → {worst[0]} is {share:.0f}% of this run ({worst[1]:.1f}s of "
                   f"{run.seconds:.1f}s)")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    paths = argv[1:]
    if not paths:
        print(__doc__)
        return 2

    lines: list[str] = []
    for path in paths:
        if path == "-":
            lines += sys.stdin.read().splitlines()
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                lines += handle.read().splitlines()
        except OSError as error:
            print(f"error: cannot read {path}: {error}", file=sys.stderr)
            return 1

    runs = parse(lines)
    if not runs:
        print("no run found — is this a goldennugget.log?")
        return 1

    print(f"goldennugget.log — {len(lines)} line(s), {len(runs)} run(s) found")
    for run in runs:
        print(report(run))

    comparable = [r for r in runs if r.costs]
    if len(comparable) >= 2:
        print("")
        print("── comparison")
        first, last = comparable[0], comparable[-1]
        fw = sum(c["bytes"] for c in first.costs)
        lw = sum(c["bytes"] for c in last.costs)
        print(f"  wire bytes: {human(fw)} → {human(lw)}"
              + (f"  ({100.0 * (lw - fw) / fw:+.1f}%)" if fw else ""))
        print(f"  seconds:    {first.seconds:.1f} → {last.seconds:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
