#!/usr/bin/env python3
"""Compile production template code and vendored ZIPFoundation for safety regressions.

No device is contacted. Archives, extracted files and generated sources live in
an isolated temporary directory. The companion Swift file contains the checks.
"""
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["TemplateXML", "XMLScanner", "TemplateFile", "TemplateOptions", "TemplateSelection",
           "TweakModel", "TweakCatalog", "TweakCatalogDaemons", "TweakDomainMap", "TweakCompiler"]


def main():
    with tempfile.TemporaryDirectory(prefix="goldennugget-template-safety-") as temporary:
        folder = Path(temporary)
        config = {"format_version": 2, "domain": "HomeDomain", "title": "Safety fixture", "author": "tests", "options": []}

        def archive(name, header, members):
            with zipfile.ZipFile(folder / name, "w") as output:
                output.writestr("config.json", json.dumps(header))
                for path, contents in members.items():
                    output.writestr(path, contents)

        archive("valid.batter", config, {"container/Library/test.txt": "payload", "banner.png": "preview"})
        for name, path in [("parent", "../outside.txt"), ("absolute", "/outside.txt"), ("backslash", "..\\outside.txt")]:
            archive(name + ".batter", {**config, "resources": ["*"]}, {path: "must not escape"})
        with zipfile.ZipFile(folder / "symlink.batter", "w") as output:
            output.writestr("config.json", json.dumps(config))
            link = zipfile.ZipInfo("link")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            output.writestr(link, "../")
        options = [{"type": "remove", "label": "Remove", "files": [], "default_value": False}]
        for setter in ["toggle", "textbox", "slider", "color_picker"]:
            options.append({"type": "set", "label": setter, "files": [], "identifier": "x", "key": "value",
                            "setter_type": setter, "default_value": [0, 0, 0, 1] if setter == "color_picker" else 1,
                            "min_value": 0, "max_value": 100})
        options.append({"type": "picker", "label": "Variants", "allow_multiple_selection": True,
                        "options": [{"label": "One", "files": []}, {"label": "Two", "files": []}], "default_values": [0]})
        archive("options.batter", {**config, "options": options}, {})
        archive("replacement.batter", {**config, "options": [{"type": "replace", "label": "Image", "files": ["container/Library/test.txt"],
                                                               "required": True, "allowed_files": "Images (*.png *.jpg)"}]},
                {"container/Library/test.txt": "original"})
        archive("posterboard.batter", {**config, "domain": "AppDomain-com.apple.PosterBoard"}, {
            "descriptors/Fixture/versions/0/contents/com.apple.posterkit.provider.contents.userInfo":
                plistlib.dumps({"category": "Featured", "groupName": "Fixture"}),
            "descriptors/Fixture/versions/0/contents/image.bin": b"wallpaper bytes",
        })
        # The existing e2e harness supplies only the version and plist helpers;
        # TemplateFile, its options, storage and delivery are the shipping code.
        support = (ROOT / "scripts/template-e2e-check.swift").read_text().split("enum PosterBoard {", 1)[1].split("// MARK: - Plumbing", 1)[0]
        support = "import Foundation\nimport UniformTypeIdentifiers\nenum PosterBoard {" + support
        support += '''
extension PosterBoard { static func sanitised(_ name: String) -> String { name } }
enum AfcFileExplorer { static func uniqueName(_ name: String, against: Set<String>) -> String { name } }
extension URL { static var documents: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["GN_TEST_ROOT"]!) } }
'''
        paths = []
        for name in SOURCES:
            content = (ROOT / "Nugget/Core" / (name + ".swift")).read_text().replace("import ZIPFoundation", "")
            if name == "TemplateFile":
                # ZIPFoundation is compiled into this same test module, so the
                # production iOS branch is exercised without a second zip reader.
                content = content.replace("#if canImport(ZIPFoundation)", "#if true")
            path = folder / (name + ".swift")
            path.write_text(content)
            paths.append(path)
        harness = folder / "Check.swift"
        harness.write_text(support + (ROOT / "scripts/template-safety-check.swift").read_text())
        vendor = sorted((ROOT / "Vendor/ZIPFoundation/Sources").glob("*.swift"))
        binary = folder / "check"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                        *map(str, vendor + paths), str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], env={**os.environ, "GN_TEST_ROOT": str(folder)}, check=True)
        # Exercise the backup compiler with the real template and SQLite store.
        # Only video/device dependencies use the existing identity-test doubles.
        support = (ROOT / "scripts/posterboard-identity-check.swift").read_text()
        support = support.split("// MARK: - Stubs for the app types", 1)[1].split("// MARK: - Harness", 1)[0]
        support = support[support.index("struct TweakPayload"):]
        start = support.index("enum PosterBoardStore {")
        end = support.index("enum PosterBoardVideo {", start)
        support = support[:start] + support[end:]
        support = support.replace('"/tmp/pbcheck/documents"', 'ProcessInfo.processInfo.environment["GN_TEST_ROOT"]!')
        support = support.replace('func extract(to destination: URL) throws {}',
            'func extract(to destination: URL) throws { if let path = ProcessInfo.processInfo.environment["GN_REAL_PB_PACK"] { try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination) } }')
        backup = folder / "BackupCheck.swift"
        backup.write_text("import Foundation\nimport UniformTypeIdentifiers\nimport SQLite3\n" + support
                          + (ROOT / "scripts/posterboard-template-check.swift").read_text())
        backup_sources = [folder / (name + ".swift") for name in ["TemplateXML", "XMLScanner", "TemplateFile", "TemplateOptions"]]
        backup_sources += [ROOT / "Nugget/Core/PosterBoard.swift", ROOT / "Nugget/Core/PosterBoardStore.swift"]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                        *map(str, vendor + backup_sources), str(backup), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], env={**os.environ, "GN_TEST_ROOT": str(folder)}, check=True)


if __name__ == "__main__":
    main()
