// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
@testable import TexPad

final class GitTests: XCTestCase {
    private var tmp: URL!
    private let me = (name: "Test User", email: "test@example.com")

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("texpad-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ name: String, _ text: String, in repo: GitRepository) throws {
        let u = repo.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    // MARK: init / status / commit

    func testInitStatusStageCommit() throws {
        let repo = try GitRepository.initialize(at: tmp.appendingPathComponent("work"))
        XCTAssertTrue(GitRepository.isRepository(at: repo.root))
        XCTAssertFalse(GitRepository.isRepository(at: tmp))
        try write("main.tex", "hello", in: repo)
        try write("chapters/a.tex", "a", in: repo)

        var st = try repo.status()
        XCTAssertEqual(st.branch, "main")
        XCTAssertEqual(Set(st.changes.map(\.path)), ["main.tex", "chapters/a.tex"])
        XCTAssertTrue(st.changes.allSatisfy { $0.unstaged == .untracked && $0.staged == nil })

        try repo.stage(["main.tex"])
        st = try repo.status()
        XCTAssertEqual(st.changes.first { $0.path == "main.tex" }?.staged, .added)

        XCTAssertThrowsError(try repo.commit(message: "  ", name: me.name, email: me.email))
        XCTAssertThrowsError(try repo.commit(message: "x", name: "", email: me.email))
        let oid = try repo.commit(message: "First", name: me.name, email: me.email)
        XCTAssertEqual(oid.count, 8)

        st = try repo.status()
        XCTAssertEqual(st.changes.map(\.path), ["chapters/a.tex"])           // only the untracked file remains
        XCTAssertThrowsError(try repo.commit(message: "again", name: me.name, email: me.email)) { e in
            XCTAssertTrue("\(e)".contains("Nothing to commit") || e.localizedDescription.contains("Nothing to commit"))
        }
    }

    func testModifyStageUnstageDiscard() throws {
        let repo = try GitRepository.initialize(at: tmp.appendingPathComponent("work"))
        try write("a.tex", "v1", in: repo)
        try repo.stageAll()
        _ = try repo.commit(message: "v1", name: me.name, email: me.email)

        try write("a.tex", "v2", in: repo)
        XCTAssertEqual(try repo.status().changes.first?.unstaged, .modified)
        try repo.stage(["a.tex"])
        XCTAssertEqual(try repo.status().changes.first?.staged, .modified)
        try repo.unstage(["a.tex"])
        let after = try repo.status().changes.first
        XCTAssertNil(after?.staged); XCTAssertEqual(after?.unstaged, .modified)

        try repo.discardTracked(["a.tex"])
        XCTAssertEqual(try String(contentsOf: repo.root.appendingPathComponent("a.tex")), "v1")
        XCTAssertTrue(try repo.status().changes.isEmpty)

        // deletions are staged as deletions
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("a.tex"))
        XCTAssertEqual(try repo.status().changes.first?.unstaged, .deleted)
        try repo.stage(["a.tex"])
        XCTAssertEqual(try repo.status().changes.first?.staged, .deleted)
    }

    func testPathsAreValidated() throws {
        let repo = try GitRepository.initialize(at: tmp.appendingPathComponent("work"))
        XCTAssertThrowsError(try repo.stage(["../outside"]))
        XCTAssertThrowsError(try repo.unstage(["/etc/passwd"]))
        XCTAssertThrowsError(try repo.discardTracked(["a/../../b"]))
    }

    func testBranches() throws {
        let repo = try GitRepository.initialize(at: tmp.appendingPathComponent("work"))
        XCTAssertThrowsError(try repo.createBranch("early"))                  // no commits yet
        try write("a.tex", "1", in: repo)
        try repo.stageAll(); _ = try repo.commit(message: "c1", name: me.name, email: me.email)

        try repo.createBranch("feature")
        XCTAssertEqual(try repo.status().branch, "feature")
        try write("b.tex", "2", in: repo)
        try repo.stageAll(); _ = try repo.commit(message: "c2", name: me.name, email: me.email)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("b.tex").path))

        try repo.checkout(branch: "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("b.tex").path))
        let names = try repo.branches().map(\.name)
        XCTAssertEqual(Set(names), ["main", "feature"])
        XCTAssertEqual(try repo.branches().first { $0.isCurrent }?.name, "main")

        XCTAssertThrowsError(try repo.createBranch("bad name with spaces"))
        XCTAssertThrowsError(try repo.createBranch("a..b"))
        XCTAssertThrowsError(try repo.checkout(branch: "nope"))
    }

    // MARK: clone / push / pull against a local bare repo

    func testCloneCommitPushPullFastForwardAndDivergence() throws {
        let bare = tmp.appendingPathComponent("server.git")
        try GitRepository.initializeBare(at: bare)
        let remoteURL = "file://" + bare.path

        // seed the server through a first clone
        let w1 = try GitRepository.cloneUnchecked(urlString: remoteURL, into: tmp.appendingPathComponent("w1"), progress: { _, _ in })
        try write("main.tex", "one", in: w1)
        try w1.stageAll(); _ = try w1.commit(message: "one", name: me.name, email: me.email)
        try w1.push()

        let w2 = try GitRepository.cloneUnchecked(urlString: remoteURL, into: tmp.appendingPathComponent("w2"), progress: { _, _ in })
        XCTAssertEqual(try String(contentsOf: w2.root.appendingPathComponent("main.tex")), "one")
        XCTAssertEqual(try w2.status().branch, "main")
        XCTAssertEqual(try w2.pull(), .upToDate)

        // w1 pushes more; w2 fast-forwards
        try write("main.tex", "two", in: w1)
        try w1.stageAll(); _ = try w1.commit(message: "two", name: me.name, email: me.email)
        try w1.push()
        XCTAssertEqual(try w2.pull(), .fastForwarded)
        XCTAssertEqual(try String(contentsOf: w2.root.appendingPathComponent("main.tex")), "two")
        let st = try w2.status()
        XCTAssertEqual(st.ahead, 0); XCTAssertEqual(st.behind, 0)

        // both sides commit: w2 can't fast-forward
        try write("x.tex", "w1", in: w1)
        try w1.stageAll(); _ = try w1.commit(message: "w1 work", name: me.name, email: me.email)
        try w1.push()
        try write("y.tex", "w2", in: w2)
        try w2.stageAll(); _ = try w2.commit(message: "w2 work", name: me.name, email: me.email)
        XCTAssertThrowsError(try w2.pull()) { XCTAssertTrue($0.localizedDescription.contains("diverged")) }
        try w2.fetch()
        let st2 = try w2.status()
        XCTAssertEqual(st2.ahead, 1); XCTAssertEqual(st2.behind, 1)
    }

    func testCloneDoesNotCreateSymlinkConfig() throws {
        let bare = tmp.appendingPathComponent("s.git")
        try GitRepository.initializeBare(at: bare)
        let w = try GitRepository.cloneUnchecked(urlString: "file://" + bare.path, into: tmp.appendingPathComponent("w"), progress: { _, _ in })
        let cfg = try String(contentsOf: w.root.appendingPathComponent(".git/config"))
        XCTAssertTrue(cfg.contains("symlinks = false"), cfg)
    }

    // MARK: URL rules

    func testRemoteURLValidation() throws {
        XCTAssertEqual(try GitURL.validate("https://github.com/o/r.git").host, "github.com")
        for bad in ["git@github.com:o/r.git", "ssh://git@github.com/o/r.git", "http://example.com/r.git", "file:///tmp/x",
                    "https://user:secret@example.com/r.git", "https://token@example.com/r.git", "nonsense", ""] {
            XCTAssertThrowsError(try GitURL.validate(bad), "should reject \(bad)")
        }
        XCTAssertEqual(GitURL.repositoryName(URL(string: "https://github.com/o/My-Repo.git")!), "My-Repo")
        XCTAssertEqual(GitURL.repositoryName(URL(string: "https://github.com/o/plain")!), "plain")
    }

    func testRemoteConfigRejectsCredentialsInURL() throws {
        let repo = try GitRepository.initialize(at: tmp.appendingPathComponent("work"))
        XCTAssertThrowsError(try repo.setRemote(url: "https://me:pw@github.com/o/r.git"))
        try repo.setRemote(url: "https://github.com/o/r.git")
        XCTAssertEqual(repo.remoteURL(), "https://github.com/o/r.git")
        try repo.setRemote(url: "https://github.com/o/other.git")
        XCTAssertEqual(repo.remoteURL(), "https://github.com/o/other.git")
        XCTAssertTrue(try repo.status().hasRemote)
    }

    // MARK: credentials

    func testCredentialStoreRoundTrip() throws {
        let host = "unit-test-\(UUID().uuidString).example.com"
        defer { GitCredentialStore.delete(host: host) }
        XCTAssertNil(GitCredentialStore.load(host: host))
        // Unsigned command-line test builds have no keychain entitlement; the check runs in signed builds (Xcode / device).
        guard GitCredentialStore.save(GitCredential(username: "me", token: "tok_123"), host: host) else { throw XCTSkip("Keychain unavailable in this (unsigned) test run") }
        XCTAssertEqual(GitCredentialStore.load(host: host.uppercased()), GitCredential(username: "me", token: "tok_123"))   // host is case-insensitive
        XCTAssertTrue(GitCredentialStore.hosts().contains(host.lowercased()))
        GitCredentialStore.delete(host: host)
        XCTAssertNil(GitCredentialStore.load(host: host))
    }
}

// MARK: - HTTPS transport against a stubbed server

final class StubGitServer: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GitHTTPTransportTests: XCTestCase {
    override func setUp() {
        GitHTTP.protocolClasses = [StubGitServer.self]
        StubGitServer.seen = []
    }
    override func tearDown() {
        GitHTTP.protocolClasses = nil
        GitHTTP.credentials = { GitCredentialStore.load(host: $0) }
        StubGitServer.handler = nil
    }

    private func readAll(_ s: GitHTTPStream) -> (rc: Int32, text: String, error: String?) {
        var out = Data(); var buf = [CChar](repeating: 0, count: 64)
        while true {
            var n = 0
            let rc = buf.withUnsafeMutableBufferPointer { s.read(into: $0.baseAddress!, size: 64, bytesRead: &n) }
            if rc != 0 { return (rc, String(decoding: out, as: UTF8.self), s.errorCString.map { String(cString: $0) }) }
            if n == 0 { return (0, String(decoding: out, as: UTF8.self), nil) }
            out.append(Data(bytes: buf, count: n))
        }
    }

    func testListRefsSendsTokenOnlyToItsHostAndStreamsBody() {
        GitHTTP.credentials = { $0 == "git.example.com" ? GitCredential(username: "bob", token: "s3cret") : nil }
        StubGitServer.handler = { _ in (200, [:], Data("001e# service=git-upload-pack\n".utf8)) }
        let s = GitHTTPStream(url: URL(string: "https://git.example.com/o/r.git")!, service: 1)
        let r = readAll(s); s.cancel()
        XCTAssertEqual(r.rc, 0); XCTAssertEqual(r.text, "001e# service=git-upload-pack\n")
        let req = StubGitServer.seen.first
        XCTAssertEqual(req?.url?.absoluteString, "https://git.example.com/o/r.git/info/refs?service=git-upload-pack")
        XCTAssertEqual(req?.httpMethod, "GET")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("bob:s3cret".utf8).base64EncodedString())

        // another host: no Authorization header at all
        StubGitServer.seen = []
        let s2 = GitHTTPStream(url: URL(string: "https://other.example.org/o/r.git")!, service: 1)
        _ = readAll(s2); s2.cancel()
        XCTAssertNil(StubGitServer.seen.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUploadPackPostsBodyWithGitContentType() {
        StubGitServer.handler = { _ in (200, [:], Data("0008NAK\n".utf8)) }
        let s = GitHTTPStream(url: URL(string: "https://git.example.com/o/r.git")!, service: 2)
        s.append(Data("0032want abc\n".utf8))
        let r = readAll(s); s.cancel()
        XCTAssertEqual(r.rc, 0)
        let req = StubGitServer.seen.first
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/o/r.git/git-upload-pack")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/x-git-upload-pack-request")
    }

    func testAuthAndNotFoundAreExplained() {
        for (status, expect) in [(401, "Authentication failed"), (403, "Authentication failed"), (404, "not found"), (500, "HTTP 500")] {
            StubGitServer.handler = { _ in (status, [:], Data()) }
            let s = GitHTTPStream(url: URL(string: "https://git.example.com/o/r.git")!, service: 1)
            let r = readAll(s); s.cancel()
            XCTAssertEqual(r.rc, -1, "status \(status)")
            XCTAssertTrue(r.error?.contains(expect) == true, "status \(status): \(r.error ?? "nil")")
        }
    }

    func testPlainHTTPIsRefused() {
        let s = GitHTTPStream(url: URL(string: "http://git.example.com/o/r.git")!, service: 1)
        let r = readAll(s); s.cancel()
        XCTAssertEqual(r.rc, -1)
        XCTAssertTrue(r.error?.contains("https") == true)
        XCTAssertTrue(StubGitServer.seen.isEmpty)
    }

    func testTokenNeverAppearsInErrorMessages() {
        GitHTTP.credentials = { _ in GitCredential(username: "bob", token: "SUPERSECRETTOKEN") }
        StubGitServer.handler = { _ in (401, [:], Data()) }
        let s = GitHTTPStream(url: URL(string: "https://git.example.com/o/r.git")!, service: 1)
        let r = readAll(s); s.cancel()
        XCTAssertFalse((r.error ?? "").contains("SUPERSECRETTOKEN"))
    }
}
