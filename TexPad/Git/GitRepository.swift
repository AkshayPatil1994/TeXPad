// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

enum GitError: Error, LocalizedError, Equatable {
    case lib(Int32, String)
    case message(String)
    var errorDescription: String? {
        switch self { case .lib(_, let m): return m; case .message(let m): return m }
    }
}

enum GitChangeKind: String { case added, modified, deleted, renamed, typeChange, untracked, conflicted
    var mark: String {
        switch self { case .added: "A"; case .modified: "M"; case .deleted: "D"; case .renamed: "R"; case .typeChange: "T"; case .untracked: "U"; case .conflicted: "!" }
    }
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var staged: GitChangeKind?
    var unstaged: GitChangeKind?
}

struct GitStatus: Equatable {
    var branch: String?
    var detached = false
    var upstream: String?
    var ahead = 0
    var behind = 0
    var hasRemote = false
    var changes: [GitFileChange] = []
}

struct GitBranchInfo: Identifiable, Equatable {
    var id: String { (isRemote ? "remote/" : "local/") + name }
    var name: String
    var isCurrent: Bool
    var isRemote: Bool
}

enum PullResult: Equatable { case upToDate, fastForwarded }

/// Remote URLs: https only, no credentials embedded (tokens live in the Keychain, never in `.git/config`).
enum GitURL {
    static func validate(_ raw: String) throws -> URL {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else {
            throw GitError.message("That doesn't look like a repository URL. Use https://host/owner/repo.git")
        }
        guard scheme == "https" else { throw GitError.message("Only https:// remotes are supported. SSH (git@…) URLs aren't available yet.") }
        guard u.user == nil, u.password == nil else {
            throw GitError.message("Remove the username/password from the URL. Save an access token for the host instead.")
        }
        return u
    }

    /// "https://github.com/owner/My-Repo.git" -> "My-Repo"
    static func repositoryName(_ url: URL) -> String {
        var n = url.lastPathComponent
        if n.hasSuffix(".git") { n.removeLast(4) }
        return PathSafety.isSafeName(n) ? n : "repository"
    }
}

private final class ProgressBox {
    var handler: (Double, String) -> Void
    var rejection: String?
    var cancelled = false
    init(_ h: @escaping (Double, String) -> Void) { handler = h }
}

/// Thin Swift wrapper over libgit2 for one repository. Not thread-safe: use it from `GitRepository.queue` (see `perform`).
final class GitRepository {
    static let queue = DispatchQueue(label: "dev.texpad.git", qos: .userInitiated)
    private static let bootstrapped: Bool = { texpad_git_init() >= 0 && GitHTTP.install() }()
    static func bootstrap() throws {
        guard bootstrapped else { throw GitError.message("Couldn't initialise the git library.") }
    }

    private var repo: OpaquePointer?
    let root: URL

    private init(repo: OpaquePointer, root: URL) { self.repo = repo; self.root = root }
    deinit { if let repo { git_repository_free(repo) } }

    /// Runs git work off the main thread, serialised.
    static func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) } }
        }
    }

    // MARK: errors / helpers

    @discardableResult
    private static func check(_ rc: Int32) throws -> Int32 {
        if rc < 0 {
            let msg = git_error_last().map { String(cString: $0.pointee.message) } ?? "git error \(rc)"
            throw GitError.lib(rc, msg)
        }
        return rc
    }

    private func withStrarray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<git_strarray>) throws -> T) rethrows -> T {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { for p in cStrings { free(p) } }
        return try cStrings.withUnsafeMutableBufferPointer { buf in
            var arr = git_strarray(strings: buf.baseAddress, count: buf.count)
            return try body(&arr)
        }
    }

    // MARK: open / create

    static func isRepository(at url: URL) -> Bool {
        guard (try? bootstrap()) != nil else { return false }
        var r: OpaquePointer?
        let rc = git_repository_open_ext(&r, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        if rc == 0, let r { git_repository_free(r); return true }
        return false
    }

    static func open(at url: URL) throws -> GitRepository {
        try bootstrap()
        var r: OpaquePointer?
        try check(git_repository_open_ext(&r, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        return GitRepository(repo: r!, root: url)
    }

    /// `git init` with `main` as the initial branch.
    static func initialize(at url: URL) throws -> GitRepository {
        try bootstrap()
        var opts = git_repository_init_options()
        try check(git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        var r: OpaquePointer?
        try "main".withCString { head in
            opts.initial_head = head
            try check(git_repository_init_ext(&r, url.path, &opts))
        }
        let repo = GitRepository(repo: r!, root: url)
        try repo.setBool("core.symlinks", false)
        return repo
    }

    /// A bare repository (used as a stand-in "server" in tests).
    static func initializeBare(at url: URL) throws {
        try bootstrap()
        var opts = git_repository_init_options()
        try check(git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        opts.flags = GIT_REPOSITORY_INIT_BARE.rawValue | GIT_REPOSITORY_INIT_MKPATH.rawValue
        var r: OpaquePointer?
        try "main".withCString { head in
            opts.initial_head = head
            try check(git_repository_init_ext(&r, url.path, &opts))
        }
        git_repository_free(r)
    }

    private func setBool(_ key: String, _ value: Bool) throws {
        var cfg: OpaquePointer?
        try Self.check(git_repository_config(&cfg, repo))
        defer { git_config_free(cfg) }
        try Self.check(git_config_set_bool(cfg, key, value ? 1 : 0))
    }

    /// Clones into `destination` (which must not exist yet). `core.symlinks=false` is set before checkout so a hostile
    /// repository can't plant symlinks in the working tree.
    static func clone(from rawURL: String, into destination: URL, progress: @escaping (Double, String) -> Void) throws -> GitRepository {
        let url = try GitURL.validate(rawURL)
        return try cloneUnchecked(urlString: url.absoluteString, into: destination, progress: progress)
    }

    /// Clone without the https-only rule — for tests that clone from local `file://` repositories.
    static func cloneUnchecked(urlString: String, into destination: URL, progress: @escaping (Double, String) -> Void) throws -> GitRepository {
        try bootstrap()
        var opts = git_clone_options()
        try check(git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        let box = ProgressBox(progress)
        opts.fetch_opts.callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
        opts.fetch_opts.callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let b = Unmanaged<ProgressBox>.fromOpaque(payload).takeUnretainedValue()
            let s = stats.pointee
            let total = max(1, Double(s.total_objects))
            b.handler(Double(s.received_objects) / total * 0.9 + Double(s.indexed_objects) / total * 0.1,
                      "Receiving objects \(s.received_objects)/\(s.total_objects)")
            return b.cancelled ? -1 : 0
        }
        opts.repository_cb = { out, path, bare, _ in
            // "main" is only used for empty remotes; otherwise checkout follows the remote's default branch.
            var o = git_repository_init_options()
            guard git_repository_init_options_init(&o, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)) == 0 else { return -1 }
            o.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | (bare != 0 ? GIT_REPOSITORY_INIT_BARE.rawValue : 0)
            var rc: Int32 = -1
            "main".withCString { head in o.initial_head = head; rc = git_repository_init_ext(out, path, &o) }
            guard rc == 0, let out else { return rc }
            var cfg: OpaquePointer?
            if git_repository_config(&cfg, out.pointee) == 0 {
                git_config_set_bool(cfg, "core.symlinks", 0)
                git_config_set_string(cfg, "init.defaultbranch", "main")   // libgit2's "empty repository" check reads this
                git_config_free(cfg)
            }
            return 0
        }
        var r: OpaquePointer?
        try withExtendedLifetime(box) { try check(git_clone(&r, urlString, destination.path, &opts)) }
        return GitRepository(repo: r!, root: destination)
    }

    // MARK: status

    func status() throws -> GitStatus {
        var st = GitStatus()
        // branch + upstream
        var head: OpaquePointer?
        let rc = git_repository_head(&head, repo)
        if rc == 0, let head {
            defer { git_reference_free(head) }
            st.detached = git_repository_head_detached(repo) == 1
            var cname: UnsafePointer<CChar>?
            if git_branch_name(&cname, head) == 0, let cname { st.branch = String(cString: cname) }
            if st.detached { st.branch = nil }
            var up: OpaquePointer?
            if git_branch_upstream(&up, head) == 0, let up {
                defer { git_reference_free(up) }
                var un: UnsafePointer<CChar>?
                if git_branch_name(&un, up) == 0, let un { st.upstream = String(cString: un) }
                if let l = git_reference_target(head), let u = git_reference_target(up) {
                    var a = 0, b = 0
                    if git_graph_ahead_behind(&a, &b, repo, l, u) == 0 { st.ahead = a; st.behind = b }
                }
            }
        } else if git_repository_head_unborn(repo) == 1 {
            var sym: OpaquePointer?
            if git_reference_lookup(&sym, repo, "HEAD") == 0, let sym {
                defer { git_reference_free(sym) }
                if let t = git_reference_symbolic_target(sym) { st.branch = String(cString: t).replacingOccurrences(of: "refs/heads/", with: "") }
            }
        }
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, "origin") == 0 { st.hasRemote = true; git_remote_free(remote) }

        // file changes
        var opts = git_status_options()
        try Self.check(git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        var list: OpaquePointer?
        try Self.check(git_status_list_new(&list, repo, &opts))
        defer { git_status_list_free(list) }
        for i in 0..<git_status_list_entrycount(list) {
            guard let e = git_status_byindex(list, i)?.pointee else { continue }
            let f = e.status.rawValue
            var path: String?
            if let d = e.head_to_index { path = String(cString: (d.pointee.new_file.path ?? d.pointee.old_file.path)) }
            if path == nil, let d = e.index_to_workdir { path = String(cString: (d.pointee.new_file.path ?? d.pointee.old_file.path)) }
            guard let p = path, PathSafety.isSafeRelative(p) || p.hasSuffix("/") == false && PathSafety.isSafeRelative(p) else { continue }
            func has(_ x: git_status_t) -> Bool { f & x.rawValue != 0 }
            var change = GitFileChange(path: p)
            if has(GIT_STATUS_CONFLICTED) { change.unstaged = .conflicted }
            if has(GIT_STATUS_INDEX_NEW) { change.staged = .added }
            else if has(GIT_STATUS_INDEX_MODIFIED) { change.staged = .modified }
            else if has(GIT_STATUS_INDEX_DELETED) { change.staged = .deleted }
            else if has(GIT_STATUS_INDEX_RENAMED) { change.staged = .renamed }
            else if has(GIT_STATUS_INDEX_TYPECHANGE) { change.staged = .typeChange }
            if has(GIT_STATUS_WT_NEW) { change.unstaged = .untracked }
            else if has(GIT_STATUS_WT_MODIFIED) { change.unstaged = .modified }
            else if has(GIT_STATUS_WT_DELETED) { change.unstaged = .deleted }
            else if has(GIT_STATUS_WT_RENAMED) { change.unstaged = .renamed }
            else if has(GIT_STATUS_WT_TYPECHANGE) { change.unstaged = .typeChange }
            if change.staged != nil || change.unstaged != nil { st.changes.append(change) }
        }
        return st
    }

    // MARK: staging / committing

    func stage(_ paths: [String]) throws {
        var idx: OpaquePointer?
        try Self.check(git_repository_index(&idx, repo))
        defer { git_index_free(idx) }
        for p in paths {
            guard PathSafety.isSafeRelative(p) else { throw GitError.message("Invalid path: \(p)") }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) { try Self.check(git_index_add_bypath(idx, p)) }
            else { _ = git_index_remove_bypath(idx, p) }     // deleted file
        }
        try Self.check(git_index_write(idx))
    }

    func stageAll() throws {
        var idx: OpaquePointer?
        try Self.check(git_repository_index(&idx, repo))
        defer { git_index_free(idx) }
        try Self.check(git_index_add_all(idx, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
        try Self.check(git_index_update_all(idx, nil, nil, nil))
        try Self.check(git_index_write(idx))
    }

    func unstage(_ paths: [String]) throws {
        for p in paths where !PathSafety.isSafeRelative(p) { throw GitError.message("Invalid path: \(p)") }
        if git_repository_head_unborn(repo) == 1 {
            var idx: OpaquePointer?
            try Self.check(git_repository_index(&idx, repo))
            defer { git_index_free(idx) }
            for p in paths { _ = git_index_remove_bypath(idx, p) }
            try Self.check(git_index_write(idx))
            return
        }
        var headObj: OpaquePointer?
        try Self.check(git_revparse_single(&headObj, repo, "HEAD"))
        defer { git_object_free(headObj) }
        try withStrarray(paths) { arr in try Self.check(git_reset_default(repo, headObj, arr)) }
    }

    /// Restores tracked files to their committed state (staged and unstaged edits are lost).
    func discardTracked(_ paths: [String]) throws {
        for p in paths where !PathSafety.isSafeRelative(p) { throw GitError.message("Invalid path: \(p)") }
        var opts = git_checkout_options()
        try Self.check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try withStrarray(paths) { arr in
            opts.paths = arr.pointee
            try Self.check(git_checkout_head(repo, &opts))
        }
    }

    func commit(message: String, name: String, email: String) throws -> String {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { throw GitError.message("Enter a commit message.") }
        guard msg.utf8.count <= 20_000 else { throw GitError.message("The commit message is too long.") }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, email.contains("@") else {
            throw GitError.message("Set your name and email for commits first (Settings → Git).")
        }
        var sig: UnsafeMutablePointer<git_signature>?
        try Self.check(git_signature_now(&sig, name, email))
        defer { git_signature_free(sig) }
        var idx: OpaquePointer?
        try Self.check(git_repository_index(&idx, repo))
        defer { git_index_free(idx) }
        var treeOid = git_oid()
        try Self.check(git_index_write_tree(&treeOid, idx))
        var tree: OpaquePointer?
        try Self.check(git_tree_lookup(&tree, repo, &treeOid))
        defer { git_tree_free(tree) }

        var parent: OpaquePointer?
        if git_repository_head_unborn(repo) == 0 {
            var headRef: OpaquePointer?
            try Self.check(git_repository_head(&headRef, repo))
            defer { git_reference_free(headRef) }
            try Self.check(git_commit_lookup(&parent, repo, git_reference_target(headRef)))
            if git_oid_equal(git_commit_tree_id(parent), &treeOid) != 0 { git_commit_free(parent); throw GitError.message("Nothing to commit — stage some changes first.") }
        }
        defer { if let parent { git_commit_free(parent) } }
        var newOid = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        try parents.withUnsafeMutableBufferPointer { buf in
            try Self.check(git_commit_create(&newOid, repo, "HEAD", sig, sig, nil, msg, tree, buf.count, buf.baseAddress))
        }
        var short = [CChar](repeating: 0, count: 9)
        git_oid_tostr(&short, short.count, &newOid)
        return String(cString: short)
    }

    // MARK: branches

    func branches() throws -> [GitBranchInfo] {
        var it: OpaquePointer?
        try Self.check(git_branch_iterator_new(&it, repo, GIT_BRANCH_ALL))
        defer { git_branch_iterator_free(it) }
        var out: [GitBranchInfo] = []
        while true {
            var ref: OpaquePointer?
            var type = GIT_BRANCH_LOCAL
            let rc = git_branch_next(&ref, &type, it)
            if rc == GIT_ITEROVER.rawValue { break }
            try Self.check(rc)
            defer { git_reference_free(ref) }
            var cname: UnsafePointer<CChar>?
            guard git_branch_name(&cname, ref) == 0, let cname else { continue }
            let name = String(cString: cname)
            if name.hasSuffix("/HEAD") { continue }
            out.append(GitBranchInfo(name: name, isCurrent: git_branch_is_head(ref) == 1, isRemote: type == GIT_BRANCH_REMOTE))
        }
        return out.sorted { ($0.isRemote ? 1 : 0, $0.name) < ($1.isRemote ? 1 : 0, $1.name) }
    }

    private static func validBranchName(_ n: String) -> Bool {
        var valid: Int32 = 0
        return git_branch_name_is_valid(&valid, n) == 0 && valid == 1
    }

    func createBranch(_ name: String) throws {
        guard Self.validBranchName(name) else { throw GitError.message("“\(name)” isn't a valid branch name.") }
        guard git_repository_head_unborn(repo) == 0 else { throw GitError.message("Make a first commit before creating branches.") }
        var obj: OpaquePointer?
        try Self.check(git_revparse_single(&obj, repo, "HEAD"))
        defer { git_object_free(obj) }
        var commit: OpaquePointer?
        try Self.check(git_commit_lookup(&commit, repo, git_object_id(obj)))
        defer { git_commit_free(commit) }
        var ref: OpaquePointer?
        try Self.check(git_branch_create(&ref, repo, name, commit, 0))
        git_reference_free(ref)
        try checkout(branch: name)
    }

    /// Switches branches. A remote-only branch ("origin/x" or "x") gets a local tracking branch first.
    func checkout(branch name: String) throws {
        guard Self.validBranchName(name) else { throw GitError.message("Invalid branch name.") }
        var ref: OpaquePointer?
        if git_reference_lookup(&ref, repo, "refs/heads/" + name) != 0 {
            var remoteRef: OpaquePointer?
            let short = name.hasPrefix("origin/") ? String(name.dropFirst(7)) : name
            guard git_reference_lookup(&remoteRef, repo, "refs/remotes/origin/" + short) == 0, let remoteRef else {
                throw GitError.message("No branch named “\(name)”.")
            }
            defer { git_reference_free(remoteRef) }
            var commit: OpaquePointer?
            try Self.check(git_commit_lookup(&commit, repo, git_reference_target(remoteRef)))
            defer { git_commit_free(commit) }
            try Self.check(git_branch_create(&ref, repo, short, commit, 0))
            _ = git_branch_set_upstream(ref, "origin/" + short)
            git_reference_free(ref); ref = nil
            return try checkout(branch: short)
        }
        defer { git_reference_free(ref) }
        var obj: OpaquePointer?
        try Self.check(git_reference_peel(&obj, ref, GIT_OBJECT_COMMIT))
        defer { git_object_free(obj) }
        var opts = git_checkout_options()
        try Self.check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        do { try Self.check(git_checkout_tree(repo, obj, &opts)) }
        catch { throw GitError.message("Couldn't switch branches: commit or discard your local changes first.\n\(error.localizedDescription)") }
        try Self.check(git_repository_set_head(repo, "refs/heads/" + name))
    }

    // MARK: remotes

    func remoteURL() -> String? {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    func setRemote(url raw: String) throws {
        let url = try GitURL.validate(raw)
        if remoteURL() != nil { try Self.check(git_remote_set_url(repo, "origin", url.absoluteString)) }
        else {
            var r: OpaquePointer?
            try Self.check(git_remote_create(&r, repo, "origin", url.absoluteString))
            git_remote_free(r)
        }
    }

    func fetch(progress: @escaping (Double, String) -> Void = { _, _ in }) throws {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0, let remote else { throw GitError.message("This repository has no remote named “origin”.") }
        defer { git_remote_free(remote) }
        var opts = git_fetch_options()
        try Self.check(git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        let box = ProgressBox(progress)
        opts.callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
        opts.callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let s = stats.pointee
            Unmanaged<ProgressBox>.fromOpaque(payload).takeUnretainedValue().handler(
                Double(s.received_objects) / max(1, Double(s.total_objects)), "Receiving objects \(s.received_objects)/\(s.total_objects)")
            return 0
        }
        try withExtendedLifetime(box) { try Self.check(git_remote_fetch(remote, nil, &opts, nil)) }
    }

    /// fetch + fast-forward only. Diverged histories are refused with an explanation (merging isn't supported yet).
    func pull(progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> PullResult {
        try fetch(progress: progress)
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0, let head else { throw GitError.message("Nothing to pull into yet — make a first commit.") }
        defer { git_reference_free(head) }
        var cname: UnsafePointer<CChar>?
        try Self.check(git_branch_name(&cname, head))
        let branch = String(cString: cname!)
        var up: OpaquePointer?
        if git_branch_upstream(&up, head) != 0 {
            guard git_reference_lookup(&up, repo, "refs/remotes/origin/" + branch) == 0 else { throw GitError.message("“\(branch)” has no upstream branch on the remote.") }
        }
        defer { git_reference_free(up) }
        var annotated: OpaquePointer?
        try Self.check(git_annotated_commit_from_ref(&annotated, repo, up))
        defer { git_annotated_commit_free(annotated) }
        var analysis = GIT_MERGE_ANALYSIS_NONE
        var pref = GIT_MERGE_PREFERENCE_NONE
        var heads: [OpaquePointer?] = [annotated]
        try heads.withUnsafeMutableBufferPointer { buf in
            try Self.check(git_merge_analysis(&analysis, &pref, repo, buf.baseAddress, 1))
        }
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 { return .upToDate }
        guard analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 else {
            throw GitError.message("Your branch and the remote have diverged, so a fast-forward isn't possible. Merging isn't supported in TexPad yet — push your work to a new branch or rebase elsewhere.")
        }
        // Check out the new tree first (the baseline is still the old HEAD, so local edits are detected correctly), then move the branch.
        var target: OpaquePointer?
        try Self.check(git_object_lookup(&target, repo, git_reference_target(up), GIT_OBJECT_COMMIT))
        defer { git_object_free(target) }
        var opts = git_checkout_options()
        try Self.check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        do { try Self.check(git_checkout_tree(repo, target, &opts)) }
        catch { throw GitError.message("Fetched, but couldn't update files: commit or discard your local changes first.\n\(error.localizedDescription)") }
        var newRef: OpaquePointer?
        try Self.check(git_reference_set_target(&newRef, head, git_reference_target(up), "pull: fast-forward"))
        git_reference_free(newRef)
        return .fastForwarded
    }

    func push(progress: @escaping (Double, String) -> Void = { _, _ in }) throws {
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0, let head else { throw GitError.message("Nothing to push yet — make a first commit.") }
        defer { git_reference_free(head) }
        var cname: UnsafePointer<CChar>?
        try Self.check(git_branch_name(&cname, head))
        let branch = String(cString: cname!)
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0, let remote else { throw GitError.message("This repository has no remote named “origin”. Add one in Source Control.") }
        defer { git_remote_free(remote) }

        var opts = git_push_options()
        try Self.check(git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        let box = ProgressBox(progress)
        opts.callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
        opts.callbacks.push_update_reference = { _, status, payload in
            if let status, let payload { Unmanaged<ProgressBox>.fromOpaque(payload).takeUnretainedValue().rejection = String(cString: status) }
            return 0
        }
        let refspec = "refs/heads/\(branch):refs/heads/\(branch)"
        try withExtendedLifetime(box) {
            try withStrarray([refspec]) { arr in try Self.check(git_remote_push(remote, arr, &opts)) }
        }
        if let why = box.rejection { throw GitError.message("The server rejected the push: \(why)") }
        var up: OpaquePointer?
        if git_branch_upstream(&up, head) != 0 { _ = git_branch_set_upstream(head, "origin/" + branch) } else { git_reference_free(up) }
    }
}
