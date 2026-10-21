// Runs against shipping template sources and ZIPFoundation via check-template-safety.py.
@main struct TemplateSafetyCheck {
    static func main() throws {
        let root = URL.documents
        let fm = FileManager.default
        let previousOptions = UserDefaults.standard.object(forKey: "TemplateOptionValues")
        defer {
            if let previousOptions { UserDefaults.standard.set(previousOptions, forKey: "TemplateOptionValues") }
            else { UserDefaults.standard.removeObject(forKey: "TemplateOptionValues") }
        }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(label) }
            catch { checks += 1; print("PASS: \(label)") }
        }
        for name in ["parent", "absolute", "backslash", "symlink"] {
            rejects("unsafe archive rejected before resources are written: \(name)") {
                _ = try TemplateFile(url: root.appendingPathComponent(name + ".batter"), deviceVersion: "26.5")
            }
        }
        let extraction = root.appendingPathComponent("extraction")
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        for path in ["../outside.txt", "../../outside.txt", "..\\outside.txt"] {
            check(TemplateGlob.match(path, under: extraction).isEmpty, "resolver refuses \(path)")
            rejects("remove option rejects escaping path \(path)") {
                _ = try RemoveOption(data: ["type": "remove", "label": "Escape", "files": [path], "default_value": true], jsonPath: "config.json")
            }
        }
        check(try Data(contentsOf: outside) == Data("keep".utf8), "outside file remains unchanged")
        let link = extraction.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        check(TemplateGlob.match("link/outside.txt", under: extraction).isEmpty, "literal resolver refuses symlink escape")
        check(!TemplateGlob.match("**", under: extraction).contains(link), "recursive glob skips symlinks and cycles")
        rejects("picker refuses escaping rename") {
            _ = try PickerOption(data: ["type": "picker", "label": "Rename", "options": [["label": "One", "files": ["file"]]],
                                        "rename": true, "names": ["../outside.txt"]], jsonPath: "config.json")
        }
        check(!TemplateGlob.fnmatch("[z-a]", "b"), "reversed character range safely matches nothing")
        check(TemplateGlob.fnmatch("[a-z]", "b"), "valid character ranges still work")
        let valid = try TemplateFile(url: root.appendingPathComponent("valid.batter"), deviceVersion: "26.5")
        let payloads = try TemplateDelivery.payloads(for: valid, into: root.appendingPathComponent("delivery"), log: { _ in })
        check(payloads.map(\.relativePath) == ["Library/test.txt"], "only container files are delivered")
        check(try payloads[0].bytes() == Data("payload".utf8), "payload bytes survive delivery")
        var options = try TemplateFile(url: root.appendingPathComponent("options.batter"), deviceVersion: "26.5")
        for index in options.options.indices {
            if var option = options.options[index] as? RemoveOption {
                option.value = true; options.options[index] = option
            } else if var option = options.options[index] as? SetOption {
                if option.setter == .colorPicker { option.color = (0.25, 0.5, 0.75, 0.8) }
                else if option.setter == .toggle { option.value = [1] }
                else { option.value = [42]; option.text = "42" }
                options.options[index] = option
            } else if var option = options.options[index] as? PickerOption {
                option.selection = []; options.options[index] = option
            }
        }
        TemplateOptionStore.persist(options)
        var restored = try TemplateFile(url: options.url, deviceVersion: "26.5")
        for index in restored.options.indices { TemplateOptionStore.restore(at: index, in: &restored) }
        check((restored.options[0] as! RemoveOption).value, "remove checkbox is restored")
        for index in 1...3 {
            check((restored.options[index] as! SetOption).value == (index == 1 ? [1] : [42]), "set value \(index) is restored")
        }
        let color = (restored.options[4] as! SetOption).color
        check(color.r == 0.25 && color.g == 0.5 && color.b == 0.75 && color.a == 0.8, "color and opacity are restored")
        check((restored.options[5] as! PickerOption).selection.isEmpty, "explicit empty multi-selection is restored")
        var replacement = try TemplateFile(url: root.appendingPathComponent("replacement.batter"), deviceVersion: "26.5")
        let chosen = root.appendingPathComponent("choices/image.png")
        try fm.createDirectory(at: chosen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("chosen image".utf8).write(to: chosen)
        let firstChoice = try TemplateChoices.store(chosen, in: root.appendingPathComponent("staged-choices"))
        let secondChoice = try TemplateChoices.store(chosen, in: root.appendingPathComponent("staged-choices"))
        check(firstChoice != secondChoice, "different picks receive distinct staging paths")
        check(try Data(contentsOf: firstChoice) == Data(contentsOf: secondChoice), "second choice does not delete the first input")
        var option = replacement.options[0] as! ReplaceOption
        option.value = firstChoice; replacement.options[0] = option
        check(option.allowedExtensions == ["png", "jpg"], "extension names have no leading dot")
        check(option.allowedExtensions.compactMap { UTType(filenameExtension: $0) }.count == 2, "replacement filters resolve to UTTypes")
        for attempt in 1...2 {
            let destination = root.appendingPathComponent("replace-\(attempt)")
            try replacement.extract(to: destination)
            check(try Data(contentsOf: destination.appendingPathComponent("container/Library/test.txt")) == Data("chosen image".utf8),
                  "replacement applies on attempt \(attempt)")
        }
        check(fm.fileExists(atPath: chosen.path), "replacement source survives apply and retry")
        print("\(checks) template safety checks passed")
    }
}
