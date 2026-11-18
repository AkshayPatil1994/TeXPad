// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct BibEntry: Equatable {
    var key: String
    var type: String
    var author: String
    var title: String
    var year: String
    var line: Int
    var detail: String { [shortAuthor, year.isEmpty ? nil : "(\(year))"].compactMap { $0 }.joined(separator: " ") }
    var shortAuthor: String? {
        let first = author.components(separatedBy: " and ").first ?? ""
        let last = first.contains(",") ? first.components(separatedBy: ",")[0] : first.split(separator: " ").last.map(String.init) ?? first
        let n = last.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        return author.contains(" and ") ? n + " et al." : n
    }
}

/// Minimal BibTeX reader: entries `@type{key, field = {value}, ...}`.
enum BibParser {
    static func parse(_ text: String) -> [BibEntry] {
        var out: [BibEntry] = []
        let chars = Array(text)
        var i = 0, line = 1
        while i < chars.count {
            if chars[i] == "\n" { line += 1 }
            if chars[i] == "@" {
                let startLine = line
                var j = i + 1
                var type = ""
                while j < chars.count, chars[j].isLetter { type.append(chars[j]); j += 1 }
                while j < chars.count, chars[j].isWhitespace { if chars[j] == "\n" { line += 1 }; j += 1 }
                guard j < chars.count, chars[j] == "{" || chars[j] == "(" else { i = j; continue }
                let open = chars[j], close: Character = open == "{" ? "}" : ")"
                var depth = 1; var k = j + 1
                var body = ""
                while k < chars.count, depth > 0 {
                    let c = chars[k]
                    if c == "\n" { line += 1 }
                    if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { break } }
                    body.append(c); k += 1
                }
                let t = type.lowercased()
                if !["comment", "string", "preamble"].contains(t) {
                    if let e = entry(type: t, body: body, line: startLine) { out.append(e) }
                }
                i = k + 1
                continue
            }
            i += 1
        }
        return out
    }

    private static func entry(type: String, body: String, line: Int) -> BibEntry? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let key = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return nil }
        let fields = String(body[body.index(after: comma)...])
        func field(_ name: String) -> String {
            guard let re = try? NSRegularExpression(pattern: "(?i)\\b\(name)\\s*=\\s*", options: []),
                  let m = re.firstMatch(in: fields, range: NSRange(fields.startIndex..., in: fields)),
                  let r = Range(m.range, in: fields) else { return "" }
            var rest = fields[r.upperBound...]
            guard let f = rest.first else { return "" }
            var val = ""
            if f == "{" || f == "\"" {
                let close: Character = f == "{" ? "}" : "\""
                var depth = 0
                rest = rest.dropFirst()
                for c in rest {
                    if f == "{" {
                        if c == "{" { depth += 1 } else if c == "}" { if depth == 0 { break }; depth -= 1 }
                    } else if c == close { break }
                    val.append(c)
                }
            } else {
                val = String(rest.prefix { $0 != "," && $0 != "\n" })
            }
            return val.replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return BibEntry(key: key, type: type, author: field("author").isEmpty ? field("editor") : field("author"),
                        title: field("title"), year: field("year").isEmpty ? field("date") : field("year"), line: line)
    }
}
