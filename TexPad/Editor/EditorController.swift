// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import WebKit

enum EditorEvent {
    case ready
    case change(path: String, text: String)
    case dirty(path: String)
    case save(path: String?)
    case cursor(path: String?, line: Int, col: Int, selected: String)
    case build, palette, quickOpen, searchProject
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: EditorController?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let type = d["type"] as? String else { return }
        Task { @MainActor in self.target?.handle(type: type, body: d) }
    }
}

/// Owns the CodeMirror web view and speaks to `window.editor` in editor.bundle.js.
@MainActor
final class EditorController: NSObject {
    let webView: WKWebView
    private let handler: TeXSchemeHandler
    private var ready = false
    private var queue: [() async -> Void] = []
    var onEvent: ((EditorEvent) -> Void)?

    override init() {
        handler = TeXSchemeHandler(cacheDir: TeXEngine.cacheDir)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(handler, forURLScheme: "tex")
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let proxy = WeakHandler()
        cfg.userContentController.add(proxy, name: "editor")
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.isOpaque = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
        proxy.target = self
        webView.load(URLRequest(url: URL(string: "tex://app/editor/editor.html")!))
    }

    fileprivate func handle(type: String, body d: [String: Any]) {
        switch type {
        case "ready":
            ready = true
            let q = queue; queue = []
            Task { for f in q { await f() } }
            onEvent?(.ready)
        case "change": onEvent?(.change(path: d["path"] as? String ?? "", text: d["text"] as? String ?? ""))
        case "dirty": onEvent?(.dirty(path: d["path"] as? String ?? ""))
        case "save": onEvent?(.save(path: d["path"] as? String))
        case "cursor": onEvent?(.cursor(path: d["path"] as? String, line: d["line"] as? Int ?? 1, col: d["col"] as? Int ?? 1,
                                        selected: d["selected"] as? String ?? ""))
        case "build": onEvent?(.build)
        case "palette": onEvent?(.palette)
        case "quickOpen": onEvent?(.quickOpen)
        case "searchProject": onEvent?(.searchProject)
        default: break
        }
    }

    // MARK: calls into JS (queued until the page is ready)

    private func run(_ js: String, _ args: [String: Any] = [:]) {
        let op: () async -> Void = { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
            } catch {
                #if DEBUG
                NSLog("[editor] js error: %@ in %@", "\(error)", js)
                #endif
            }
        }
        if ready { Task { await op() } } else { queue.append(op) }
    }

    func open(path: String, text: String, line: Int = 0, col: Int = 1) {
        run("window.editor.openDoc(path, text, line, col)", ["path": path, "text": text, "line": line, "col": col])
    }
    func close(path: String) { run("window.editor.closeDoc(path)", ["path": path]) }
    func rename(from: String, to: String) { run("window.editor.renameDoc(a, b)", ["a": from, "b": to]) }
    func reload(path: String, text: String) { run("window.editor.reload(path, text)", ["path": path, "text": text]) }
    func goto(line: Int, col: Int = 1, select: Bool = false) {
        run("window.editor.gotoLine(line, col, select)", ["line": line, "col": col, "select": select])
    }
    func setDiagnostics(path: String, items: [[String: Any]]) { run("window.editor.setDiagnostics(path, items)", ["path": path, "items": items]) }
    func clearDiagnostics() { run("window.editor.clearDiagnostics()") }
    func setProjectData(_ d: [String: Any]) { run("window.editor.setProjectData(d)", ["d": d]) }
    func insert(_ text: String) { run("window.editor.insertText(t)", ["t": text]) }
    func insertSnippet(_ tpl: String) { run("window.editor.insertSnippet(t)", ["t": tpl]) }
    func complete() { run("window.editor.complete()") }
    /// Dev/test hook: evaluate arbitrary JS in the editor page.
    #if DEBUG
    func evalDebug(_ js: String) { run(js) }
    #endif
    func find() { run("window.editor.find()") }
    func undo() { run("window.editor.undo()") }
    func redo() { run("window.editor.redo()") }
    func focus() { run("window.editor.focus()") }
    func setTheme(_ name: String) { run("window.editor.setTheme(n)", ["n": name]) }
    func setFontSize(_ px: Int) { run("window.editor.setFontSize(n)", ["n": px]) }
    func setWrap(_ on: Bool) { run("window.editor.setWrap(b)", ["b": on]) }
    func currentText() async -> String? {
        try? await webView.callAsyncJavaScript("return window.editor.getText()", contentWorld: .page) as? String
    }
}


extension EditorController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == "tex" ? .allow : .cancel
    }

    /// If iOS kills the editor's web process (memory pressure) reload it; Project re-opens the active file on `.ready`.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.ready = false
            webView.reload()
        }
    }
}
