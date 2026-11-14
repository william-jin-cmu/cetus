import Foundation

/// How the phone shows an artifact: rendered in-app for the formats agents
/// hand over most, Quick Look for everything else.
public enum ArtifactFormat: Sendable, Hashable {
    case markdown
    /// CSV / TSV with its separator.
    case table(Character)
    /// HTML or SVG in a web view.
    case web
    /// Source or plain text; the language colors it when known.
    case code(language: String?)
    /// Images, PDF, audio, video, Office files: the system viewer.
    case native

    public init(_ artifact: Artifact) {
        let ext = (artifact.name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdx": self = .markdown
        case "csv": self = .table(",")
        case "tsv", "tab": self = .table("\t")
        case "html", "htm", "xhtml", "svg": self = .web
        case "txt", "text", "log", "out", "err": self = .code(language: nil)
        default:
            if !ext.isEmpty, SyntaxHighlighter.knows(ext) {
                self = .code(language: ext)
            } else {
                switch artifact.kind {
                case "markdown": self = .markdown
                case "html": self = .web
                case "text": self = .code(language: nil)
                default: self = .native
                }
            }
        }
    }

    /// Read as text and drawn by the app (web pages included).
    public var isText: Bool { self != .native }
}

/// RFC 4180-ish delimited text: quoted fields, doubled quotes, line breaks
/// inside quotes, CRLF. Stops after `limit` rows.
public enum DelimitedText {
    public static func parse(_ text: String, separator: Character, limit: Int = .max) -> (rows: [[String]], complete: Bool) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var chars = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        func endRow() {
            row.append(field)
            field = ""
            // A trailing blank line is not a row.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            atFieldStart = true
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            if c == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else if c == separator {
                row.append(field)
                field = ""
                atFieldStart = true
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
                if rows.count >= limit { return (rows, chars.next() == nil && pending == nil) }
            } else {
                field.append(c)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return (rows, true)
    }
}

/// Re-indents JSON without parsing it, so keys keep the order they were
/// written in. Text that already spans lines is left alone.
public enum JSONIndent {
    public static func format(_ text: String, limit: Int = 4_000_000) -> String {
        guard text.utf8.count <= limit else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              trimmed.split(separator: "\n", maxSplits: 3).count < 3 else { return text }
        var out = ""
        out.reserveCapacity(trimmed.utf8.count * 2)
        var depth = 0
        var inString = false
        var escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: max(depth, 0)) }
        var chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true; out.append(c)
                case "{", "[":
                    // Keep empty {} and [] on one line.
                    var j = i + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                        out.append(c); out.append(chars[j]); i = j
                    } else {
                        out.append(c); depth += 1; newline()
                    }
                case "}", "]": depth -= 1; newline(); out.append(c)
                case ",": out.append(c); newline()
                case ":": out += ": "
                case _ where c.isWhitespace: break
                default: out.append(c)
                }
            }
            i += 1
        }
        chars = []
        return out
    }
}
