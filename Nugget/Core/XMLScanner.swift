import Foundation

/// A cursor over an XML document, for `TemplateXML`'s parser.
///
/// Hand-written rather than `XMLParser` for the reason `TemplateXML`'s own
/// header gives: attribute order and text nodes are both load-bearing here (see
/// there), and a SAX parser hands neither over in a form that survives a write.
///
/// The lexer is deliberately **partial**.  It reads the XML a CoreAnimation
/// document actually contains and refuses the rest — a DTD, a processing
/// instruction other than the declaration, a namespace prefix, an unquoted
/// attribute value.  Refusing is the point: the alternative is a parser that
/// half-understands a construct, and the failure then shows up as an edit
/// landing on the wrong element rather than as an error at import.
struct XMLScanner {
    private let characters: [Character]
    private var cursor = 0

    init(_ text: String) {
        self.characters = Array(text)
    }

    var isAtEnd: Bool { cursor >= characters.count }

    /// The remainder, for an error message.  Bounded, because the message goes
    /// on screen.
    var rest: String {
        String(characters[min(cursor, characters.count)...].prefix(40))
    }

    var peek: Character? { cursor < characters.count ? characters[cursor] : nil }

    mutating func skipWhitespace() {
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
    }

    /// Consume `token` if it is next.  Reports whether it was.
    @discardableResult
    mutating func consume(_ token: String) -> Bool {
        let candidate = Array(token)
        guard cursor + candidate.count <= characters.count else { return false }
        for (offset, character) in candidate.enumerated()
        where characters[cursor + offset] != character { return false }
        cursor += candidate.count
        return true
    }

    /// `<?xml … ?>` — kept verbatim so the document round-trips.
    ///
    /// Only the *declaration* is accepted, and only before the root element.  A
    /// PI anywhere else would be dropped, and a template author who put one
    /// there has written something this editor does not model.
    mutating func consumeDeclaration() throws -> String {
        skipWhitespace()
        guard cursor < characters.count, characters[cursor] == "<" else { return "" }
        // `<!--` is a comment, not a declaration.
        guard cursor + 1 < characters.count, characters[cursor + 1] == "?" else { return "" }
        let start = cursor
        guard consume("<?xml") else {
            throw TemplateXML.ParseError(reason: "the XML's first construct is a processing "
                + "instruction rather than a declaration. This editor only reads documents "
                + "that start with `<?xml …?>`.")
        }
        guard consumeUntil("?>") else {
            throw TemplateXML.ParseError(reason: "the XML declaration is never closed.")
        }
        return String(characters[start..<cursor])
    }

    /// Consume through `terminator`, which is left unconsumed.  False when the
    /// document ends first — the caller's own error message is better than one
    /// from here, because it can say *what* was being read.
    @discardableResult
    mutating func consumeUntil(_ terminator: String) -> Bool {
        let needle = Array(terminator)
        guard !needle.isEmpty else { return false }
        var scan = cursor
        while scan + needle.count <= characters.count {
            var matched = true
            for (offset, character) in needle.enumerated()
            where characters[scan + offset] != character { matched = false; break }
            if matched {
                cursor = scan + needle.count
                return true
            }
            scan += 1
        }
        return false
    }

    /// Where the cursor currently is, for a caller that consumed a construct
    /// itself and needs the text it covered.
    var index: Int { cursor }

    /// The characters from `start` to the cursor.  Paired with the `start`
    /// captured *before* a `consume`/`consumeUntil`, this is how a caller that
    /// had to test the token first still gets its text.
    func text(from start: Int) -> String {
        String(characters[min(start, characters.count)...min(cursor, characters.count)])
    }

    /// `<!-- … -->` including the markers.
    mutating func consumeComment() throws -> String {
        let start = cursor - 4   // the `<!--` the caller already ate
        guard consumeUntil("-->") else {
            throw TemplateXML.ParseError(reason: "a comment in the XML is never closed.")
        }
        return String(characters[start..<cursor])
    }

    /// One element, its attributes, and everything inside it.
    mutating func consumeElement() throws -> TemplateXML.Node {
        skipWhitespace()
        guard consume("<") else {
            throw TemplateXML.ParseError(reason: "expected an element, found \"\(rest)\".")
        }
        guard cursor < characters.count, !characters[cursor].isWhitespace,
              characters[cursor] != "/", characters[cursor] != ">" else {
            throw TemplateXML.ParseError(reason: "the XML has a tag with no name (\"<\" "
                + "followed by \"\(rest)\").")
        }
        let tag = try consumeName()

        var attributes: [(name: String, value: String)] = []
        while true {
            let beforeWhitespace = cursor
            skipWhitespace()
            if consume("/>") {
                let node = TemplateXML.Node(tag: tag, attributes: attributes)
                // Whether there was whitespace between the last attribute and the
                // `/>`, so the writer can put it back exactly as it was.
                node.tightSelfClosing = cursor == beforeWhitespace + 2
                return node
            }
            if consume(">") { break }
            // Two tag names in a row with nothing between them is a malformed
            // file, and reading on would merge two attributes into one.
            guard cursor > beforeWhitespace else {
                throw TemplateXML.ParseError(reason: "the `<\(tag)>` tag has two attributes "
                    + "with nothing between them.")
            }
            attributes.append(try consumeAttribute(in: tag))
        }

        let node = TemplateXML.Node(tag: tag, attributes: attributes)
        try consumeContent(into: node)
        return node
    }

    private mutating func consumeName() throws -> String {
        var name = ""
        while cursor < characters.count {
            let character = characters[cursor]
            guard character.isLetter || character.isNumber || character == "_"
                || character == "-" || character == "." || character == ":" else { break }
            name.append(character)
            cursor += 1
        }
        guard !name.isEmpty else {
            throw TemplateXML.ParseError(reason: "the XML has a tag whose name is empty.")
        }
        // A prefix means a namespace this parser does not model: `caml` uses a
        // default namespace and never a prefix, so one appearing here is either
        // a different document or an edit this editor should not make blind.
        if name.contains(":") {
            throw TemplateXML.ParseError(reason: "the XML uses the namespace prefix "
                + "\"\(name)\", which this editor does not read. CoreAnimation documents "
                + "declare their namespace as the default one, with no prefix.")
        }
        return name
    }

    private mutating func consumeAttribute(in tag: String) throws -> (name: String, value: String) {
        let name = try consumeName()
        skipWhitespace()
        guard consume("=") else {
            throw TemplateXML.ParseError(reason: "the attribute \"\(name)\" on `<\(tag)>` has "
                + "no value.")
        }
        skipWhitespace()
        guard let quote = peek, quote == "\"" || quote == "'" else {
            throw TemplateXML.ParseError(reason: "the attribute \"\(name)\" on `<\(tag)>` is "
                + "not quoted. This editor only reads quoted values.")
        }
        cursor += 1
        var raw = ""
        while cursor < characters.count, characters[cursor] != quote {
            // `<` cannot appear in an attribute value in a well-formed document,
            // and reading past it would swallow the rest of the tag.
            if characters[cursor] == "<" {
                throw TemplateXML.ParseError(reason: "the attribute \"\(name)\" on `<\(tag)>` "
                    + "contains a `<`, which no well-formed XML does.")
            }
            raw.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count else {
            throw TemplateXML.ParseError(reason: "the attribute \"\(name)\" on `<\(tag)>` is "
                + "never closed.")
        }
        cursor += 1   // the closing quote
        return (name, try TemplateXML.unescape(raw))
    }

    /// Children, text and trivia until this element's own closing tag.
    ///
    /// Text is appended as its own `.text` segment rather than concatenated, so
    /// the indentation between child elements stays where the file put it.  It
    /// is **not** trimmed: dropping it would reformat every element a template
    /// touched, which is exactly the noise a `.caml` diff should not have.
    private mutating func consumeContent(into node: TemplateXML.Node) throws {
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            node.content.append(.text(text))
            text = ""
        }

        while true {
            guard cursor < characters.count else {
                throw TemplateXML.ParseError(reason: "the `<\(node.tag)>` element is never closed.")
            }
            if characters[cursor] == "<" {
                if consume("</") {
                    skipWhitespace()
                    let closing = try consumeName()
                    guard closing == node.tag else {
                        throw TemplateXML.ParseError(reason: "`<\(node.tag)>` is closed by "
                            + "`</\(closing)>`.")
                    }
                    skipWhitespace()
                    guard consume(">") else {
                        throw TemplateXML.ParseError(reason: "the `</\(closing)>` tag is malformed.")
                    }
                    flushText()
                    return
                }
                if consume("<!--") {
                    flushText()
                    node.content.append(.raw(try consumeComment()))
                    continue
                }
                if consume("<![CDATA[") {
                    let start = cursor - 9
                    guard consumeUntil("]]>") else {
                        throw TemplateXML.ParseError(reason: "a CDATA section is never closed.")
                    }
                    flushText()
                    node.content.append(.raw(String(characters[start..<cursor])))
                    continue
                }
                if consume("<?") {
                    let start = cursor - 2
                    guard consumeUntil("?>") else {
                        throw TemplateXML.ParseError(reason: "a processing instruction is "
                            + "never closed.")
                    }
                    flushText()
                    node.content.append(.raw(String(characters[start..<cursor])))
                    continue
                }
                if consume("<!") {
                    throw TemplateXML.ParseError(reason: "the XML declares a "
                        + "\"\(String(characters[cursor...].prefix(20)))\", which this editor "
                        + "does not read. A CoreAnimation document has no DTD and no entities "
                        + "beyond the five predefined ones.")
                }
                flushText()
                node.content.append(.element(try consumeElement()))
                continue
            }
            let start = cursor
            while cursor < characters.count, characters[cursor] != "<" { cursor += 1 }
            text += try TemplateXML.unescape(String(characters[start..<cursor]))
        }
    }
}
