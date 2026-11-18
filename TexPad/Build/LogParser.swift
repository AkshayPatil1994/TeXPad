// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

struct Diagnostic: Identifiable, Equatable {
    enum Severity: Int { case error = 0, warning = 1, info = 2 }
    let id = UUID()
    var severity: Severity
    var message: String
    var file: String?      // project-relative path when known
    var line: Int?         // 1-based
    var context: String?   // source excerpt TeX printed after `l.N`

    static func == (a: Diagnostic, b: Diagnostic) -> Bool {
        a.severity == b.severity && a.message == b.message && a.file == b.file && a.line == b.line
    }
}

/// Parses pdfTeX terminal/log output into diagnostics. Pure Foundation so it is unit-testable.
enum LogParser {
    static let maxPrintLine = 79

    /// A hostile document can produce huge logs (or one endless 79-column-wrapped "line"); bound the work.
    static let maxLogBytes = 2_000_000
    static let maxLineLength = 2_000
    static let maxDiagnostics = 500

    static func parse(_ rawLog: String) -> [Diagnostic] {
        let raw = rawLog.utf8.count > maxLogBytes ? String(decoding: Array(rawLog.utf8.prefix(maxLogBytes)), as: UTF8.self) : rawLog
        let lines = unwrap(raw).map { $0.count > maxLineLength ? String($0.prefix(maxLineLength)) : $0 }
        var out: [Diagnostic] = []
        var stack: [String?] = []
        var i = 0

        func currentFile() -> String? {
            // innermost open file; bundled TeX files (/tex/...) are reported as-is so the UI can tell them apart
            for f in stack.reversed() { if let f { return normalize(f) } }
            return nil
        }

        while i < lines.count, out.count < maxDiagnostics {
            let line = lines[i]

            if line.hasPrefix("! ") {
                var msg = String(line.dropFirst(2))
                var ctx: String?
                var ln: Int?
                var j = i + 1
                while j < lines.count, j < i + 12 {
                    let l = lines[j]
                    if let m = firstMatch(#"^l\.(\d+)\s?(.*)$"#, in: l) {
                        ln = Int(m[1]); ctx = m[2]; break
                    }
                    if l.hasPrefix("! ") { break }
                    if !l.trimmingCharacters(in: .whitespaces).isEmpty, !l.hasPrefix("Type ") , !l.hasPrefix("See the") ,
                       !l.hasPrefix("<") , !l.hasPrefix("\\") , !l.hasPrefix("?"), !l.hasPrefix("Your command") {
                        if msg.count < 200, !l.hasPrefix(" ") { msg += " " + l.trimmingCharacters(in: .whitespaces) }
                    }
                    j += 1
                }
                if !msg.contains("==> Fatal error occurred") {
                    out.append(Diagnostic(severity: .error, message: msg, file: currentFile(), line: ln, context: ctx))
                }
                i += 1
                continue
            }
            // file:line:error style
            if let m = firstMatch(#"^(\.?/?[^\s:()]+\.\w+):(\d+): (.+)$"#, in: line) {
                out.append(Diagnostic(severity: .error, message: m[3], file: normalize(m[1]), line: Int(m[2]), context: nil))
                i += 1; continue
            }

            if let w = warning(at: i, lines: lines) {
                var d = w.diag
                if d.file == nil { d.file = currentFile() }
                out.append(d)
                i = w.next
                updateStack(&stack, with: line)  // parens on the first warning line
                continue
            }

            updateStack(&stack, with: line)
            i += 1
        }
        return out
    }

    // MARK: warnings

    private static func warning(at i: Int, lines: [String]) -> (diag: Diagnostic, next: Int)? {
        let line = lines[i]
        let isLaTeX = line.hasPrefix("LaTeX Warning:") || line.hasPrefix("LaTeX Font Warning:")
        let isPkg = firstMatch(#"^(Package|Class) \S+ Warning:"#, in: line) != nil
        if isLaTeX || isPkg {
            var text = line
            var j = i + 1
            // continuation lines until blank line
            while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty, j < i + 8 {
                let l = lines[j]
                if l.hasPrefix("(") , !l.hasPrefix("(\\") { break }
                text += " " + l.trimmingCharacters(in: .whitespaces)
                if text.contains("on input line") { j += 1; break }
                j += 1
            }
            let ln = firstMatch(#"on input line (\d+)"#, in: text).flatMap { Int($0[1]) }
            var msg = text.replacingOccurrences(of: "LaTeX Warning: ", with: "")
            msg = msg.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return (Diagnostic(severity: .warning, message: msg, file: nil, line: ln, context: nil), j)
        }
        if let m = firstMatch(#"^(Overfull|Underfull) \\[hv]box .*?(?:at lines (\d+)--\d+|at line (\d+)|detected at line (\d+))"#, in: line) {
            let n = [m[2], m[3], m[4]].compactMap { Int($0) }.first
            return (Diagnostic(severity: .info, message: String(line.prefix(160)), file: nil, line: n, context: nil), i + 1)
        }
        return nil
    }

    // MARK: file stack

    private static func updateStack(_ stack: inout [String?], with line: String) {
        let chars = Array(line)
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if c == "(" {
                var j = k + 1
                var tok = ""
                while j < chars.count, !chars[j].isWhitespace, chars[j] != ")", chars[j] != "(" { tok.append(chars[j]); j += 1 }
                stack.append(looksLikeFile(tok) ? tok : nil)
                k = j
                continue
            } else if c == ")" {
                if !stack.isEmpty { stack.removeLast() }
            }
            k += 1
        }
    }

    private static func looksLikeFile(_ t: String) -> Bool {
        guard !t.isEmpty, !t.hasPrefix("\\") else { return false }
        if t.hasPrefix("./") || t.hasPrefix("/") { return true }
        let ext = (t as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Files from the bundled TeX tree live under /tex/ — they are not project files.
    static func isProjectFile(_ f: String) -> Bool { !f.hasPrefix("/tex/") }

    private static func normalize(_ f: String) -> String {
        var p = f
        if p.hasPrefix("/work/") { p.removeFirst("/work/".count) }
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    // MARK: helpers

    /// TeX hard-wraps its output at 79 columns; re-join those lines.
    static func unwrap(_ raw: String) -> [String] {
        let src = raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var out: [String] = []
        var cur = ""
        for (idx, l) in src.enumerated() {
            cur += l
            if l.count == maxPrintLine, idx + 1 < src.count, cur.count < maxLineLength * 2 { continue }
            out.append(cur); cur = ""
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : String(s[Range(r, in: s)!])
        }
    }
}
