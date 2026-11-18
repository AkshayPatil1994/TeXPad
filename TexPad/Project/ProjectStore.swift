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
        // Dev/test hook: TEXPAD_OPEN_SAMPLE=Thesis opens a bundled sample on launch.
        if let name = ProcessInfo.processInfo.environment["TEXPAD_OPEN_SAMPLE"] {
            Task { @MainActor in
                self.openSample(name)
                if ProcessInfo.processInfo.environment["TEXPAD_BUILD"] != nil { self.project?.build() }
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
