// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
import PDFKit
@testable import TexPad

final class SecurityTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("texpad-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: PathSafety

    func testSafeNames() {
        XCTAssertTrue(PathSafety.isSafeName("main.tex"))
        XCTAssertTrue(PathSafety.isSafeName(".ipadtex.json"))
        for bad in ["", ".", "..", "a/b", "a\\b", "x\u{0}y", "line\nbreak", String(repeating: "a", count: 300)] {
            XCTAssertFalse(PathSafety.isSafeName(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testSafeRelativePaths() {
        XCTAssertTrue(PathSafety.isSafeRelative("chapters/intro.tex"))
        for bad in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "a/./b", "..", "a/.."] {
            XCTAssertFalse(PathSafety.isSafeRelative(bad), "should reject \(bad)")
        }
    }

    func testTeXNamesRejectEncodedSeparators() {
        XCTAssertTrue(PathSafety.isSafeTeXName("article.cls"))
        XCTAssertTrue(PathSafety.isSafeTeXName("cmr10"))
        XCTAssertFalse(PathSafety.isSafeTeXName("..%2f..%2fsecret.txt"))
        XCTAssertFalse(PathSafety.isSafeTeXName("../secret.txt"))
        XCTAssertFalse(PathSafety.isSafeTeXName("a%00b"))
    }

    func testResolveRejectsSymlinkEscape() throws {
        let root = tmp.appendingPathComponent("project")
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try "ok".write(to: root.appendingPathComponent("a.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertNotNil(PathSafety.resolve("a.tex", in: root))
        XCTAssertNil(PathSafety.resolve("link/s.txt", in: root), "symlink pointing outside the project must not resolve")
        XCTAssertNil(PathSafety.resolve("../outside/s.txt", in: root))
    }

    func testFileTreeSkipsSymlinks() throws {
        let root = tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let names = FileTree.flatten(FileTree.scan(root: root)).map(\.path)
        XCTAssertEqual(names, ["a.tex"])
    }

    // MARK: scheme handler (the TeX engine's view of the filesystem)

    @MainActor
    func testHandlerLookupCannotLeaveItsDirectories() throws {
        let cache = tmp.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "SECRET".write(to: tmp.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "ok".write(to: cache.appendingPathComponent("legit.sty"), atomically: true, encoding: .utf8)
        let h = TeXSchemeHandler(cacheDir: cache)

        XCTAssertNotNil(h.lookup("legit", fmt: 26))
        XCTAssertNil(h.lookup("../secret.txt", fmt: 26))
        XCTAssertNil(h.lookup("..%2fsecret.txt", fmt: 26))
        XCTAssertNil(h.lookup("/etc/passwd", fmt: 26))
        XCTAssertNil(h.lookup("..", fmt: 26))
    }

    // MARK: log parsing resource limits

    func testHugeHostileLogParsesQuickly() {
        // One endless chain of exactly-79-column lines (what a hostile document can print), plus a flood of fake errors.
        let chain = (0..<40_000).map { _ in String(repeating: "x", count: 79) }.joined(separator: "\n")
        let flood = (0..<20_000).map { "! Fake error \($0).\nl.\($0) boom" }.joined(separator: "\n")
        let start = Date()
        let d = LogParser.parse(chain + "\n" + flood)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        XCTAssertLessThanOrEqual(d.count, LogParser.maxDiagnostics)
    }

    // MARK: watchdog

    @MainActor
    func testWithTimeoutFiresOnHungOperation() async {
        do {
            _ = try await withTimeout(seconds: 0.2) { try await Task.sleep(nanoseconds: 60 * 1_000_000_000); return 1 }
            XCTFail("expected timeout")
        } catch { XCTAssertTrue(error is BuildTimeout) }
    }

    @MainActor
    func testWithTimeoutPassesThroughResult() async throws {
        let v = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(v, 42)
    }

    // MARK: PDF link sanitising

    func testPDFSanitizerStripsDangerousLinks() throws {
        let doc = PDFDocument()
        let page = PDFPage()
        for (i, u) in ["https://example.com", "tel:123456", "facetime://x", "file:///etc/passwd", "mailto:a@b.c"].enumerated() {
            let a = PDFAnnotation(bounds: CGRect(x: 10, y: 10 + i * 20, width: 50, height: 10), forType: .link, withProperties: nil)
            a.url = URL(string: u)
            page.addAnnotation(a)
        }
        doc.insert(page, at: 0)
        PDFSanitizer.sanitize(doc)
        let kept = doc.page(at: 0)!.annotations.compactMap { $0.url?.absoluteString }.sorted()
        XCTAssertEqual(kept, ["https://example.com", "mailto:a@b.c"])
    }
}
