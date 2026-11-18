// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import SwiftUI

extension GitRepository: @unchecked Sendable {}

/// Cooperative cancel flag shared with a running clone/fetch.
final class GitCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Source-control state for one project folder. All libgit2 work runs on `GitRepository.queue`.
@MainActor
final class GitModel: ObservableObject {
    let root: URL

    @Published private(set) var isRepo = false
    @Published private(set) var status = GitStatus()
    @Published private(set) var branches: [GitBranchInfo] = []
    @Published private(set) var remoteURL: String?
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double?
    @Published var commitMessage = ""
    @Published var lastError: String?
    /// Set when a remote operation failed for lack of a token; the UI asks for one for this host.
    @Published var needsTokenForHost: String?

    /// Called after operations that change files on disk (pull, checkout, discard).
    var onFilesChanged: () -> Void = {}
    private var repo: GitRepository?
    private var refreshWork: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        isRepo = GitRepository.isRepository(at: root)
        if isRepo { Task { await refresh() } }
    }

    var changeCount: Int { status.changes.count }
    var stagedChanges: [GitFileChange] { status.changes.filter { $0.staged != nil } }
    var unstagedChanges: [GitFileChange] { status.changes.filter { $0.unstaged != nil } }
    var remoteHost: String? { remoteURL.flatMap { URL(string: $0)?.host } }

    var identity: (name: String, email: String) {
        (UserDefaults.standard.string(forKey: "gitName") ?? "", UserDefaults.standard.string(forKey: "gitEmail") ?? "")
    }

    // MARK: refresh

    func refreshSoon() {
        guard isRepo else { return }
        refreshWork?.cancel()
        refreshWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { await self?.refresh() }
        }
    }

    func refresh() async {
        guard isRepo else { return }
        do {
            let url = root
            let existing = repo
            let result = try await GitRepository.perform {
                let r = try existing ?? GitRepository.open(at: url)
                return (r, try r.status(), try r.branches(), r.remoteURL())
            }
            repo = result.0; status = result.1; branches = result.2; remoteURL = result.3
        } catch { lastError = error.localizedDescription }
    }

    // MARK: running operations

    private func run<T>(_ label: String, showProgress: Bool = false, refreshAfter: Bool = true, filesChange: Bool = false,
                        _ work: @escaping (GitRepository, @escaping (Double, String) -> Void) throws -> T) async -> T? {
        guard busy == nil else { return nil }
        busy = label; lastError = nil; progress = showProgress ? 0 : nil
        defer { busy = nil; progress = nil }
        do {
            let url = root
            let report: @Sendable (Double, String) -> Void = { [weak self] p, text in
                Task { @MainActor in self?.progress = p; if !text.isEmpty { self?.busy = label + " " + text } }
            }
            if repo == nil { repo = try await GitRepository.perform { try GitRepository.open(at: url) } }
            let r = repo!
            let value = try await GitRepository.perform { try work(r, report) }
            if refreshAfter { await refresh() }
            if filesChange { onFilesChanged() }
            return value
        } catch {
            lastError = error.localizedDescription
            if let host = remoteHost, lastError?.contains("Authentication failed") == true || lastError?.contains("not found") == true,
               GitCredentialStore.load(host: host) == nil { needsTokenForHost = host }
            return nil
        }
    }

    // MARK: repository setup

    func initialize() async {
        let url = root
        do {
            _ = try await GitRepository.perform { try GitRepository.initialize(at: url) }
            Self.writeDefaultGitignoreIfMissing(at: url)
            isRepo = true
            repo = try await GitRepository.perform { try GitRepository.open(at: url) }
            await refresh()
            onFilesChanged()
        } catch { lastError = error.localizedDescription }
    }

    static let defaultGitignore = """
    # LaTeX build output
    build/
    *.aux
    *.log
    *.out
    *.toc
    *.lof
    *.lot
    *.bbl
    *.blg
    *.synctex.gz
    *.fdb_latexmk
    *.fls
    .DS_Store
    """

    static func writeDefaultGitignoreIfMissing(at root: URL) {
        let u = root.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: u.path) { try? (defaultGitignore + "\n").write(to: u, atomically: true, encoding: .utf8) }
    }

    func setRemote(_ url: String) async { _ = await run("Setting remote") { r, _ in try r.setRemote(url: url) } }

    // MARK: staging / commit

    func stage(_ change: GitFileChange) async { _ = await run("Staging") { r, _ in try r.stage([change.path]) } }
    func unstage(_ change: GitFileChange) async { _ = await run("Unstaging") { r, _ in try r.unstage([change.path]) } }
    func stageAll() async { _ = await run("Staging") { r, _ in try r.stageAll() } }
    func unstageAll() async { let paths = stagedChanges.map(\.path); _ = await run("Unstaging") { r, _ in try r.unstage(paths) } }

    /// Throws away local changes to one file (tracked: restore from HEAD; untracked: delete).
    func discard(_ change: GitFileChange) async {
        if change.unstaged == .untracked && change.staged == nil {
            guard let u = PathSafety.resolve(change.path, in: root) else { lastError = "Invalid path"; return }
            do { try FileManager.default.removeItem(at: u) } catch { lastError = error.localizedDescription }
            await refresh(); onFilesChanged()
        } else {
            _ = await run("Discarding", filesChange: true) { r, _ in try r.discardTracked([change.path]) }
        }
    }

    func commit() async {
        let (name, email) = identity
        let msg = commitMessage
        if let oid: String = await run("Committing", { r, _ in try r.commit(message: msg, name: name, email: email) }) {
            commitMessage = ""
            lastOID = oid
        }
    }
    @Published private(set) var lastOID: String?

    // MARK: branches

    func createBranch(_ name: String) async { _ = await run("Creating branch", filesChange: true) { r, _ in try r.createBranch(name) } }
    func checkout(_ name: String) async { _ = await run("Switching branch", filesChange: true) { r, _ in try r.checkout(branch: name) } }

    // MARK: sync

    func fetch() async { _ = await run("Fetching", showProgress: true) { r, p in try r.fetch(progress: p) } }

    func pull() async -> PullResult? {
        await run("Pulling", showProgress: true, filesChange: true) { r, p in try r.pull(progress: p) }
    }

    func push() async { _ = await run("Pushing", showProgress: true) { r, p in try r.push(progress: p) } }
}
