// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct SearchMatch: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var line: Int
    var column: Int
    var text: String          // the full line, trimmed
    var matchRange: Range<Int>?  // character offsets within `text` (after trimming)
}

enum ProjectSearch {
    static func search(query: String, texts: [String: String], caseSensitive: Bool, regex: Bool, wholeWord: Bool, limit: Int = 500) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b\(pattern)\\b" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        var out: [SearchMatch] = []
        for path in texts.keys.sorted() {
            let lines = texts[path]!.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range, in: line) else { continue }
                let lead = line.prefix { $0 == " " || $0 == "\t" }.count
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let start = line.distance(from: line.startIndex, to: r.lowerBound)
                let end = line.distance(from: line.startIndex, to: r.upperBound)
                out.append(SearchMatch(path: path, line: i + 1, column: start + 1, text: String(trimmed.prefix(300)),
                                       matchRange: max(0, start - lead)..<max(0, end - lead)))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Replace across files; returns new texts for files that changed.
    static func replace(query: String, with replacement: String, texts: [String: String], caseSensitive: Bool, regex: Bool, wholeWord: Bool) -> [String: String] {
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b\(pattern)\\b" }
        guard !query.isEmpty, let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [:] }
        var out: [String: String] = [:]
        for (path, text) in texts {
            let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement))
            if new != text { out[path] = new }
        }
        return out
    }
}
