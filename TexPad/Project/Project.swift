// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import SwiftUI

struct FileStamp: Equatable { var mtime: TimeInterval; var size: Int }

enum BuildState: Equatable {
    case idle
    case preparing
    case building
    case succeeded(ms: Int, passes: Int)
    case failed
}

/// One open project folder: files, tabs, buffers, index, builds.
@MainActor
final class Project: ObservableObject {
    let root: URL
    let engine: TeXEngine
    let editor = EditorController()

    @Published var tree: [FileNode] = []
    @Published var tabs: [String] = []
    @Published var active: String?
    @Published var dirty: Set<String> = []
    @Published var settings: ProjectSettings
    @Published var diagnostics: [Diagnostic] = []
    @Published var buildLog = ""
    @Published var buildState: BuildState = .idle
    @Published var pdf: Data?
    @Published var index = ProjectIndex()
    @Published var cursor = (line: 1, col: 1)
    @Published var selection = ""
    @Published var toast: String?

    var name: String { root.lastPathComponent }

    private var buffers: [String: String] = [:]     // text of open documents (source of truth while open)
    private var textCache: [String: String] = [:]   // text of all small text files, for indexing/search
    private var lastSent: [String: FileStamp] = [:]
    private var lastMain: String?
    private var saveTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var rebuildRequested = false
    private var packageData: (packages: [String], classes: [String])?

    init(root: URL, engine: TeXEngine) {
        self.root = root
        self.engine = engine
        var loaded = ProjectSettings.load(from: root)
        // .ipadtex.json lives inside the (possibly untrusted) project: never let it point outside the project.
        if !PathSafety.isSafeRelative(loaded.outputDir) { loaded.outputDir = "build" }
        if let m = loaded.mainFile, !PathSafety.isSafeRelative(m) { loaded.mainFile = nil }
        self.settings = loaded
        editor.onEvent = { [weak self] e in self?.handle(e) }
        reloadTree()
        loadAllText()
        rebuildIndex()
        loadPackageData()
        if let main = resolveMain() { open(main) }
        Task { _ = await engine.prepare() }
    }

    // MARK: - editor events

    private func handle(_ e: EditorEvent) {
        switch e {
        case .ready:
            applyEditorPrefs()
            #if DEBUG
            if let js = ProcessInfo.processInfo.environment["TEXPAD_EDITOR_JS"] {
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.editor.evalDebug(js) }
            }
            #endif
            if let a = active, let t = buffers[a] { editor.open(path: a, text: t) }
            pushProjectData()
        case .change(let path, let text):
            guard tabs.contains(path), PathSafety.isSafeRelative(path) else { return }
            buffers[path] = text; textCache[path] = text
            scheduleSave(); scheduleIndex()
        case .dirty(let path): if tabs.contains(path) { dirty.insert(path) }
        case .save: saveAll()
        case .cursor(_, let l, let c, let sel): cursor = (l, c); selection = sel
        case .build: build()
        case .palette, .quickOpen, .searchProject: NotificationCenter.default.post(name: .editorShortcut, object: e.shortcutName)
        }
    }

    func applyEditorPrefs() {
        let d = UserDefaults.standard
        editor.setTheme(d.string(forKey: "theme") ?? "system")
        editor.setFontSize(d.object(forKey: "fontSize") as? Int ?? 15)
        editor.setWrap(d.object(forKey: "wrap") as? Bool ?? true)
    }

    // MARK: - tree & text loading

    func reloadTree() { tree = FileTree.scan(root: root) }

    private func loadAllText() {
        textCache = [:]
        for n in FileTree.flatten(tree) where n.isText && !n.isDirectory && n.path != ProjectSettings.fileName {
            if n.path.hasPrefix(settings.outputDir + "/") { continue }
            let u = root.appendingPathComponent(n.path)
            if let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 2_000_000 { continue }
            if let t = try? String(contentsOf: u, encoding: .utf8) { textCache[n.path] = t }
        }
    }

    func text(of path: String) -> String? { buffers[path] ?? textCache[path] }

    /// Poison URL used for rejected paths: every file operation on it fails (ENOTDIR).
    private static let invalidURL = URL(fileURLWithPath: "/dev/null/invalid")

    /// Project-relative path -> file URL. Anything that isn't a plain relative path inside the project gets the poison URL.
    func url(_ path: String) -> URL {
        if path.isEmpty { return root }
        return PathSafety.resolve(path, in: root) ?? Self.invalidURL
    }

    // MARK: - open / close / save

    func open(_ path: String, line: Int = 0, col: Int = 1) {
        guard PathSafety.isSafeRelative(path) else { return }   // paths from TeX logs are attacker-controlled
        let node = FileTree.flatten(tree).first { $0.path == path }
        if node?.isDirectory == true { return }
        if !tabs.contains(path) { tabs.append(path) }
        active = path
        guard node?.isText ?? FileKind.isText(ext: (path as NSString).pathExtension.lowercased(), name: (path as NSString).lastPathComponent) else { return }
        if buffers[path] == nil {
            buffers[path] = (try? String(contentsOf: url(path), encoding: .utf8)) ?? ""
        }
        editor.open(path: path, text: buffers[path] ?? "", line: line, col: col)
        pushDiagnostics(for: path)
    }

    func close(_ path: String) {
        if dirty.contains(path) { save(path) }
        tabs.removeAll { $0 == path }
        buffers[path] = nil
        editor.close(path: path)
        if active == path {
            active = tabs.last
            if let a = active { open(a) }
        }
    }

    func save(_ path: String) {
        guard let text = buffers[path], dirty.contains(path) else { return }
        do { try text.write(to: url(path), atomically: true, encoding: .utf8); dirty.remove(path) }
        catch { toast = "Couldn't save \(path): \(error.localizedDescription)" }
    }

    func saveAll() {
        saveTask?.cancel()
        let was = !dirty.isEmpty
        for p in dirty { save(p) }
        if was, settings.autoBuild, UserDefaults.standard.object(forKey: "autoBuild") as? Bool ?? true { scheduleAutoBuild() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard UserDefaults.standard.object(forKey: "autoSave") as? Bool ?? true else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { self?.saveAll() }
        }
    }

    private var autoBuildTask: Task<Void, Never>?
    private func scheduleAutoBuild() {
        autoBuildTask?.cancel()
        autoBuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { self?.build() }
        }
    }

    // MARK: - file operations

    @discardableResult
    func createFile(in dir: String, name: String, contents: String = "") -> String? {
        guard dir.isEmpty || PathSafety.isSafeRelative(dir), PathSafety.isSafeRelative(name) else { toast = "Invalid file name"; return nil }
        let rel = dir.isEmpty ? name : dir + "/" + name
        let u = url(rel)
        guard !FileManager.default.fileExists(atPath: u.path) else { toast = "\(name) already exists"; return nil }
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: u, atomically: true, encoding: .utf8)
        } catch { toast = error.localizedDescription; return nil }
        textCache[rel] = contents
        reloadTree(); open(rel); scheduleIndex()
        return rel
    }

    func createFolder(in dir: String, name: String) {
        guard dir.isEmpty || PathSafety.isSafeRelative(dir), PathSafety.isSafeRelative(name) else { toast = "Invalid folder name"; return }
        let rel = dir.isEmpty ? name : dir + "/" + name
        do { try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true) } catch { toast = error.localizedDescription }
        reloadTree()
    }

    func rename(_ path: String, to newName: String) {
        guard PathSafety.isSafeName(newName) else { toast = "Invalid name"; return }
        let dir = (path as NSString).deletingLastPathComponent
        let newPath = dir.isEmpty ? newName : dir + "/" + newName
        move(path, to: newPath)
    }

    func move(_ path: String, to newPath: String) {
        guard path != newPath else { return }
        // `path` may come from a drag-and-drop payload (any app can drop text here): only move things that are really in the project.
        guard PathSafety.isSafeRelative(path), PathSafety.isSafeRelative(newPath),
              FileTree.flatten(tree).contains(where: { $0.path == path }) else { return }
        guard !newPath.hasPrefix(path + "/") else { toast = "Can't move a folder into itself"; return }
        guard !FileManager.default.fileExists(atPath: url(newPath).path) else { toast = "\((newPath as NSString).lastPathComponent) already exists there"; return }
        do {
            try FileManager.default.createDirectory(at: url(newPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url(path), to: url(newPath))
        } catch { toast = error.localizedDescription; return }
        func remap(_ p: String) -> String { p == path ? newPath : (p.hasPrefix(path + "/") ? newPath + p.dropFirst(path.count) : p) }
        tabs = tabs.map(remap)
        for (k, v) in buffers where remap(k) != k { buffers[remap(k)] = v; buffers[k] = nil; editor.rename(from: k, to: remap(k)) }
        dirty = Set(dirty.map(remap))
        if let a = active { active = remap(a) }
        if settings.mainFile.map(remap) != settings.mainFile { settings.mainFile = settings.mainFile.map(remap); settings.save(to: root) }
        reloadTree(); loadAllText(); scheduleIndex()
    }

    func delete(_ path: String) {
        guard PathSafety.isSafeRelative(path), FileTree.flatten(tree).contains(where: { $0.path == path }) else { return }
        do { try FileManager.default.removeItem(at: url(path)) } catch { toast = error.localizedDescription; return }
        for t in tabs where t == path || t.hasPrefix(path + "/") { tabs.removeAll { $0 == t }; buffers[t] = nil; dirty.remove(t); editor.close(path: t) }
        if let a = active, !tabs.contains(a) { active = tabs.last; if let n = active { open(n) } }
        reloadTree(); loadAllText(); scheduleIndex()
    }

    func duplicate(_ path: String) {
        guard PathSafety.isSafeRelative(path) else { return }
        let ext = (path as NSString).pathExtension, base = (path as NSString).deletingPathExtension
        var n = 2, candidate = "\(base) copy" + (ext.isEmpty ? "" : "." + ext)
        while FileManager.default.fileExists(atPath: url(candidate).path) { candidate = "\(base) copy \(n)" + (ext.isEmpty ? "" : "." + ext); n += 1 }
        try? FileManager.default.copyItem(at: url(path), to: url(candidate))
        reloadTree(); loadAllText(); scheduleIndex()
    }

    func importFiles(_ urls: [URL], into dir: String) {
        guard dir.isEmpty || PathSafety.isSafeRelative(dir) else { return }
        for u in urls where PathSafety.isSafeName(u.lastPathComponent) {
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dst = url(dir.isEmpty ? u.lastPathComponent : dir + "/" + u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            do { try FileManager.default.copyItem(at: u, to: dst) } catch { toast = error.localizedDescription }
        }
        reloadTree(); loadAllText(); scheduleIndex()
    }

    func setMainFile(_ path: String?) { settings.mainFile = path; settings.save(to: root) }

    /// Pick up edits made outside the app (Files, iCloud) when the app returns to the foreground.
    func refreshFromDisk() {
        reloadTree()
        for p in tabs where !dirty.contains(p) {
            guard let disk = try? String(contentsOf: url(p), encoding: .utf8), disk != buffers[p] else { continue }
            buffers[p] = disk; textCache[p] = disk; editor.reload(path: p, text: disk)
        }
        loadAllText(); scheduleIndex()
    }

    // MARK: - index

    private func scheduleIndex() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { self?.rebuildIndex() }
        }
    }

    func rebuildIndex() {
        index = ProjectIndex.build(texts: textCache, mainFirst: resolveMain())
        pushProjectData()
    }

    private func loadPackageData() {
        if let u = Bundle.main.url(forResource: "web", withExtension: nil)?.appendingPathComponent("editor/packages.json"),
           let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] {
            packageData = (j["packages"] ?? [], j["classes"] ?? [])
        }
    }

    func pushProjectData() {
        let files = FileTree.flatten(tree).filter { !$0.isDirectory }
        let local = files.filter { $0.ext == "sty" || $0.ext == "cls" }.map { ($0.name as NSString).deletingPathExtension }
        editor.setProjectData([
            "labels": index.labels.map { ["key": $0.key, "detail": "\($0.path):\($0.line)"] },
            "cites": index.citations.map { ["key": $0.key, "detail": $0.detail, "info": $0.title] },
            "files": files.filter { $0.ext == "tex" }.map { $0.path },
            "images": files.filter { $0.isImage || $0.isPDF || ["eps", "svg"].contains($0.ext) }.map { $0.path },
            "bibs": files.filter { $0.ext == "bib" }.map { $0.path },
            "packages": Array(Set((packageData?.packages ?? []) + local)).sorted(),
            "classes": Array(Set((packageData?.classes ?? []) + files.filter { $0.ext == "cls" }.map { ($0.name as NSString).deletingPathExtension })).sorted(),
        ])
    }

    // MARK: - search

    func search(_ q: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool) -> [SearchMatch] {
        var texts = textCache
        for (p, t) in buffers { texts[p] = t }
        return ProjectSearch.search(query: q, texts: texts, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
    }

    func replaceAll(_ q: String, with r: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool) -> Int {
        var texts = textCache
        for (p, t) in buffers { texts[p] = t }
        let changed = ProjectSearch.replace(query: q, with: r, texts: texts, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
        for (p, t) in changed {
            try? t.write(to: url(p), atomically: true, encoding: .utf8)
            textCache[p] = t
            if buffers[p] != nil { buffers[p] = t; dirty.remove(p); editor.reload(path: p, text: t) }
        }
        scheduleIndex()
        return changed.count
    }

    // MARK: - build

    static let buildTimeout: TimeInterval = 120

    private static let magicRoot = #"^\s*%\s*!TEX\s+root\s*=\s*(.+?)\s*$"#

    func resolveMain() -> String? {
        if let m = settings.mainFile, textCache[m] != nil || FileManager.default.fileExists(atPath: url(m).path) { return m }
        if let a = active, let t = buffers[a] ?? textCache[a] {
            for line in t.components(separatedBy: "\n").prefix(10) {
                if let m = LogParser.firstMatch(Self.magicRoot, in: line) {
                    let dir = (a as NSString).deletingLastPathComponent
                    let joined = dir.isEmpty ? m[1] : dir + "/" + m[1]
                    let norm = URL(fileURLWithPath: "/" + joined).standardized.path.dropFirst()
                    if textCache[String(norm)] != nil { return String(norm) }
                }
            }
            if t.contains("\\documentclass") { return a }
        }
        let roots = textCache.filter { $0.key.hasSuffix(".tex") && $0.value.contains("\\documentclass") }.keys
            .sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        if let m = roots.first(where: { $0 == "main.tex" }) { return m }
        return roots.first
    }

    var mainName: String? { resolveMain() }

    func build() {
        if buildTask != nil { rebuildRequested = true; return }
        buildTask = Task { [weak self] in
            await self?.runBuild()
            guard let self else { return }
            self.buildTask = nil
            if self.rebuildRequested { self.rebuildRequested = false; self.build() }
        }
    }

    private func isExcludedFromEngine(_ rel: String) -> Bool {
        rel.hasPrefix(settings.outputDir + "/") || rel.hasPrefix(".") || rel.contains("/.")
    }

    private func runBuild() async {
        for p in dirty { save(p) }
        guard let main = resolveMain() else { toast = "No root .tex file (with \\documentclass) found"; buildState = .failed; return }
        buildState = .preparing
        guard await engine.prepare() else { buildState = .failed; buildLog = "Engine failed to start"; return }
        buildState = .building

        // Collect files that changed since the last build.
        let fm = FileManager.default
        var current: [String: FileStamp] = [:]
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                let rel = String(u.path.dropFirst(root.path.count + 1))
                if isExcludedFromEngine(rel) { if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { en.skipDescendants() }; continue }
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, size <= 25_000_000 else { continue }
                current[rel] = FileStamp(mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, size: size)
            }
        }
        let removed = Set(lastSent.keys).subtracting(current.keys)
        let reset = !removed.isEmpty || lastMain != main
        let toSend = current.filter { reset || lastSent[$0.key] != $0.value }.keys
        var payload: [String: Data] = [:]
        for rel in toSend { if let d = try? Data(contentsOf: url(rel)) { payload[rel] = d } }

        engine.handler.clearMisses()
        do {
            let r = try await withTimeout(seconds: Self.buildTimeout) { [engine] in
                try await engine.build(files: payload, main: main, reset: reset)
            }
            lastSent = current; lastMain = main
            buildLog = r.log.count > 200_000 ? String(r.log.prefix(200_000)) + "\n… (log truncated)" : r.log
            diagnostics = LogParser.parse(r.log)
            if r.ok, let data = r.pdf {
                pdf = data
                buildState = .succeeded(ms: r.ms, passes: r.passes)
                writeOutputs(main: main, pdf: data, log: r.log)
            } else {
                buildState = .failed
                diagnostics += missingFileHints(engine.handler.takeMisses())
                if diagnostics.allSatisfy({ $0.severity != .error }) {
                    diagnostics.insert(Diagnostic(severity: .error, message: "Build failed (status \(r.log.isEmpty ? "no log" : "see log"))", file: main, line: nil, context: nil), at: 0)
                }
            }
            pushAllDiagnostics()
        } catch {
            buildState = .failed
            let timedOut = error is BuildTimeout
            // A hung or crashed engine (infinite macro loop, out of memory) is thrown away and restarted.
            engine.restart()
            lastSent = [:]; lastMain = nil
            let msg = timedOut ? "Build timed out after \(Int(Self.buildTimeout)) s (an infinite loop or a very large document?). The engine was restarted."
                               : "The engine stopped unexpectedly (possibly out of memory) and was restarted."
            buildLog = msg + "\n\(error)"
            diagnostics = [Diagnostic(severity: .error, message: msg, file: nil, line: nil, context: nil)]
        }
    }

    /// Turns the engine's "file not found" requests into hints about how to supply the file.
    private func missingFileHints(_ misses: Set<String>) -> [Diagnostic] {
        let noise: Set<String> = ["cfg", "dfu", "aux", "out", "bbl", "toc", "lof", "lot", "pgc", "log", "ini", "nav", "snm", "vrb", "bcf", "blg", "idx", "ind", "glo", "gls"]
        var hints: [Diagnostic] = []
        for m in misses.sorted() {
            let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let fmt = Int(parts[0]) else { continue }
            let name = parts[1]
            if name.hasSuffix(":") || noise.contains((name as NSString).pathExtension.lowercased()) { continue }
            let kind: String
            switch fmt { case 26: kind = "TeX file"; case 3: kind = "font metrics (.tfm)"; case 32: kind = "Type 1 font"; case 7: kind = "BibTeX style (.bst)"; default: continue }
            if fmt == 26 && textCache[name] != nil { continue }
            hints.append(Diagnostic(severity: .info, message: "Not found: \(name) (\(kind)). If your project needs it, add it to the project folder or to TexPad/TeXExtras in the Files app.",
                                    file: nil, line: nil, context: nil))
        }
        return hints
    }

    private func writeOutputs(main: String, pdf: Data, log: String) {
        guard let outDir = PathSafety.resolve(settings.outputDir, in: root) else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
        try? pdf.write(to: outDir.appendingPathComponent(base + ".pdf"), options: .atomic)
        try? log.write(to: outDir.appendingPathComponent(base + ".log"), atomically: true, encoding: .utf8)
        reloadTree()
    }

    // MARK: - diagnostics

    private var lastDiagnosticPaths: Set<String> = []

    func pushAllDiagnostics() {
        let main = resolveMain()
        let grouped = Dictionary(grouping: diagnostics.filter { $0.line != nil }) { d -> String in
            if let f = d.file, LogParser.isProjectFile(f) { return f }
            return main ?? ""
        }
        for p in lastDiagnosticPaths.subtracting(grouped.keys) { editor.setDiagnostics(path: p, items: []) }
        for (p, list) in grouped where !p.isEmpty {
            editor.setDiagnostics(path: p, items: list.filter { $0.severity != .info }.map {
                ["line": $0.line ?? 1, "severity": $0.severity == .error ? "error" : "warning", "message": $0.message]
            })
        }
        lastDiagnosticPaths = Set(grouped.keys)
    }

    private func pushDiagnostics(for path: String) {
        let items = diagnostics.filter { $0.line != nil && $0.severity != .info && (($0.file ?? resolveMain()) == path) }
        guard !items.isEmpty else { return }
        editor.setDiagnostics(path: path, items: items.map {
            ["line": $0.line ?? 1, "severity": $0.severity == .error ? "error" : "warning", "message": $0.message]
        })
    }

    func jump(to d: Diagnostic) {
        guard let f = d.file, LogParser.isProjectFile(f) else {
            if let m = resolveMain(), let l = d.line { open(m, line: l) }
            return
        }
        open(f, line: d.line ?? 1)
    }

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    func saveBuildOutput() -> URL? {
        guard let main = resolveMain() else { return nil }
        let base = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
        return url(settings.outputDir + "/" + base + ".pdf")
    }
}

extension EditorEvent {
    var shortcutName: String {
        switch self { case .palette: return "palette"; case .quickOpen: return "quickOpen"; case .searchProject: return "search"; default: return "" }
    }
}

extension Notification.Name { static let editorShortcut = Notification.Name("editorShortcut") }


struct BuildTimeout: Error {}

/// Runs `op`, but gives up after `seconds` even if `op` never returns (a hung WebAssembly call can't be cancelled).
@MainActor
func withTimeout<T>(seconds: TimeInterval, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        var finished = false
        Task { @MainActor in
            do { let v = try await op(); if !finished { finished = true; cont.resume(returning: v) } }
            catch { if !finished { finished = true; cont.resume(throwing: error) } }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !finished { finished = true; cont.resume(throwing: BuildTimeout()) }
        }
    }
}
