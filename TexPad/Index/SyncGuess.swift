// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Best-effort source<->PDF navigation. The bundled pdfTeX has no SyncTeX, so we match visible text.
enum SyncGuess {
    /// Turns a source line into a short plain-text query to look up in the PDF text layer.
    static func pdfQuery(forSourceLine raw: String) -> String? {
        var s = ProjectIndex.stripComment(raw)
        s = s.replacingOccurrences(of: #"\\(?:label|ref|eqref|cite[a-z]*|includegraphics|input|include|usepackage|documentclass)(\[[^\]]*\])?\{[^}]*\}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+\*?"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[{}$&~^_\\\[\]]"#, with: " ", options: .regularExpression)
        let words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return nil }
        let take = Array(words.prefix(5))
        let q = take.joined(separator: " ")
        return q.count >= 4 ? q : nil
    }

    /// Finds the source line that best matches text selected/tapped in the PDF.
    static func source(forPDFText text: String, texts: [String: String]) -> (path: String, line: Int)? {
        let target = Set(words(text).filter { $0.count >= 3 })
        guard target.count >= 1 else { return nil }
        var best: (score: Double, path: String, line: Int)?
        for path in texts.keys.sorted() where path.hasSuffix(".tex") {
            let lines = texts[path]!.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                let lw = Set(words(plain(l)))
                if lw.isEmpty { continue }
                let hit = Double(target.intersection(lw).count)
                let score = hit / Double(target.count) + 0.01 * hit
                if hit > 0, best == nil || score > best!.score { best = (score, path, i + 1) }
            }
        }
        guard let b = best, b.score >= 0.5 else { return nil }
        return (b.path, b.line)
    }

    private static func plain(_ l: String) -> String {
        ProjectIndex.stripComment(l).replacingOccurrences(of: #"\\[a-zA-Z]+\*?"#, with: " ", options: .regularExpression)
    }
    private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
