// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct OutlineItem: Identifiable, Equatable {
    var id: String { "\(path):\(line)" }
    var level: Int        // 0 part, 1 chapter, 2 section, 3 subsection, 4 subsubsection, 5 paragraph
    var title: String
    var path: String
    var line: Int
}

struct LabelItem: Equatable { var key: String; var path: String; var line: Int }

/// Static analysis of a LaTeX project: outline, labels, bibliography keys, includes, packages.
struct ProjectIndex: Equatable {
    var outline: [OutlineItem] = []
    var labels: [LabelItem] = []
    var citations: [BibEntry] = []
    var citationFile: [String: String] = [:]   // key -> .bib path
    var packages: Set<String> = []
    var includes: [String: [String]] = [:]    // file -> files it \input/\include's

    private static let levels = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5]

    /// `texts`: project-relative path -> contents (only .tex-like and .bib files are needed).
    static func build(texts: [String: String], mainFirst main: String?) -> ProjectIndex {
        var idx = ProjectIndex()
        let ordered = texts.keys.sorted()
        // Order outline by \input graph from main when possible; fall back to alphabetical.
        var visited = Set<String>(); var order: [String] = []
        func visit(_ p: String) {
            guard texts[p] != nil, !visited.contains(p) else { return }
            visited.insert(p); order.append(p)
            for c in includesOf(texts[p]!, from: p, existing: texts) { visit(c) }
        }
        if let main { visit(main) }
        for p in ordered where p.hasSuffix(".tex") && !visited.contains(p) { visit(p) }

        for path in order {
            guard let text = texts[path] else { continue }
            let lines = text.components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let l = stripComment(raw)
                if let m = LogParser.firstMatch(#"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?(?:\[[^\]]*\])?\{([^}]*)\}?"#, in: l) {
                    idx.outline.append(OutlineItem(level: levels[m[1]] ?? 2, title: m[2].trimmingCharacters(in: .whitespaces), path: path, line: i + 1))
                }
                for m in matches(#"\\label\{([^}]+)\}"#, in: l) { idx.labels.append(LabelItem(key: m, path: path, line: i + 1)) }
                for m in matches(#"\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{([^}]+)\}"#, in: l) {
                    for p in m.split(separator: ",") { idx.packages.insert(p.trimmingCharacters(in: .whitespaces)) }
                }
            }
            idx.includes[path] = includesOf(text, from: path, existing: texts)
        }
        for path in ordered where path.hasSuffix(".bib") {
            for e in BibParser.parse(texts[path] ?? "") { idx.citations.append(e); idx.citationFile[e.key] = path }
        }
        return idx
    }

    static func includesOf(_ text: String, from path: String, existing: [String: String]) -> [String] {
        var out: [String] = []
        let dir = (path as NSString).deletingLastPathComponent
        for raw in text.components(separatedBy: "\n") {
            for name in matches(#"\\(?:input|include|subfile)\{([^}]+)\}"#, in: stripComment(raw)) {
                for cand in [name, name + ".tex"] {
                    let rel = (dir.isEmpty ? cand : dir + "/" + cand)
                    if existing[cand] != nil { out.append(cand); break }
                    if existing[rel] != nil { out.append(rel); break }
                }
            }
        }
        return out
    }

    static func stripComment(_ s: String) -> String {
        var prev: Character = " "
        for (i, c) in s.enumerated() {
            if c == "%" && prev != "\\" { return String(s.prefix(i)) }
            prev = c
        }
        return s
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } : nil
        }
    }

    /// Where a label/citation is defined (for go-to-definition).
    func location(ofLabel key: String) -> (path: String, line: Int)? {
        labels.first { $0.key == key }.map { ($0.path, $0.line) }
    }
    func location(ofCitation key: String) -> (path: String, line: Int)? {
        guard let e = citations.first(where: { $0.key == key }), let p = citationFile[key] else { return nil }
        return (p, e.line)
    }
}
