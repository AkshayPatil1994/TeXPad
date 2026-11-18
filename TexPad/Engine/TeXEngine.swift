// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import WebKit

/// Hosts the pdfTeX WebAssembly worker in an off-screen WKWebView.
@MainActor
final class TeXEngine: NSObject, ObservableObject {
    enum Status: Equatable { case idle, loading, buildingFormat, ready, failed(String) }
    @Published private(set) var status: Status = .idle
    private var prepareTask: Task<Bool, Never>?

    @Published private(set) var webView: WKWebView
    let handler: TeXSchemeHandler
    private var loaded = false

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("texcache")
    }
    private var fmtURL: URL { handler.cacheDir.appendingPathComponent("swiftlatexpdftex.fmt") }

    override init() {
        handler = TeXSchemeHandler(cacheDir: TeXEngine.cacheDir)
        webView = TeXEngine.makeWebView(handler: handler)
        super.init()
        webView.navigationDelegate = self
    }

    private static func makeWebView(handler: TeXSchemeHandler) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(handler, forURLScheme: "tex")
        cfg.websiteDataStore = .nonPersistent()       // nothing the engine page does is stored
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        #if DEBUG
        if #available(iOS 16.4, *) { v.isInspectable = true }
        #endif
        return v
    }

    /// Throws away the web view (killing a runaway or crashed engine) and starts over; the cached format is reused.
    func restart() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView = TeXEngine.makeWebView(handler: handler)
        webView.navigationDelegate = self
        loaded = false
        prepareTask = nil
        status = .idle
    }

    /// Loads the WASM engine and builds the LaTeX format once. Safe to call repeatedly.
    func prepare() async -> Bool {
        if status == .ready { return true }
        if let t = prepareTask { return await t.value }
        let t = Task { @MainActor () -> Bool in
            do {
                status = .loading
                try await load()
                status = .buildingFormat
                if let err = try await ensureFormat() { status = .failed(err); return false }
                status = .ready
                return true
            } catch { status = .failed("\(error)"); return false }
        }
        prepareTask = t
        let ok = await t.value
        if !ok { prepareTask = nil }   // allow retry
        return ok
    }

    func load() async throws {
        guard !loaded else { return }
        webView.load(URLRequest(url: URL(string: "tex://app/engine.html")!))
        // wait for page load
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("typeof window.tex")) as? String == "object" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try await webView.callAsyncJavaScript("return await window.tex.load()", contentWorld: .page)
        loaded = true
    }

    /// Builds pdflatex.fmt once (on first launch) from the bundled TeX tree.
    func ensureFormat() async throws -> String? {
        if FileManager.default.fileExists(atPath: fmtURL.path) { return nil }
        let r = try await webView.callAsyncJavaScript("return await window.tex.run({engine: 'pdftex', op: 'format'})", contentWorld: .page)
        guard let d = r as? [String: Any], d["ok"] as? Bool == true, let b64 = d["fmt"] as? String,
              let data = Data(base64Encoded: b64) else {
            return (r as? [String: Any])?["log"] as? String ?? "format build failed"
        }
        try data.write(to: fmtURL)
        return nil
    }

    /// Runs one build step in the given engine. `files` (and `reset`) are only needed on the first step that uses the engine.
    func run(engine kind: EngineKind, op: String, main: String, files: [String: Data], reset: Bool, produce: Bool) async throws -> StepResult {
        var dirs = Set<String>()
        for name in files.keys {
            var acc = ""
            for c in name.split(separator: "/").dropLast() { acc += (acc.isEmpty ? "" : "/") + c; dirs.insert(acc) }
        }
        let spec: [String: Any] = [
            "engine": kind.rawValue, "op": op, "main": main, "reset": reset, "produce": produce,
            "files": files.mapValues { $0.base64EncodedString() }, "dirs": dirs.sorted(),
        ]
        let r = try await webView.callAsyncJavaScript("return await window.tex.run(spec)", arguments: ["spec": spec], contentWorld: .page)
        guard let d = r as? [String: Any] else { return StepResult(ok: false, log: "bad result from engine", pdf: nil, ms: 0) }
        return StepResult(ok: d["ok"] as? Bool ?? false, log: d["log"] as? String ?? "",
                          pdf: (d["pdf"] as? String).flatMap { Data(base64Encoded: $0) }, ms: d["ms"] as? Int ?? 0)
    }
}


extension TeXEngine: WKNavigationDelegate {
    /// The engine page never navigates anywhere except our own tex:// pages.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == "tex" ? .allow : .cancel
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in if webView === self.webView { self.restart() } }
    }
}
