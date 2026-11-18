// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import WebKit

/// Serves `tex://app/...` — the engine web assets plus the offline TeX tree.
///   tex://app/<file>                      -> bundle `web/<file>`
///   tex://app/tl/pdftex/<fmt>/<name>      -> bundle `texlive/<name>` or cache dir
final class TeXSchemeHandler: NSObject, WKURLSchemeHandler {
    let cacheDir: URL
    private let webDir: URL?
    private let texDir: URL?
    private let missLogURL: URL
    /// User-supplied TeX files (Files app > TexPad > TeXExtras), searched recursively by file name.
    let extrasDir: URL
    private var extrasIndex: [String: URL] = [:]
    private(set) var misses: Set<String> = []

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
        self.webDir = Bundle.main.url(forResource: "web", withExtension: nil)
        self.texDir = Bundle.main.url(forResource: "texlive", withExtension: nil)
        self.missLogURL = cacheDir.appendingPathComponent("tex-misses.txt")
        self.extrasDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TeXExtras")
        super.init()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        prepareExtras()
    }

    // MARK: user-supplied TeX files

    private func prepareExtras() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: extrasDir.path) {
            try? fm.createDirectory(at: extrasDir, withIntermediateDirectories: true)
            let note = """
            Put extra LaTeX packages, classes, BibTeX styles and fonts in this folder (sub-folders are fine).
            TexPad finds files here by name when a build needs something that isn't bundled, e.g. foo.sty, bar.cls, baz.bst, qux.tfm.
            Copy them in from the Files app, then reopen the project or tap "Rescan TeX extras" in Settings.
            """
            try? note.write(to: extrasDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        }
        rescanExtras()
    }

    /// Re-reads TeXExtras; returns the number of files indexed.
    @discardableResult
    func rescanExtras() -> Int {
        var idx: [String: URL] = [:]
        if let en = FileManager.default.enumerator(at: extrasDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if u.lastPathComponent != "README.txt" { idx[u.lastPathComponent] = u }
            }
        }
        extrasIndex = idx
        return idx.count
    }
    var extrasCount: Int { extrasIndex.count }

    func takeMisses() -> Set<String> { let m = misses; misses = []; return m }
    func clearMisses() { misses = [] }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path
        var fileURL: URL?
        var fileID = ""

        if path.hasPrefix("/tl/pdftex/") {
            let parts = path.dropFirst("/tl/pdftex/".count).split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let fmt = Int(parts[0]), PathSafety.isSafeTeXName(parts[1]) {
                let name = parts[1]
                fileID = parts[0] + "_" + name
                if let c = lookup(name, fmt: fmt) {
                    fileURL = c
                } else {
                    logMiss("\(parts[0])/\(name)")
                }
            }
        } else if let dir = webDir {
            let rel = path == "/" ? "engine.html" : String(path.dropFirst())
            if let c = PathSafety.resolve(rel, in: dir), Self.servedWebExtensions.contains(c.pathExtension.lowercased()),
               FileManager.default.fileExists(atPath: c.path) { fileURL = c }
        }

        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: url, status: 404, headers: [:], body: Data())
            return
        }
        var headers = ["Content-Type": mime(fileURL.pathExtension),
                       "Content-Length": "\(data.count)",
                       "X-Content-Type-Options": "nosniff"]
        headers["fileid"] = fileURL.lastPathComponent
        respond(task, url: url, status: 200, headers: headers, body: data)
    }

    private static let servedWebExtensions: Set<String> = ["html", "js", "wasm", "json"]

    /// kpathsea file-type numbers (see kpse_*_format enum in the engine).
    private static func extensions(for fmt: Int) -> [String] {
        switch fmt {
        case 3: return [".tfm", ""]
        case 6: return [".bib", ""]
        case 7: return [".bst", ""]
        case 11: return ["", ".map"]
        case 32: return [".pfb", ""]
        case 33: return [".vf", ""]
        case 44: return [".enc", ""]
        default: return ["", ".tex", ".sty", ".cls", ".def", ".cfg", ".clo", ".fd", ".ltx", ".tfm", ".pfb", ".vf", ".enc", ".map"]
        }
    }

    /// kpathsea asks for bare names ("cmr10"); try the suffixes that make sense for the requested type.
    func lookup(_ name: String, fmt: Int) -> URL? {
        guard PathSafety.isSafeTeXName(name) else { return nil }
        let fm = FileManager.default
        let exts = Self.extensions(for: fmt)
        for dir in [cacheDir, texDir].compactMap({ $0 }) {
            for e in exts {
                let u = dir.appendingPathComponent(name + e)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue, PathSafety.isInside(u, base: dir) { return u }
            }
            if dir == cacheDir {   // user extras take priority over the bundle, but not over the generated format file
                for e in exts { if let u = extrasIndex[name + e], PathSafety.isInside(u, base: extrasDir) { return u } }
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, headers: [String: String], body: Data) {
        var h = headers
        h["Access-Control-Expose-Headers"] = "fileid"
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }

    private func mime(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }

    private func logMiss(_ s: String) {
        if misses.count < 2000 { misses.insert(s) }
        #if DEBUG
        NSLog("[tex] miss %@", s)
        if let h = try? FileHandle(forWritingTo: missLogURL) {
            h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
        } else {
            try? (s + "\n").write(to: missLogURL, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
