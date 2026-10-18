import Foundation

/// The `.caml` / `.xml` editor behind a template's `set` and `remove` options.
///
/// A port of `src/controllers/xml_handler.py`, which is three functions over
/// `xml.etree.ElementTree`: `set_xml_value`, `set_xml_values` and
/// `delete_xml_value`.  They are the only thing in the reference that edits a
/// CoreAnimation document, and every template that customises a wallpaper's
/// layers goes through them.
///
/// **Why a hand-written DOM rather than `XMLParser`.**  `XMLParser` is a SAX
/// parser and hands attributes over as an unordered `[String: String]`, so a
/// document written back through it comes out with its attributes in a different
/// order than it went in.  That is harmless to a conformant reader — attribute
/// order is not significant in XML, and `ElementTree` does the same kind of
/// reordering — but a `.caml` is a file a human diffs when a template does not
/// do what its author meant, and "the diff shows every attribute of every
/// touched element moved" is a bad thing to hand someone.  The parser here keeps
/// order, keeps the text nodes (and therefore the indentation), and round-trips
/// a document it did not change byte for byte.
///
/// The grammar it accepts is the one CoreAnimation writes, which is a small
/// subset of XML: a declaration, elements with double- or single-quoted
/// attributes, self-closing tags, text, comments, CDATA and the five predefined
/// entities plus numeric character references.  Anything else — a DTD, a
/// processing instruction beyond the declaration, a namespace prefix — is
/// **refused** rather than half-read.  A template that ships one is a template
/// whose edit would silently land on the wrong element.
enum TemplateXML {
    // MARK: - Errors

    /// A document this parser will not read, or a `nuggetOffset` it cannot
    /// evaluate.  Both are refusals with a reason rather than a silent no-op:
    /// the reference lets `ElementTree` raise, and a template that half-applied
    /// is worse than one that did not apply.
    struct ParseError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: - The document

    /// One element.  A class rather than a struct because `deleteValue` has to
    /// unlink a node from its parent, and an array of values cannot do that.
    final class Node {
        /// The tag as written, namespace prefix included (`CALayer`, not a
        /// `{uri}CALayer` pair): a `caml` uses one default namespace and never
        /// a prefix, so splitting the two would only create a spelling the file
        /// does not have.
        var tag: String
        /// Ordered, because the order is the file's.
        var attributes: [(name: String, value: String)]
        /// The element's body, in document order.
        ///
        /// An ordered list rather than "a `text` plus a `children` array plus
        /// trivia indexed against the children": mixed content is exactly what
        /// an indented XML file is, and an index that has to be kept in step
        /// with a delete is an index that will be wrong.
        enum Content {
            case element(Node)
            /// Character data — escaped on the way out, unescaped on the way in.
            case text(String)
            /// A comment, a CDATA section or a processing instruction: verbatim
            /// in both directions, because escaping any of them changes them.
            case raw(String)
        }
        var content: [Content] = []
        /// Whether the element's own empty-element tag was written `/>` with no
        /// space before it.
        ///
        /// Pure fidelity, and it is the difference between a template that
        /// touches nothing coming back byte-identical and coming back with one
        /// space reinserted in every self-closing tag it did not mean to touch.
        var tightSelfClosing = false

        init(tag: String, attributes: [(name: String, value: String)]) {
            self.tag = tag
            self.attributes = attributes
        }

        /// The element's own character data, for an element that has none.
        /// Empty otherwise — including for `<elements/>`-shaped nodes.
        var text: String {
            content.compactMap { if case .text(let value) = $0 { return value } else { return nil } }
                .joined()
        }

        var children: [Node] {
            content.compactMap { if case .element(let node) = $0 { return node } else { return nil } }
        }

        /// The value of an attribute, or nil.
        func attribute(_ name: String) -> String? {
            attributes.first { $0.name == name }?.value
        }

        func setAttribute(_ name: String, to value: String) {
            if let index = attributes.firstIndex(where: { $0.name == name }) {
                attributes[index].value = value
            } else {
                // Appending is what `Element.set` does, and it is observable:
                // the reference's `set_xml_values` only ever *replaces* keys a
                // `caml` already has for a `set` option, but a `remove` with an
                // identifier that does not exist adds nothing and must not
                // either.
                attributes.append((name, value))
            }
        }

        /// Every element below this one, in document order, excluding this one.
        ///
        /// `.//*` in `ElementTree`, which is what both reference functions
        /// search with — and it excludes the root, which is reproduced here
        /// because a `nuggetId` on the document element would then not be
        /// found by the reference and must not be found here.
        func descendants() -> [Node] {
            var out: [Node] = []
            for child in children {
                out.append(child)
                out.append(contentsOf: child.descendants())
            }
            return out
        }
    }

    /// A parsed document: the declaration line (kept verbatim, so it round-trips)
    /// and the root element.
    struct Document {
        var declaration: String
        var root: Node
    }

    // MARK: - Reading

    /// Parse a document, or throw `ParseError` naming what was refused.
    static func parse(_ data: Data) throws -> Document {
        var text = String(decoding: data, as: UTF8.self)
        // A byte-order mark is invisible to every reader and fatal to this one:
        // it is not whitespace, so it would fail the tag scan below.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var scanner = XMLScanner(text)
        let declaration = try scanner.consumeDeclaration()

        let root = try scanner.consumeElement()
        scanner.skipWhitespace()
        // Trailing comments are legal and are kept: they are the one place a
        // template author's note lives, and they are usually outside the part
        // being edited.
        while true {
            if scanner.consume("<!--") {
                root.content.append(.raw(try scanner.consumeComment()))
            } else if scanner.consume("<?") {
                let start = scanner.index
                guard scanner.consumeUntil("?>") else {
                    throw ParseError(reason: "a processing instruction is never closed.")
                }
                root.content.append(.raw(scanner.text(from: start)))
            } else {
                break
            }
            scanner.skipWhitespace()
        }
        guard scanner.isAtEnd else {
            throw ParseError(reason: "the XML has content after the root element "
                + "(\"\(scanner.rest.prefix(40))\"), which this editor will not guess at.")
        }
        return Document(declaration: declaration, root: root)
    }

    // MARK: - Writing

    /// Serialise back to bytes.  Same encoding and declaration as the input.
    static func write(_ document: Document) -> Data {
        var out = document.declaration
        if out.isEmpty { out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" }
        out += "\n"
        out += element(document.root, indent: 0)
        return Data(out.utf8)
    }

    private static func element(_ node: Node, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var open = "\(pad)<" + node.tag
        for attribute in node.attributes {
            open += " \(attribute.name)=\"\(escape(attribute.value))\""
        }
        if node.content.isEmpty {
            return open + (node.tightSelfClosing ? "/>" : " />")
        }
        var out = open + ">"
        for item in node.content {
            switch item {
            case .element(let child):
                // **No extra indent.** The document's indentation is already in
                // the text segments between the elements — that is what keeping
                // them verbatim means — so indenting here as well would add a
                // space per nesting level and walk the whole file sideways.
                out += element(child, indent: 0)
            case .text(let value):
                out += escape(value)
            case .raw(let value):
                out += value
            }
        }
        out += "\(pad)</\(node.tag)>"
        return out
    }

    /// The five predefined entities and numeric character references.  This is
    /// deliberately not "escape every `&`": a `caml` attribute can hold a URL
    /// with `&amp;` already in it, and double-escaping that changes the value
    /// CoreAnimation reads.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Decoding is **throwing**, and that is not decoration: `&` not starting
    /// an entity, or an entity this editor does not know, is what a hand-edited
    /// or deliberately hostile file looks like, and returning the raw text would
    /// hand the caller a `caml` whose attribute values silently disagree with
    /// the file's.
    static func unescape(_ value: String) throws -> String {
        guard value.contains("&") else { return value }
        var out = ""
        out.reserveCapacity(value.count)
        var rest = Substring(value)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let tail = rest[rest.index(after: amp)...]
            guard let semicolon = tail.firstIndex(of: ";") else {
                // A bare `&` is what a hand-edited file has; `ElementTree` refuses
                // it, and so does this, one layer up.
                throw ParseError(reason: "the XML has a `&` that does not start an entity.")
            }
            let entity = tail[tail.startIndex..<semicolon]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                   let code = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                } else if entity.hasPrefix("#"),
                          let code = UInt32(entity.dropFirst()),
                          let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                } else {
                    throw ParseError(reason: "the XML uses the entity `&\(entity);`, "
                        + "which this editor does not know.")
                }
            }
            rest = tail[tail.index(after: semicolon)...]
        }
        out += rest
        return out
    }

    // MARK: - The two reference entry points

    /// `set_xml_values`: write `values` onto every element carrying the
    /// identifier, applying a `nuggetOffset` equation to the first key only.
    ///
    /// - Parameters:
    ///   - id: the `nuggetId` (or, with `useCAID`, the CoreAnimation `id`).
    ///   - useCAID: search the CoreAnimation `id` instead of `nuggetId`, and
    ///     *additionally* every element whose `targetId` is `id`.
    static func setValues(in data: Data,
                          id: String,
                          keys: [String],
                          values: [String],
                          useCAID: Bool = false) throws -> Data {
        guard !keys.isEmpty else { return data }
        var document = try parse(data)
        let idKey = useCAID ? "id" : "nuggetId"

        for element in document.root.descendants() {
            guard element.attribute(idKey) == id else { continue }
            // `nuggetOffset` applies to the **first** key only — the reference's
            // own TODO says so ("Allow offsets for more than just the first
            // value"), and a template that relies on more than that is already
            // outside what it can do.
            let equation = element.attribute("nuggetOffset")
            for (index, key) in keys.enumerated() where index < values.count {
                var value = values[index]
                if index == 0, let equation {
                    value = try OffsetEquation(equation).apply(to: value)
                }
                element.setAttribute(key, to: value)
            }
        }

        if useCAID {
            // `targetId` is the reference's second pass and it is *not* offset:
            // `set_xml_values` re-reads `values[i]` there without the equation.
            // Reproduced, because a `targetId` element and a `nuggetId` element
            // can both be in one file and only one of them carries the offset.
            for element in document.root.descendants() where element.attribute("targetId") == id {
                for (index, key) in keys.enumerated() where index < values.count {
                    element.setAttribute(key, to: values[index])
                }
            }
        }

        return write(document)
    }

    /// `delete_xml_value`: remove every element carrying the identifier.
    ///
    /// With `useCAID`, that is both the `id` elements and the `targetId` ones —
    /// which is what makes "remove the layer" and "remove whatever points at the
    /// layer" one option.
    static func deleteValue(in data: Data, id: String, useCAID: Bool = false) throws -> Data {
        var document = try parse(data)
        let idKey = useCAID ? "id" : "nuggetId"
        remove(matching: { $0.attribute(idKey) == id }, from: document.root)
        if useCAID {
            remove(matching: { $0.attribute("targetId") == id }, from: document.root)
        }
        return write(document)
    }

    /// `remove_from_root`: unlink every match from its parent.
    ///
    /// Iterative rather than recursive, because a nested match's parent may
    /// itself have just been unlinked — and `ElementTree` has the same
    /// behaviour, since it collects the parents first and then searches within
    /// them. Walking down from the root and filtering each level's children
    /// gives the same set.
    private static func remove(matching predicate: (Node) -> Bool, from root: Node) {
        var level = [root]
        while let parent = level.popLast() {
            var kept: [Node.Content] = []
            kept.reserveCapacity(parent.content.count)
            var skipNextText = false
            for item in parent.content {
                // A removed element takes its **tail** with it — the text between
                // its closing tag and whatever came next.  That is
                // `ElementTree`'s `tail` living on the element rather than on
                // the parent, and it is observable: deleting one layer out of a
                // `<sublayers>` takes the newline that followed it, so the
                // survivor's indentation changes.  Verified against the
                // reference rather than assumed; `scripts/template-xml-check.swift`
                // pins it.
                if skipNextText, case .text = item {
                    skipNextText = false
                    continue
                }
                skipNextText = false
                switch item {
                case .element(let child):
                    if predicate(child) {
                        skipNextText = true
                        continue
                    }
                    level.append(child)
                    kept.append(item)
                case .text, .raw:
                    kept.append(item)
                }
            }
            parent.content = kept
        }
    }

    // MARK: - The offset equation

    /// `parse_equation`: evaluate a `nuggetOffset` against the user's value.
    ///
    /// The reference splits on `,` for the components and runs Python's `eval`
    /// with `__builtins__` cleared and `x`, `y`, `z`, `a` bound to the
    /// components of the value (`"2 * x + 10", "3 * y + 15"` over `"195 365"`
    /// gives `"400 1110"`).  Every operand is a `float` there, so every result
    /// prints with a decimal point — which matters, because the result is
    /// written straight into a `caml` attribute that CoreAnimation parses.
    ///
    /// `eval` is not reproduced.  This is a recursive-descent parser over
    /// `+ - * / % **`, parentheses and the four variables, and anything else is
    /// refused by name.  A template author who needs more than arithmetic in an
    /// offset has a different tool, and an `eval` here would be an arbitrary
    /// code path driven by the contents of a file the user chose to import.
    struct OffsetEquation {
        private let equations: [String]
        /// Bound by the caller, so a missing variable is a refusal rather than a
        /// silent zero: `eval` would raise `NameError`, and reproducing a
        /// silently-different answer is what this port exists to avoid.
        private let variables: [String: Double]

        init(_ equation: String) {
            self.equations = equation
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self.variables = [:]
        }

        init(_ equation: String, variables: [String: Double]) {
            self.equations = equation
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self.variables = variables
        }

        func apply(to value: String) throws -> String {
            guard !equations.isEmpty else { return value }
            // A single value stays single: `"3 * x + 1"` over `"20"` must not
            // become `"61"` with a space in it, and must not become `"61.0 61.0"`
            // either.
            let components = value.contains(" ") ? value.split(separator: " ").map(String.init) : nil
            var mapped: [String: Double] = variables
            if let components {
                for (name, component) in zip(["x", "y", "z", "a"], components) {
                    guard let number = Double(component) else {
                        throw ParseError(reason: "a `nuggetOffset` needs numbers, and "
                            + "\"\(component)\" is not one.")
                    }
                    mapped[name] = number
                }
            } else if let number = Double(value) {
                mapped["x"] = number
            } else {
                throw ParseError(reason: "a `nuggetOffset` needs a numeric value, and "
                    + "\"\(value)\" is not one.")
            }

            let results = try equations.map { try OffsetEquation.evaluate($0, mapped) }
            return results.map(OffsetEquation.format).joined(separator: " ")
        }

        /// `str(float)`: always a decimal point on an integral value, which is
        /// what Python prints and therefore what every offset in the wild was
        /// written against.
        static func format(_ number: Double) -> String {
            if number.isNaN { return "nan" }
            if number.isInfinite { return number < 0 ? "-inf" : "inf" }
            return "\(number)"
        }

        // MARK: The grammar

        private static func evaluate(_ expression: String, _ variables: [String: Double]) throws -> Double {
            var parser = EquationParser(Array(expression.utf8), variables: variables)
            let value = try parser.parseExpression()
            parser.skipSpaces()
            guard parser.isAtEnd else {
                throw ParseError(reason: "the `nuggetOffset` expression "
                    + "\"\(expression)\" has trailing content this editor cannot parse.")
            }
            return value
        }

        private struct EquationParser {
            let bytes: [UInt8]
            let variables: [String: Double]
            var index = 0

            init(_ bytes: [UInt8], variables: [String: Double]) {
                self.bytes = bytes
                self.variables = variables
            }

            var isAtEnd: Bool { index >= bytes.count }

            mutating func skipSpaces() {
                while index < bytes.count,
                      bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
            }

            mutating func parseExpression() throws -> Double {
                var value = try parseTerm()
                while true {
                    skipSpaces()
                    guard index < bytes.count else { return value }
                    let symbol = bytes[index]
                    if symbol == 0x2B {            // +
                        index += 1
                        value += try parseTerm()
                    } else if symbol == 0x2D {     // -
                        index += 1
                        value -= try parseTerm()
                    } else {
                        return value
                    }
                }
            }

            mutating func parseTerm() throws -> Double {
                var value = try parseUnary()
                while true {
                    skipSpaces()
                    guard index < bytes.count else { return value }
                    switch bytes[index] {
                    case 0x2A:                    // *
                        index += 1
                        value *= try parseUnary()
                    case 0x2F:                    // /
                        index += 1
                        let divisor = try parseUnary()
                        guard divisor != 0 else {
                            throw ParseError(reason: "a `nuggetOffset` divides by zero.")
                        }
                        value /= divisor
                    case 0x25:                    // %
                        index += 1
                        let divisor = try parseUnary()
                        guard divisor != 0 else {
                            throw ParseError(reason: "a `nuggetOffset` takes a modulus of zero.")
                        }
                        value = value.truncatingRemainder(dividingBy: divisor)
                    default:
                        return value
                    }
                }
            }

            mutating func parseUnary() throws -> Double {
                skipSpaces()
                guard index < bytes.count else {
                    throw ParseError(reason: "a `nuggetOffset` expression ends where a value "
                        + "should be.")
                }
                if bytes[index] == 0x2D {          // -
                    index += 1
                    return -(try parseUnary())
                }
                if bytes[index] == 0x2B {          // +
                    index += 1
                    return try parseUnary()
                }
                return try parsePower()
            }

            mutating func parsePower() throws -> Double {
                let base = try parseAtom()
                skipSpaces()
                // `**` binds tighter than unary minus, so `-2 ** 2` is `-4`.
                guard index + 1 < bytes.count, bytes[index] == 0x2A, bytes[index + 1] == 0x2A else {
                    return base
                }
                index += 2
                return try pow(base, try parseUnary())
            }

            mutating func parseAtom() throws -> Double {
                skipSpaces()
                guard index < bytes.count else {
                    throw ParseError(reason: "a `nuggetOffset` expression ends where a value "
                        + "should be.")
                }
                if bytes[index] == 0x28 {          // (
                    index += 1
                    let value = try parseExpression()
                    skipSpaces()
                    guard index < bytes.count, bytes[index] == 0x29 else {
                        throw ParseError(reason: "a `nuggetOffset` opens a parenthesis it never closes.")
                    }
                    index += 1
                    return value
                }
                let digit = bytes[index]
                if (0x30...0x39).contains(digit) || digit == 0x2E {
                    return try parseNumber()
                }
                if bytes[index] == 0x78 || bytes[index] == 0x79
                    || bytes[index] == 0x7A || bytes[index] == 0x61 {   // x y z a
                    let name = String(UnicodeScalar(bytes[index]))
                    index += 1
                    guard let value = variables[name] else {
                        throw ParseError(reason: "the `nuggetOffset` uses \(name), but the value "
                            + "it offsets has no \(name) component.")
                    }
                    return value
                }
                let text = String(decoding: bytes[index...].prefix(16), as: UTF8.self)
                let quoted = text.isEmpty ? "an end of input" : "\"\(text)\""
                throw ParseError(reason: "a `nuggetOffset` contains \(quoted), which is not a "
                    + "number, a variable or an operator.")
            }

            mutating func parseNumber() throws -> Double {
                let start = index
                while index < bytes.count {
                    let byte = bytes[index]
                    let isDigit = byte >= 0x30 && byte <= 0x39
                    // `e`/`E` only count as an exponent when a digit or a sign
                    // follows, so `2e` is not silently read as `2`.
                    let isExponentMarker = (byte == 0x65 || byte == 0x45)
                        && index + 1 < bytes.count
                        && (bytes[index + 1] == 0x2B || bytes[index + 1] == 0x2D
                            || (bytes[index + 1] >= 0x30 && bytes[index + 1] <= 0x39))
                    if isDigit || byte == 0x2E || isExponentMarker {
                        index += 1
                        if isExponentMarker { index += 1 }
                    } else {
                        break
                    }
                }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard let value = Double(text) else {
                    throw ParseError(reason: "\"\(text)\" is not a number.")
                }
                return value
            }
        }
    }
}

// MARK: - Glob

/// `glob.glob(path, recursive=True)`, over one pattern.
///
/// Every `set`, `remove` and `replace` option's `files` list goes through the
/// reference's `glob.glob`, so a template can name `descriptors/*/main.caml`
/// instead of listing every descriptor.  Reproduced down to the parts that
/// change what lands on the device:
///
///   * `*` and `?` stop at a `/` — they match within one path component, which
///     is what makes `*` in `assets/*` mean "the files in assets", not
///     "everything below assets";
///   * `**` crosses components, and `**/` also matches **zero** components, so
///     `**/main.caml` finds `main.caml` at the root;
///   * a pattern with no wildcard is one path, and it is returned only if it
///     exists — which is what makes a `remove` option on a file the template
///     does not ship a no-op rather than an error;
///   * directories come back too.  `remove` relies on it (`os.path.isdir` →
///     `rmtree`), and so does `set` on a directory-shaped pattern.
enum TemplateGlob {
    /// The paths under `root` that `pattern` names, in a stable order.
    ///
    /// Sorted, because `os.listdir` order is the filesystem's and the payload
    /// order is what a run's log and the injected inodes depend on; this port
    /// makes the same choice everywhere else (see `PosterBoard`'s divergence
    /// note).
    static func match(_ pattern: String, under root: URL) -> [URL] {
        let fm = FileManager.default
        // `FileManager` hands back `/private/tmp/...` for a `/tmp` root (that is
        // the symlink macOS puts there), so every path this returns is prefixed
        // with the **resolved** root, not the one that was passed in.
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        // A leading `/` in an option's path is not "the filesystem root", it is
        // the same thing a leading `/` is everywhere else here: noise from a
        // template author.  `option.apply` joins onto the extraction directory,
        // so dropping it is what makes `"/descriptors/x"` behave like
        // `"descriptors/x"`.
        var start = 0
        while start < components.count, components[start].isEmpty { start += 1 }
        guard start < components.count else { return [] }
        let rest = Array(components[start...])

        if !rest.contains(where: { $0.contains("*") || $0.contains("?") || $0.contains("[") }) {
            let candidate = root.appendingPathComponent(rest.joined(separator: "/"))
            return fm.fileExists(atPath: candidate.path) ? [candidate] : []
        }
        return expand(rest, at: root, fm: fm)
    }

    private static func expand(_ components: [String], at directory: URL,
                               fm: FileManager) -> [URL] {
        guard let head = components.first else { return [directory] }
        let tail = Array(components.dropFirst())

        if head == "**" {
            // Zero components: `**/x` matches `x` in this directory too.
            if tail.isEmpty {
                // A bare `**` is the whole subtree: every entry here and
                // everything under it, files and directories alike.  The
                // starting directory is **not** in the result — `glob("**")`
                // returns its contents, not itself — so an option that says
                // `files: ["**"]` acts on what is *inside* the extraction
                // directory rather than on the directory.
                var out: [URL] = []
                for child in children(of: directory, fm: fm) {
                    out.append(child)
                    if isDirectory(child, fm: fm) {
                        out += expand(components, at: child, fm: fm)
                    }
                }
                return out
            }
            var out = expand(tail, at: directory, fm: fm)
            for child in children(of: directory, fm: fm) where isDirectory(child, fm: fm) {
                // Only directories are descended — there is nothing under a
                // file — while a file can still *be* the tail's match, which
                // the zero-component call above already covers.
                out += expand(components, at: child, fm: fm)
            }
            return out
        }

        var out: [URL] = []
        for child in children(of: directory, fm: fm) where fnmatch(head, child.lastPathComponent) {
            if tail.isEmpty {
                // The last component names the entry itself — a file or a
                // directory, both of which are results (`remove` acts on a
                // directory with `rmtree`).
                out.append(child)
            } else if isDirectory(child, fm: fm) {
                out += expand(tail, at: child, fm: fm)
            }
            // A non-directory with components left cannot match: there is
            // nothing under a file.
        }
        return out
    }

    private static func children(of directory: URL, fm: FileManager) -> [URL] {
        ((try? fm.contentsOfDirectory(at: directory,
                                       includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var flag: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// `fnmatch.fnmatch` with no `FNM_PATHNAME`, for **one** component: `*` and
    /// `?` match anything (including a `/`, which cannot occur here), and
    /// `[...]` is a character class with `!`/`^` negation and `a-z` ranges.
    static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0, ni = 0
        var starPattern = -1, starName = 0

        while ni < n.count {
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starPattern = pi
                    starName = ni
                    pi += 1
                    continue
                case "?":
                    pi += 1
                    ni += 1
                    continue
                case "[":
                    if let (matched, next) = matchClass(p, from: pi, against: n[ni]) {
                        if matched { pi = next; ni += 1; continue }
                        break
                    }
                    break
                default:
                    if p[pi] == n[ni] { pi += 1; ni += 1; continue }
                }
            }
            // Backtrack into the last `*`, one more character at a time.  This
            // is the reference's own `fnmatch` algorithm; without it
            // `*.caml` would not match `a.b.caml`.
            if starPattern >= 0 {
                starName += 1
                pi = starPattern + 1
                ni = starName
                continue
            }
            return false
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func matchClass(_ pattern: [Character], from start: Int,
                                   against character: Character) -> (matched: Bool, next: Int)? {
        var index = start + 1
        var negated = false
        if index < pattern.count, pattern[index] == "!" || pattern[index] == "^" {
            negated = true
            index += 1
        }
        var matched = false
        var first = true
        while index < pattern.count {
            if pattern[index] == "]" && !first { break }
            first = false
            if index + 2 < pattern.count, pattern[index + 1] == "-", pattern[index + 2] != "]" {
                if pattern[index]...pattern[index + 2] ~= character { matched = true }
                index += 3
            } else {
                if pattern[index] == character { matched = true }
                index += 1
            }
        }
        guard index < pattern.count else { return nil }
        return (negated ? !matched : matched, index + 1)
    }
}
