#!/usr/bin/env python3
"""Differential test of the page-reset payload plan against the reference implementation.

The reset's verification was, until now, a *hand* diff: somebody read
`device_manager._reset_tweaks` and `add_skip_setup` and confirmed the file list, the
order, the stock dict and the per-branch null bytes matched.  That is the weakest kind
of evidence in this port, because nothing re-runs it: the reference can change and the
diff stays green in the reader's head.  (It had already gone stale once -- the reset's
skip-setup files were emitted *first* while the reference appends them last, and on iOS
27 the reference's own gate excludes them entirely unless the Daemons page is ticked.
`scripts/reset-port-diff.py` is what caught it.)

This script re-derives both sides mechanically and compares them:

  reference  `src/devicemanagement/device_manager.py`   -- parsed with `ast`
            `src/tweaks/basic_plist_locations.py`       -- `FileLocation` member -> path
  this port  `Nugget/Core/TweakReset.swift`             -- the page table + stock dict
            `Nugget/Core/GoldenNuggetEngine.swift`      -- how the payloads are ordered

`ast` rather than import, so no PySide6 / pymobiledevice3 is needed and the check runs on
a machine that has never had the reference's dependencies installed.  The Python side is
read as source, never executed -- importing `device_manager` would execute the module and
its imports, which is how a test starts having side effects.

What is compared, and what is not:

  COMPARED   the per-page file lists and their order; which page writes the non-null
             file; the stock `disabled.plist` dict (keys, values *and* bool/int types);
             the null bytes per version branch; whether the skip-setup files are gated,
             and where they land in the payload order.
  NOT        anything that needs a device or a running process: the Manifest.db vs MBDB
  COMPARED  fork, the backup pull, the prune set, the restore itself, and the
             no-psysbackup decision.  Those are in `Nugget/Core/TweakReset.swift`'s doc
             comment and `docs/tweak-port.md` §2.4, and are verified by reading the
             reference, not by this script.

Usage:
    scripts/reset-port-diff.py [--goldennugget ~/projects/GoldenNugget] [-v]
"""

import argparse
import ast
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CANDIDATE_ROOTS = ("~/GoldenNugget", "~/projects/GoldenNugget")


# ----------------------------------------------------------------------------------- #
# reference side
# ----------------------------------------------------------------------------------- #

def find_reference(explicit: str | None) -> pathlib.Path:
    if explicit:
        root = pathlib.Path(explicit).expanduser()
        if not (root / "src/devicemanagement/device_manager.py").is_file():
            sys.exit(f"error: {root} does not look like the reference tree")
        return root
    for candidate in CANDIDATE_ROOTS:
        root = pathlib.Path(candidate).expanduser()
        if (root / "src/devicemanagement/device_manager.py").is_file():
            return root
    sys.exit("error: reference tree not found; pass --goldennugget PATH")


def file_location_paths(tree: ast.Module) -> dict[str, str]:
    """`FileLocation` enum member name -> the path its `.value` is."""
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "FileLocation":
            out: dict[str, str] = {}
            for stmt in node.body:
                if not isinstance(stmt, ast.Assign) or not isinstance(stmt.value, ast.Constant):
                    continue
                if not isinstance(stmt.targets[0], ast.Name):
                    continue
                if isinstance(stmt.value.value, str):
                    out[stmt.targets[0].id] = stmt.value.value
            return out
    sys.exit("error: FileLocation enum not found in the reference")


def find_function(tree: ast.Module, name: str) -> ast.FunctionDef | ast.AsyncFunctionDef:
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    sys.exit(f"error: {name}() not found in the reference")


def unparse(node: ast.AST) -> str:
    return ast.unparse(node)


class Reference:
    """Everything this script compares, read out of the reference's source."""

    def __init__(self, root: pathlib.Path):
        self.root = root
        dm_path = root / "src/devicemanagement/device_manager.py"
        loc_path = root / "src/tweaks/basic_plist_locations.py"
        self.dm_source = dm_path.read_text(encoding="utf-8")
        self.dm = ast.parse(self.dm_source)
        self.paths = file_location_paths(ast.parse(loc_path.read_text(encoding="utf-8")))
        self._read_reset()
        self._read_skip_setup_gate()

    # -- _reset_tweaks ------------------------------------------------------------- #

    def _read_reset(self) -> None:
        fn = find_function(self.dm, "_reset_tweaks")

        # per page: the files it nulls, and whether it sets uses_domains
        self.nulls: dict[str, list[str]] = {}
        self.pages_setting_uses_domains: list[str] = []
        self.stock_daemons: dict[str, bool] | None = None
        self.null_fork: dict[str, str] = {}          # branch -> python expression
        self.skip_setup_call_line: int | None = None
        self.null_loop_line: int | None = None
        self.restore_call_line: int | None = None

        self._walk_pages(fn.body, None)
        self._read_null_loop(fn)

        self.dm_lines = self.dm_source.splitlines()
        for i, line in enumerate(self.dm_lines, 1):
            if "add_skip_setup(files_to_restore, uses_domains)" in line:
                self.skip_setup_call_line = i
            if "start_restore(files_to_restore" in line:
                self.restore_call_line = i

    def _walk_pages(self, body: list[ast.stmt], page: str | None) -> None:
        """Source-ordered descent, tracking which `elif page == Page.X` we are inside.

        `ast.walk` is breadth-first, so the page a `files_to_null.append` belongs to
        cannot be tracked with it -- the first version of this script read every page
        as empty and passed the comparison vacuously.
        """
        for node in body:
            if isinstance(node, ast.If) and _is_page_test(node.test, "Page."):
                inner = node.test.comparators[0].attr
                self.nulls.setdefault(inner, [])
                self._walk_pages(node.body, inner)
                self._walk_pages(node.orelse, inner)
                continue
            if isinstance(node, (ast.For, ast.While, ast.With, ast.Try)):
                self._walk_pages(getattr(node, "body", []), page)
                self._walk_pages(getattr(node, "orelse", []), page)
                continue
            if isinstance(node, ast.Assign):
                names = [t.id for t in node.targets if isinstance(t, ast.Name)]
                if "default_daemons" in names and isinstance(node.value, ast.Dict):
                    self.stock_daemons = _const_dict(node.value)
                if "uses_domains" in names and isinstance(node.value, ast.Constant) \
                        and node.value.value is True and page:
                    self.pages_setting_uses_domains.append(page)
            # `files_to_null.append(FileLocation.springboard.value)` sits in the page
            # branch, *before* the null loop drains the list -- so it is collected here
            # rather than in _read_null_loop, which only reads the fork.
            for call in ast.walk(node):
                if isinstance(call, ast.Call) and unparse(call.func) == "files_to_null.append" \
                        and page:
                    member = _file_location_member(call.args[0])
                    if member:
                        self.nulls[page].append(member)

    def _read_null_loop(self, fn) -> None:
        """The loop that drains `files_to_null`, and the per-branch null bytes.

        Two reference shapes are supported: the current one, where the loop body
        forks directly on `if is_ios27:` (`plistlib.dumps({})` vs `b""`), and the
        older one that captured the original plist first and forked inside the
        `orelse` of `if original is not None:`. The reference dropped the capture
        when it dropped psysbackup; both are read so a diff against either tree
        still works.
        """
        for node in ast.walk(fn):
            if not (isinstance(node, ast.For) and unparse(node.target) == "file_path"):
                continue
            self.null_loop_line = node.lineno
            unconditional = _contents_expr(node.body)
            if unconditional != "<not found>":
                self.null_fork = {"ios27": unconditional, "ios26": unconditional}
            for stmt in node.body:
                if not isinstance(stmt, ast.If):
                    continue
                if _is_ios27_test(stmt.test):
                    self.null_fork["ios27"] = _contents_expr(stmt.body)
                    self.null_fork["ios26"] = _contents_expr(stmt.orelse)
                elif _is_not_none(stmt.test):
                    for arm in stmt.orelse:
                        if isinstance(arm, ast.If) and _is_version_ge_27(arm.test):
                            self.null_fork["ios27"] = _contents_expr(arm.body)
                            for inner in arm.orelse:
                                if isinstance(inner, ast.Assign):
                                    self.null_fork["ios26"] = _contents_expr([inner])
                        elif isinstance(arm, ast.Assign):
                            self.null_fork["ios26"] = _contents_expr([arm])

    # -- add_skip_setup ------------------------------------------------------------ #

    def _read_skip_setup_gate(self) -> None:
        fn = find_function(self.dm, "add_skip_setup")
        gate = None
        for node in ast.walk(fn):
            if isinstance(node, ast.If):
                test = unparse(node.test)
                if "restoring_domains" in test:
                    gate = test
                    break
        self.skip_setup_gate = gate
        if gate is None:
            sys.exit("error: add_skip_setup's `restoring_domains` gate not found")
        # the paths the two files are written to, in append order
        self.skip_setup_paths: list[str] = []
        for node in ast.walk(fn):
            if isinstance(node, ast.Call) and unparse(node.func) == "FileToRestore":
                for kw in node.keywords:
                    if kw.arg == "restore_path" and isinstance(kw.value, ast.Constant):
                        self.skip_setup_paths.append(kw.value.value)

    def null_paths(self, page: str) -> list[str]:
        return [self.paths[m] for m in self.nulls.get(page, [])]

    def skip_setup_payload_index(self) -> str:
        """Where the skip-setup files land: 'last' / 'first' / 'between' / 'unknown'."""
        if not self.skip_setup_call_line or not self.restore_call_line:
            return "unknown"
        if self.skip_setup_call_line > self.restore_call_line:
            return "after restore (unexpected)"
        if self.null_loop_line and self.skip_setup_call_line < self.null_loop_line:
            return "first"
        return "last"


def _is_page_test(test: ast.expr, prefix: str) -> bool:
    return (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
            and test.left.id == "page" and len(test.comparators) == 1
            and isinstance(test.comparators[0], ast.Attribute)
            and unparse(test.comparators[0]).startswith(prefix))


def _is_empty_bytes(expr: str | None) -> bool:
    """`b""` / `b''` -- `ast.unparse` picks the quote, so the text cannot be compared."""
    return bool(expr) and re.fullmatch(r"b(['\"]{2})", expr.strip()) is not None


def _contents_expr(body: list[ast.stmt]) -> str:
    for stmt in body:
        if isinstance(stmt, ast.Assign) and unparse(stmt.targets[0]) == "contents":
            return unparse(stmt.value)
    return "<not found>"


def _file_location_member(node: ast.expr) -> str | None:
    """`FileLocation.springboard.value` -> "springboard".

    Two chained attributes, so a single `isinstance(node.value, ast.Name)` check finds
    nothing -- the enum member is an attribute of `FileLocation`, not a name.
    """
    while isinstance(node, ast.Attribute) and node.attr != "value":
        node = node.value
    if isinstance(node, ast.Attribute) and node.attr == "value" \
            and isinstance(node.value, ast.Attribute) \
            and isinstance(node.value.value, ast.Name) \
            and node.value.value.id == "FileLocation":
        return node.value.attr
    return None


def _is_not_none(test: ast.expr) -> bool:
    """`<name> is not None` -- the temp assigned from `original_plists.get(...)` just
    above. Testing for a `.get()` call here matches nothing: the comparison is on the
    name, which is why the first version of this found no fork at all."""
    return (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
            and isinstance(test.comparators[0], ast.Constant)
            and test.comparators[0].value is None
            and any(isinstance(op, ast.IsNot) for op in test.ops))


def _is_version_ge_27(test: ast.expr) -> bool:
    # `ast.unparse` re-quotes string literals with single quotes, so a literal search for
    # `Version("27.0")` never matches an unparsed tree.
    text = unparse(test)
    return bool(re.search(r"Version\((['\"])27\.0\1\)", text)) and ">=" in text


def _is_ios27_test(test: ast.expr) -> bool:
    """The null loop's version fork: `if is_ios27:` or an inline `Version >= 27.0`."""
    if isinstance(test, ast.Name):
        return test.id in ("is_ios27", "ios27")
    return _is_version_ge_27(test)


def _const_dict(node: ast.Dict) -> dict:
    out = {}
    for k, v in zip(node.keys, node.values):
        if isinstance(k, ast.Constant) and isinstance(v, ast.Constant):
            out[k.value] = v.value
    return out


# ----------------------------------------------------------------------------------- #
# this port
# ----------------------------------------------------------------------------------- #

class Port:
    def __init__(self) -> None:
        self.reset_src = (REPO / "Nugget/Core/TweakReset.swift").read_text(encoding="utf-8")
        self.engine_src = (REPO / "Nugget/Core/GoldenNuggetEngine.swift").read_text(encoding="utf-8")

    def page_locations(self) -> dict[str, list[str]]:
        """`case .springboard: return [.a, .b]` -> {page: [location names]}."""
        out: dict[str, list[str]] = {}
        for case, body in re.findall(
            r"case \.(\w+):\s*\n\s*return \[([^\]]*)\]", self.reset_src
        ):
            out[case] = re.findall(r"\.(\w+)", body)
        return out

    def stock_daemons(self) -> dict[str, bool]:
        block = re.search(
            r"stockDisabledDaemons: \[String: Bool\] = \[(.*?)\n    \]", self.reset_src, re.S
        )
        if not block:
            sys.exit("error: stockDisabledDaemons not found in TweakReset.swift")
        pairs = re.findall(r'"([^"]+)":\s*(true|false)', block.group(1))
        return {k: v == "true" for k, v in pairs}

    def null_bytes(self) -> dict[str, str]:
        """The null fork, normalised to what the bytes *mean*.

        The two sides are different languages, so the expressions are not comparable as
        text: `plistlib.dumps({})` and `serialisePlist([:])` are the same 181 bytes, and
        `b""` and `Data()` are both zero. Only the meaning is compared -- that the iOS 27
        branch writes an *empty dict* and the other writes *no bytes at all*, and not the
        other way round.
        """
        if re.search(r"let nullContents = TweakCompiler.serialisePlist\(\[:\]\)", self.reset_src):
            return {"ios27": "emptyDict", "ios26": "emptyDict"}
        m = re.search(r"let nullContents = ios27 \? (.+?) : (.+)", self.reset_src)
        if not m:
            # A missing fork is a difference, not a script error: report it as one so the
            # table still prints and names it, instead of dying halfway through.
            return {"ios27": "<no ios27/ios26 fork found>", "ios26": "<no ios27/ios26 fork found>"}
        ios27, ios26 = m.group(1).strip(), m.group(2).strip()
        kind27 = "emptyDict" if re.search(r"serialisePlist\(\[:\]\)", ios27) else f"? {ios27}"
        kind26 = "emptyBytes" if ios26 in ("Data()", "Data([])") else f"? {ios26}"
        return {"ios27": kind27, "ios26": kind26}

    def payload_order(self) -> str:
        """Which side of the payload list the skip-setup files are on.

        Scoped to the reset run body, because `tweakPayloads:` also appears in
        `applyTweaks` and `re.search` would otherwise have matched that one and
        reported the apply path's order as the reset's. The body lives in
        `resetPagesRun`; `resetPages` is now only the `loggedRun` wrapper, so the
        scope falls back to it for older sources.
        """
        body = re.search(r"(?:private )?func resetPagesRun\(.*?\n    \}", self.engine_src, re.S)
        if not body:
            body = re.search(r"func resetPages\(.*?\n    \}", self.engine_src, re.S)
        if not body:
            sys.exit("error: resetPagesRun()/resetPages() not found in GoldenNuggetEngine.swift")
        m = re.search(r"tweakPayloads: (.+?),", body.group(0))
        if not m:
            sys.exit("error: tweakPayloads not found inside resetPagesRun()")
        expr = m.group(1)
        if expr.startswith("skipSetup.payloads"):
            return "first"
        if expr.startswith("plan.payloads"):
            return "last"
        return "unknown"

    def skip_setup_gate(self) -> str:
        """The gate, normalised: which pages set `uses_domains`, and the `or` arm.

        The reference sets the flag in the Daemons branch *and* in the StatusBar
        branch's iOS 27 (archive) arm. The AST walker above does not descend into
        the status bar's inner version `if`, so it only reports Daemons; this
        side reads the port's source directly and requires both arms.
        """
        m = re.search(r"func skipSetupAllowed\(.*?\) -> Bool \{\s*\n(.*?)\n    \}",
                      self.reset_src, re.S)
        if not m:
            sys.exit("error: skipSetupAllowed(pages:ios27:) not found in TweakReset.swift")
        body = m.group(1)
        uses = re.search(r"usesDomains = (.*)", body)
        allowed = re.search(r"return usesDomains \|\| !ios27", body)
        if not uses or not allowed:
            sys.exit("error: could not read the skipSetupAllowed body")
        expression = uses.group(1)
        if not ("pages.contains(.daemons)" in expression
                and "pages.contains(.statusBar)" in expression
                and "ios27" in expression):
            sys.exit(f"error: unexpected skipSetupAllowed usesDomains expression: {expression}")
        return "statusBar (iOS 27) and daemons set the flag; or !ios27"



# ----------------------------------------------------------------------------------- #
# compare
# ----------------------------------------------------------------------------------- #

# reference page name -> this port's ResetPage case
PAGE_MAP = {
    "Springboard": "springboard",
    "InternalOptions": "internalOptions",
    "Daemons": "daemons",
}


def compare(ref: Reference, port: Port, verbose: bool) -> list[str]:
    failures: list[str] = []
    port_pages = port.page_locations()

    def check(label: str, expected, actual) -> None:
        ok = expected == actual
        if verbose or not ok:
            print(f"  {'ok  ' if ok else 'FAIL'} {label}")
        if not ok:
            print(f"         reference: {expected}")
            print(f"         this port: {actual}")
        if not ok:
            failures.append(label)

    print("per-page nulled files (order significant):")
    for ref_page, port_page in PAGE_MAP.items():
        expected = [ref.paths[m] for m in ref.nulls.get(ref_page, [])]
        actual_names = port_pages.get(port_page, [])
        actual = [_location_path(n) for n in actual_names if n != "disabledDaemons"]
        check(f"{ref_page} -> {port_page}", expected, actual)

    print("\nthe one non-null file:")
    daemons = [p for p in port_pages.get("daemons", []) if p == "disabledDaemons"]
    check("Daemons writes disabled.plist", ["disabledDaemons"], daemons)
    check("Daemons path", ref.paths["disabledDaemons"], _location_path("disabledDaemons"))

    print("\nstock disabled.plist (keys, values and types):")
    check("default_daemons", ref.stock_daemons, port.stock_daemons())

    print("\nthe null fork:")
    # The reference's expressions, mapped to the port's vocabulary. Comparing the text
    # itself would fail on every run, since the two sides are different languages.
    check("iOS 27 null is a valid empty plist",
          "emptyDict" if "plistlib.dumps({})" == ref.null_fork.get("ios27")
          else f"? {ref.null_fork.get('ios27')}",
          port.null_bytes()["ios27"])
    check("iOS 26 null contents",
          "emptyDict" if "plistlib.dumps({})" == ref.null_fork.get("ios26") else "emptyBytes" if _is_empty_bytes(ref.null_fork.get("ios26"))
          else f"? {ref.null_fork.get('ios26')}",
          port.null_bytes()["ios26"])

    print("\nskip-setup files:")
    check("the two paths", [
        "Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
        "mobile/com.apple.purplebuddy.plist",
    ], ref.skip_setup_paths)
    check("position in the payload list", ref.skip_setup_payload_index(), port.payload_order())
    # The gate is compared through both sides' own reading of the reference: the
    # reference's raw text is printed, and the port is held to the semantics that text
    # says -- a flag set by one page, ORed with "version below 27".
    ref_gate = ref.skip_setup_gate or ""
    check("gate: reference names both arms",
          True,
          "restoring_domains" in ref_gate
          and bool(re.search(r"Version\((['\"])27\.0\1\)", ref_gate)))
    check("gate: this port", "statusBar (iOS 27) and daemons set the flag; or !ios27",
          port.skip_setup_gate())
    check("which pages set uses_domains in a reset", ["Daemons"],
          ref.pages_setting_uses_domains)

    return failures


def _location_path(name: str) -> str:
    """The Swift `TweakFileLocation` rawValue for a case name, from the generated enum."""
    catalog = (REPO / "Nugget/Core/TweakCatalog.swift").read_text(encoding="utf-8")
    m = re.search(rf'case {re.escape(name)}\s*=\s*"([^"]+)"', catalog)
    return m.group(1) if m else f"<{name} not found in TweakCatalog.swift>"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--goldennugget", help="path to the reference tree")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print every check, not only the failures")
    args = ap.parse_args()

    root = find_reference(args.goldennugget)
    print(f"reference: {root}\n")

    ref, port = Reference(root), Port()
    failures = compare(ref, port, args.verbose)

    print()
    if failures:
        print(f"{len(failures)} difference(s) against the reference:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("reset plan matches the reference (file lists, order, stock dict, null bytes, "
          "skip-setup gate and position).")
    print("not covered here: the Manifest.db/MBDB fork, the backup pull, the prune set and "
          "the no-psysbackup decision -- see docs/tweak-port.md 2.4.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
