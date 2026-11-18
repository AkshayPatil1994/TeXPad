// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import PDFKit

/// Drives the PDFView: zoom, page info, and best-effort source<->PDF jumps.
@MainActor
final class PDFController: ObservableObject {
    weak var view: PDFView?
    @Published var pageText = ""
    var onDoubleTap: ((String) -> Void)?

    func zoomIn() { view?.autoScales = false; view?.scaleFactor *= 1.2 }
    func zoomOut() { view?.autoScales = false; view?.scaleFactor /= 1.2 }
    func fit() { view?.autoScales = true }
    func updatePageText() {
        guard let v = view, let d = v.document, let p = v.currentPage else { return }
        pageText = "\(d.index(for: p) + 1) / \(d.pageCount)"
    }

    /// Find `query` in the PDF text layer and scroll to it.
    @discardableResult
    func reveal(_ query: String) -> Bool {
        guard let v = view, let doc = v.document else { return false }
        let sels = doc.findString(query, withOptions: .caseInsensitive)
        guard let s = sels.first else { return false }
        v.setCurrentSelection(s, animate: true)
        v.go(to: s)
        return true
    }
}

struct PDFPane: View {
    @ObservedObject var project: Project
    @ObservedObject var controller: PDFController
    @State private var sharing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                Button { controller.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                Text(controller.pageText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { jumpToPDF() } label: { Label("To PDF", systemImage: "arrow.right.doc.on.clipboard").labelStyle(.iconOnly) }
                    .help("Show the current source line in the PDF")
                if project.pdf != nil, let u = project.saveBuildOutput(), FileManager.default.fileExists(atPath: u.path) {
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.secondarySystemBackground))
            Divider()
            ZStack {
                if let d = project.pdf {
                    PDFKitView(data: d, controller: controller)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("Press Build (⌘B) to preview").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { controller.onDoubleTap = { text in jumpToSource(text) } }
    }

    private func jumpToPDF() {
        guard let a = project.active, let t = project.text(of: a) else { return }
        let lines = t.components(separatedBy: "\n")
        var i = max(0, min(project.cursor.line - 1, lines.count - 1))
        // search outward from the cursor for a line that has visible text
        for off in 0..<8 {
            for cand in [i + off, i - off] where cand >= 0 && cand < lines.count {
                if let q = SyncGuess.pdfQuery(forSourceLine: lines[cand]), controller.reveal(q) { return }
            }
        }
        project.toast = "Couldn't find that line in the PDF"
        i = 0
    }

    private func jumpToSource(_ text: String) {
        var texts: [String: String] = [:]
        for n in FileTree.flatten(project.tree) where n.ext == "tex" { if let t = project.text(of: n.path) { texts[n.path] = t } }
        if let hit = SyncGuess.source(forPDFText: text, texts: texts) { project.open(hit.path, line: hit.line) }
        else { project.toast = "No matching source line found" }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data
    let controller: PDFController?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor.secondarySystemBackground
        v.pageShadowsEnabled = true
        controller?.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        v.addGestureRecognizer(tap)
        context.coordinator.controller = controller
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: v)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        guard context.coordinator.lastData != data else { return }
        context.coordinator.lastData = data
        let oldIndex = v.currentPage.flatMap { v.document?.index(for: $0) }
        defer { if let d = v.document { PDFSanitizer.sanitize(d) } }
        let oldPoint = v.currentDestination?.point
        let oldScale = v.scaleFactor, wasAuto = v.autoScales
        v.document = PDFDocument(data: data)
        if let i = oldIndex, let doc = v.document, i < doc.pageCount, let page = doc.page(at: i) {
            if !wasAuto { v.autoScales = false; v.scaleFactor = oldScale }
            if let pt = oldPoint { v.go(to: PDFDestination(page: page, at: pt)) }
        }
        controller?.updatePageText()
    }

    final class Coordinator: NSObject {
        var lastData: Data?
        weak var controller: PDFController?
        @objc func pageChanged() { Task { @MainActor in controller?.updatePageText() } }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? PDFView, let page = v.page(for: g.location(in: v), nearest: true) else { return }
            let pt = v.convert(g.location(in: v), to: page)
            let text = page.selectionForLine(at: pt)?.string ?? page.selectionForWord(at: pt)?.string ?? ""
            if !text.isEmpty { Task { @MainActor in controller?.onDoubleTap?(text) } }
        }
    }
}


/// PDFs produced from untrusted LaTeX can carry link annotations pointing at any URL scheme (tel:, facetime:, app deep links, file:).
/// Keep only web and mail links; strip everything else before the document is shown.
enum PDFSanitizer {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func sanitize(_ doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Link" {
                if let url = a.url {
                    if !allowedSchemes.contains(url.scheme?.lowercased() ?? "") { page.removeAnnotation(a) }
                } else if let act = a.action, !(act is PDFActionGoTo) {
                    page.removeAnnotation(a)     // named actions, remote goto, launch, reset-form, ...
                }
            }
        }
    }
}
