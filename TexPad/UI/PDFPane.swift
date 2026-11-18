// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - remembered view state

/// Where the user was in the PDF; stored per project so a rebuild or relaunch returns to the same spot.
struct PDFViewMemory: Codable, Equatable {
    var page = 0
    var x = 0.0
    var y = 0.0
    var scale = 1.0
    var autoScales = true
    var layout = PDFLayout.continuous

    private static func key(_ project: String) -> String { "pdfview.v1." + project }
    static func load(_ project: String) -> PDFViewMemory? {
        UserDefaults.standard.data(forKey: key(project)).flatMap { try? JSONDecoder().decode(PDFViewMemory.self, from: $0) }
    }
    func save(_ project: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(project)) }
    }
}

enum PDFLayout: String, Codable, CaseIterable, Identifiable {
    case continuous, single, twoUp
    var id: String { rawValue }
    var title: String { switch self { case .continuous: "Continuous"; case .single: "Single page"; case .twoUp: "Two pages" } }
    var icon: String { switch self { case .continuous: "rectangle.grid.1x2"; case .single: "rectangle"; case .twoUp: "rectangle.split.2x1" } }
    var displayMode: PDFDisplayMode { switch self { case .continuous: .singlePageContinuous; case .single: .singlePage; case .twoUp: .twoUpContinuous } }
}

struct PDFOutlineNode: Identifiable {
    let id = UUID()
    var label: String
    var depth: Int
    var destination: PDFDestination?
}

// MARK: - controller

/// Drives the PDFView: zoom, pages, layout, outline, find, and best-effort source<->PDF jumps.
@MainActor
final class PDFController: ObservableObject {
    weak var view: PDFView?
    /// Bumped when a PDFView attaches, so views that need it (thumbnails) can link themselves.
    @Published private(set) var attachCount = 0
    /// Bumped whenever the displayed document is replaced (thumbnails re-render).
    @Published private(set) var revision = 0
    @Published var pageText = ""
    @Published var pageCount = 0
    @Published var currentPage = 1
    @Published var layout: PDFLayout = .continuous
    @Published var outline: [PDFOutlineNode] = []
    var onDoubleTap: ((String) -> Void)?
    /// Key for remembering the view position (the project's name).
    var memoryKey: String?
    private var saveWork: Task<Void, Never>?

    func attach(_ v: PDFView) {
        view = v
        DispatchQueue.main.async { self.attachCount += 1 }
    }

    func zoomIn() { view?.autoScales = false; view?.scaleFactor *= 1.2; persistSoon() }
    func zoomOut() { view?.autoScales = false; view?.scaleFactor /= 1.2; persistSoon() }
    func fitWidth() {
        guard let v = view else { return }
        v.autoScales = true
        persistSoon()
    }
    func fitPage() {
        guard let v = view else { return }
        v.autoScales = false
        let fit = v.scaleFactorForSizeToFit
        v.scaleFactor = fit > 0 ? fit : v.scaleFactor
        if let p = v.currentPage { v.go(to: p) }
        persistSoon()
    }

    func setLayout(_ l: PDFLayout) {
        layout = l
        view?.displayMode = l.displayMode
        view?.displaysAsBook = false
        persistSoon()
    }

    func goTo(page n: Int) {
        guard let v = view, let d = v.document, n >= 1, n <= d.pageCount, let p = d.page(at: n - 1) else { return }
        v.go(to: p)
    }
    func nextPage() { if view?.canGoToNextPage == true { view?.goToNextPage(nil) } }
    func previousPage() { if view?.canGoToPreviousPage == true { view?.goToPreviousPage(nil) } }

    func presentFind() { view?.findInteraction.presentFindNavigator(showingReplace: false) }

    func documentChanged() { revision += 1 }

    func refresh() {
        guard let v = view, let d = v.document else { pageText = ""; pageCount = 0; outline = []; return }
        pageCount = d.pageCount
        if let p = v.currentPage { currentPage = d.index(for: p) + 1 }
        pageText = "\(currentPage) / \(pageCount)"
    }
    func updatePageText() { refresh(); persistSoon() }

    func rebuildOutline() {
        var out: [PDFOutlineNode] = []
        func walk(_ o: PDFOutline, _ depth: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                out.append(PDFOutlineNode(label: c.label ?? "", depth: depth, destination: c.destination))
                walk(c, depth + 1)
                if out.count > 2000 { return }
            }
        }
        if let root = view?.document?.outlineRoot { walk(root, 0) }
        outline = out
    }

    func go(to n: PDFOutlineNode) { if let d = n.destination { view?.go(to: d) } }

    // MARK: persistence

    func persistSoon() {
        saveWork?.cancel()
        saveWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.persistNow() }
        }
    }

    func persistNow() {
        guard let key = memoryKey, let v = view, let d = v.document, let p = v.currentPage, let dest = v.currentDestination else { return }
        PDFViewMemory(page: d.index(for: p), x: Double(dest.point.x), y: Double(dest.point.y), scale: Double(v.scaleFactor),
                      autoScales: v.autoScales, layout: layout).save(key)
    }

    func restoreMemory() {
        guard let key = memoryKey, let m = PDFViewMemory.load(key), let v = view, let d = v.document else { return }
        layout = m.layout
        v.displayMode = m.layout.displayMode
        v.autoScales = m.autoScales
        if !m.autoScales { v.scaleFactor = CGFloat(m.scale) }
        if m.page < d.pageCount, let page = d.page(at: m.page) { v.go(to: PDFDestination(page: page, at: CGPoint(x: m.x, y: m.y))) }
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

// MARK: - PDF pane

struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PDFPane: View {
    @ObservedObject var project: Project
    @ObservedObject var controller: PDFController
    @AppStorage("pdfDark") private var pdfDark = "auto"          // auto | on | off
    @AppStorage("pdfFollowCursor") private var followCursor = false
    @AppStorage("pdfSidebar") private var showSidebar = false
    @State private var sidebarMode = 0                               // 0 thumbnails, 1 outline
    @State private var exporting = false
    @State private var pageField = ""
    @Environment(\.colorScheme) private var colorScheme

    private var inverted: Bool { pdfDark == "on" || (pdfDark == "auto" && colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if showSidebar && project.pdf != nil { sidebar.frame(width: 132); Divider() }
                ZStack {
                    if let d = project.pdf {
                        PDFKitView(data: d, controller: controller)
                            .colorInvert(inverted)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.richtext").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("Press Build (⌘B) to preview").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear { controller.onDoubleTap = { text in jumpToSource(text) }; controller.memoryKey = project.name }
        .onChange(of: project.pdf) { _, new in
            guard new != nil, followCursor else { return }
            Task { try? await Task.sleep(nanoseconds: 350_000_000); _ = jumpToPDF(silent: true) }
        }
        .fileExporter(isPresented: $exporting, document: PDFFileDocument(data: project.pdf ?? Data()), contentType: .pdf,
                      defaultFilename: (project.mainName.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "document")) { _ in }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left").symbolVariant(showSidebar ? .fill : .none) }
                .accessibilityLabel("Thumbnails and outline")
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            Menu {
                Button { controller.fitWidth() } label: { Label("Fit width", systemImage: "arrow.left.and.right") }
                Button { controller.fitPage() } label: { Label("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") }
                Divider()
                ForEach(PDFLayout.allCases) { l in
                    Button { controller.setLayout(l) } label: {
                        if controller.layout == l { Label(l.title, systemImage: "checkmark") } else { Label(l.title, systemImage: l.icon) }
                    }
                }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }

            Button { controller.previousPage() } label: { Image(systemName: "chevron.up") }
            TextField(controller.pageText.isEmpty ? "–" : "\(controller.currentPage)", text: $pageField)
                .keyboardType(.numberPad).multilineTextAlignment(.center).frame(width: 40)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let n = Int(pageField) { controller.goTo(page: n) }; pageField = "" }
            Text("/ \(controller.pageCount)").font(.caption).foregroundStyle(.secondary)
            Button { controller.nextPage() } label: { Image(systemName: "chevron.down") }

            Spacer(minLength: 4)
            Button { controller.presentFind() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Find in PDF")
            Button { pdfDark = pdfDark == "off" ? "on" : pdfDark == "on" ? "auto" : "off" } label: {
                Image(systemName: pdfDark == "auto" ? "circle.lefthalf.filled" : pdfDark == "on" ? "moon.fill" : "sun.max")
            }.accessibilityLabel("PDF dark mode: \(pdfDark)")
            Button { _ = jumpToPDF(silent: false) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }
                .accessibilityLabel("Show current source line in the PDF")
            Menu {
                Toggle(isOn: $followCursor) { Label("Follow cursor after build", systemImage: "scope") }
                Divider()
                if let data = project.pdf {
                    if let u = project.saveBuildOutput(), FileManager.default.fileExists(atPath: u.path) {
                        ShareLink(item: u) { Label("Share PDF…", systemImage: "square.and.arrow.up") }
                    }
                    Button { PDFPrinter.printPDF(data, title: project.mainName ?? "TexPad") } label: { Label("Print…", systemImage: "printer") }
                    Button { exporting = true } label: { Label("Save to Files…", systemImage: "folder") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.secondarySystemBackground))
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarMode) { Image(systemName: "square.grid.2x2").tag(0); Image(systemName: "list.bullet.indent").tag(1) }
                .pickerStyle(.segmented).padding(6)
            if sidebarMode == 0 {
                PDFThumbnails(controller: controller)
            } else if controller.outline.isEmpty {
                Text("No outline").font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                List(controller.outline) { n in
                    Button { controller.go(to: n) } label: {
                        Text(n.label).font(.caption).lineLimit(2).padding(.leading, CGFloat(n.depth) * 8)
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    // MARK: source <-> PDF (best effort; the bundled engines don't emit SyncTeX)

    @discardableResult
    private func jumpToPDF(silent: Bool) -> Bool {
        guard let a = project.active, let t = project.text(of: a) else { return false }
        let lines = t.components(separatedBy: "\n")
        let i = max(0, min(project.cursor.line - 1, lines.count - 1))
        // search outward from the cursor for a line that has visible text
        for off in 0..<8 {
            for cand in [i + off, i - off] where cand >= 0 && cand < lines.count {
                if let q = SyncGuess.pdfQuery(forSourceLine: lines[cand]), controller.reveal(q) { return true }
            }
        }
        if !silent { project.toast = "Couldn't find that line in the PDF" }
        return false
    }

    private func jumpToSource(_ text: String) {
        var texts: [String: String] = [:]
        for n in FileTree.flatten(project.tree) where n.ext == "tex" { if let t = project.text(of: n.path) { texts[n.path] = t } }
        if let hit = SyncGuess.source(forPDFText: text, texts: texts) { project.open(hit.path, line: hit.line) }
        else { project.toast = "No matching source line found" }
    }
}

extension View {
    /// Inverts colours (dark PDF mode). Hue rotation keeps colours recognisable after the inversion.
    @ViewBuilder func colorInvert(_ on: Bool) -> some View {
        if on { self.colorInvert().hueRotation(.degrees(180)) } else { self }
    }
}

// MARK: - thumbnails

struct PDFThumbnails: View {
    @ObservedObject var controller: PDFController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<controller.pageCount, id: \.self) { i in
                        ThumbnailCell(controller: controller, index: i).id(i)
                    }
                }.padding(8)
            }
            .onChange(of: controller.currentPage) { _, p in withAnimation { proxy.scrollTo(p - 1, anchor: .center) } }
        }
    }
}

private struct ThumbnailCell: View {
    @ObservedObject var controller: PDFController
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Rectangle().fill(Color(.tertiarySystemFill)).aspectRatio(0.77, contentMode: .fit) }
            }
            .background(Color.white)
            .overlay(Rectangle().stroke(controller.currentPage == index + 1 ? Color.accentColor : Color(.separator),
                                        lineWidth: controller.currentPage == index + 1 ? 3 : 1))
            Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.goTo(page: index + 1) }
        .task(id: controller.revision) {
            image = controller.view?.document?.page(at: index)?.thumbnail(of: CGSize(width: 180, height: 240), for: .cropBox)
        }
    }
}

// MARK: - PDF view

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
        v.isFindInteractionEnabled = true
        controller?.attach(v)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        v.addGestureRecognizer(tap)
        context.coordinator.controller = controller
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewVisiblePagesChanged] {
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: name, object: v)
        }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        guard context.coordinator.lastData != data else { return }
        let first = context.coordinator.lastData == nil
        context.coordinator.lastData = data
        let oldIndex = v.currentPage.flatMap { v.document?.index(for: $0) }
        let oldPoint = v.currentDestination?.point
        let oldScale = v.scaleFactor, wasAuto = v.autoScales
        let doc = PDFDocument(data: data)
        if let doc { PDFSanitizer.sanitize(doc) }
        v.document = doc
        if first {
            controller?.restoreMemory()           // reopening a project: back to where the user was
        } else if let i = oldIndex, let doc = v.document, i < doc.pageCount, let page = doc.page(at: i) {
            if !wasAuto { v.autoScales = false; v.scaleFactor = oldScale }
            if let pt = oldPoint { v.go(to: PDFDestination(page: page, at: pt)) }   // rebuild: stay put
        }
        controller?.rebuildOutline()
        controller?.refresh()
        controller?.documentChanged()
    }

    final class Coordinator: NSObject {
        var lastData: Data?
        weak var controller: PDFController?
        @objc func changed() { Task { @MainActor in controller?.updatePageText() } }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? PDFView, let page = v.page(for: g.location(in: v), nearest: true) else { return }
            let pt = v.convert(g.location(in: v), to: page)
            let text = page.selectionForLine(at: pt)?.string ?? page.selectionForWord(at: pt)?.string ?? ""
            if !text.isEmpty { Task { @MainActor in controller?.onDoubleTap?(text) } }
        }
    }
}

// MARK: - printing

enum PDFPrinter {
    @MainActor
    static func printPDF(_ data: Data, title: String) {
        guard UIPrintInteractionController.canPrint(data) else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let c = UIPrintInteractionController.shared
        c.printInfo = info
        c.printingItem = data
        c.present(animated: true, completionHandler: nil)
    }
}

// MARK: - link sanitising

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
