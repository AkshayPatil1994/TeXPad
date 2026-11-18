// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import SwiftUI
import Combine

struct RecentProject: Codable, Identifiable, Equatable {
    var id: String { name + bookmark.base64EncodedString().prefix(16) }
    var name: String
    var bookmark: Data
    var lastOpened: Date
}

/// App-level state: the shared engine, recent projects (security-scoped bookmarks) and the open project.
@MainActor
final class ProjectStore: ObservableObject {
    @Published var project: Project?
    @Published var recents: [RecentProject] = []
    @Published var openError: String?

    let engine = TeXEngine()
    private let recentsKey = "recentProjects.v1"
    private var scopedURL: URL?
    private var engineObserver: AnyCancellable?

    init() {
        engineObserver = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        loadRecents()
        #if DEBUG
        // Dev/test hook: TEXPAD_CLONE_URL=https://… clones a public repository and writes the outcome to Documents/clone-result.txt.
        if let cloneURL = ProcessInfo.processInfo.environment["TEXPAD_CLONE_URL"] {
            Task { @MainActor in
                let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("clone-result.txt")
                do {
                    let t0 = Date()
                    try await self.cloneRepository(urlString: cloneURL, username: "", token: "", parent: nil, cancel: GitCancelToken()) { _, _ in }
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: self.project?.root.path ?? "")) ?? []
                    let st = try? await self.project?.git.refresh()
                    _ = st
                    try "OK \(String(format: "%.1f", Date().timeIntervalSince(t0)))s branch=\(self.project?.git.status.branch ?? "?") files=\(files.sorted())".write(to: out, atomically: true, encoding: .utf8)
                } catch { try? "FAIL \(error.localizedDescription)".write(to: out, atomically: true, encoding: .utf8) }
            }
        }
        // Dev/test hook: TEXPAD_OPEN_SAMPLE=Thesis opens a bundled sample on launch.
        if let name = ProcessInfo.processInfo.environment["TEXPAD_OPEN_SAMPLE"] {
            Task { @MainActor in
                self.openSample(name)
                if ProcessInfo.processInfo.environment["TEXPAD_BUILD"] != nil { self.project?.build() }
                if ProcessInfo.processInfo.environment["TEXPAD_GIT_DEMO"] != nil, let p = self.project {
                    // First commit, then a modified file, a new file and a staged change, to show the Source Control UI.
                    UserDefaults.standard.set("Demo User", forKey: "gitName"); UserDefaults.standard.set("demo@users.noreply.github.com", forKey: "gitEmail")
                    await p.git.initialize(); await p.git.stageAll(); p.git.commitMessage = "Initial commit"; await p.git.commit()
                    let main = p.root.appendingPathComponent("main.tex")
                    if let t = try? String(contentsOf: main, encoding: .utf8) { try? (t + "\n% a local edit\n").write(to: main, atomically: true, encoding: .utf8) }
                    try? "scratch notes".write(to: p.root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
                    try? "more".write(to: p.root.appendingPathComponent("chapters/intro.tex"), atomically: true, encoding: .utf8)
                    await p.git.refresh()
                    if let c = p.git.status.changes.first(where: { $0.path == "chapters/intro.tex" }) { await p.git.stage(c) }
                    await p.git.setRemote("https://github.com/example/thesis.git")
                }
            }
        }
        #endif
    }

    // MARK: open / close

    func open(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            openError = "Folder not found: \(url.lastPathComponent)"; if accessing { url.stopAccessingSecurityScopedResource() }; return
        }
        closeProject()
        if accessing { scopedURL = url }
        project = Project(root: url, engine: engine)
        if let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            addRecent(RecentProject(name: url.lastPathComponent, bookmark: bm, lastOpened: Date()))
        }
    }

    func open(recent: RecentProject) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            openError = "Can't reopen \(recent.name). Open it again from Files."
            recents.removeAll { $0.id == recent.id }; saveRecents(); return
        }
        open(url: url)
    }

    func closeProject() {
        project?.saveAll()
        project = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }

    /// Clones an https repository and opens it. `parent` nil = TexPad's own Documents folder (visible in Files).
    func cloneRepository(urlString: String, username: String, token: String, parent: URL?, cancel: GitCancelToken,
                         progress: @escaping (Double, String) -> Void) async throws {
        let url = try GitURL.validate(urlString)
        guard let host = url.host else { throw GitError.message("Missing host in URL.") }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { GitCredentialStore.save(GitCredential(username: username.isEmpty ? "git" : username, token: t), host: host) }

        let base = parent ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scoped = parent?.startAccessingSecurityScopedResource() ?? false
        var keepScope = false
        defer { if scoped && !keepScope { parent?.stopAccessingSecurityScopedResource() } }

        var name = GitURL.repositoryName(url), dest = base.appendingPathComponent(name), n = 2
        while FileManager.default.fileExists(atPath: dest.path) { name = GitURL.repositoryName(url) + " \(n)"; dest = base.appendingPathComponent(name); n += 1 }

        do {
            _ = try await GitRepository.perform { try GitRepository.clone(from: urlString, into: dest, cancel: cancel, progress: progress) }
        } catch {
            try? FileManager.default.removeItem(at: dest)            // don't leave a half-cloned folder behind
            if cancel.cancelled { throw GitError.message("Clone cancelled.") }
            throw error
        }
        closeProject()
        if scoped { scopedURL = parent; keepScope = true }
        project = Project(root: dest, engine: engine)
        if let bm = try? dest.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            addRecent(RecentProject(name: dest.lastPathComponent, bookmark: bm, lastOpened: Date()))
        }
    }

    /// Copies a bundled sample project into Documents and opens it.
    func openSample(_ name: String) {
        guard ["Thesis", "Manuscript", "XeLaTeX", "Broken"].contains(name) else { return }
        guard let src = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Samples") else {
            openError = "Sample \(name) not found in the app bundle"; return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dst = docs.appendingPathComponent(name)
        #if DEBUG
        if ProcessInfo.processInfo.environment["TEXPAD_RESET_SAMPLE"] != nil { try? FileManager.default.removeItem(at: dst) }
        #endif
        if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: src, to: dst) }
        open(url: dst)
    }

    // MARK: recents

    private func addRecent(_ r: RecentProject) {
        recents.removeAll { $0.name == r.name }
        recents.insert(r, at: 0)
        recents = Array(recents.prefix(10))
        saveRecents()
    }
    private func loadRecents() {
        if let d = UserDefaults.standard.data(forKey: recentsKey), let r = try? JSONDecoder().decode([RecentProject].self, from: d) { recents = r }
    }
    private func saveRecents() {
        if let d = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(d, forKey: recentsKey) }
    }
}
