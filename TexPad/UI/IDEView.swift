// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case explorer, search, git, outline, symbols
    var id: String { rawValue }
    var icon: String { switch self { case .explorer: "doc.on.doc"; case .search: "magnifyingglass"; case .git: "arrow.triangle.branch"; case .outline: "list.bullet.indent"; case .symbols: "function" } }
    var title: String { switch self { case .explorer: "Explorer"; case .search: "Search"; case .git: "Source Control"; case .outline: "Outline"; case .symbols: "Insert" } }
}

enum BottomTab: String, CaseIterable { case problems = "Problems", log = "Build Log" }

struct IDEView: View {
    @ObservedObject var project: Project
    @EnvironmentObject var store: ProjectStore
    #if DEBUG
    @State private var sidebarTab: SidebarTab? = ProcessInfo.processInfo.environment["TEXPAD_SIDEBAR"].flatMap { SidebarTab(rawValue: $0) } ?? .explorer
    #else
    @State private var sidebarTab: SidebarTab? = .explorer
    #endif
    #if DEBUG
    @State private var showPDF = ProcessInfo.processInfo.environment["TEXPAD_SHOW_PDF"] != nil
    #else
    @State private var showPDF = false
    #endif
    @State private var showBottom = false
    @State private var bottomTab: BottomTab = .problems
    @State private var palette: PaletteMode?
    @State private var showSettings = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 250
    @AppStorage("pdfFraction") private var pdfFraction: Double = 0.45
    @AppStorage("theme") private var theme = "system"
    @AppStorage("fontSize") private var fontSize = 15
    @AppStorage("wrap") private var wrap = true
    @StateObject private var pdfController = PDFController()
    @StateObject private var keyboard = KeyboardObserver()

    // On narrow screens with the PDF open the editor is hidden, so no key bar is needed.
    private var showPDFOnly: Bool { showPDF && screenWidth < 1000 }
    @State private var screenWidth: CGFloat = 1200

    var body: some View {
        VStack(spacing: 0) {
            TopBar(project: project, sidebarTab: $sidebarTab, showPDF: $showPDF, showBottom: $showBottom,
                   palette: $palette, showSettings: $showSettings)
            Divider()
            GeometryReader { geo in
                let narrow = geo.size.width < 1000
                let _ = DispatchQueue.main.async { if screenWidth != geo.size.width { screenWidth = geo.size.width } }
                HStack(spacing: 0) {
                    ActivityBar(selection: $sidebarTab, problems: project.errorCount, gitChanges: project.git.changeCount)
                    Divider()
                    if let tab = sidebarTab {
                        SidebarView(project: project, tab: tab).frame(width: sidebarWidth)
                        DragHandle { dx in sidebarWidth = min(max(180, sidebarWidth + dx), geo.size.width * 0.5) }
                    }
                    VStack(spacing: 0) {
                        EditorArea(project: project, pdf: pdfController)
                        if showBottom && !keyboard.visible {
                            Divider()
                            BottomPanel(project: project, tab: $bottomTab).frame(height: 220)
                        }
                    }
                    // Narrow (portrait) screens show either the editor or the PDF, wide screens show both.
                    .frame(maxWidth: narrow && showPDF ? 0 : .infinity).opacity(narrow && showPDF ? 0 : 1).clipped()
                    if showPDF {
                        if !narrow { DragHandle { dx in pdfFraction = min(max(0.2, pdfFraction - dx / (geo.size.width - sidebarWidth)), 0.7) } }
                        if narrow { PDFPane(project: project, controller: pdfController) }
                        else { PDFPane(project: project, controller: pdfController).frame(width: (geo.size.width - sidebarWidth - 50) * pdfFraction) }
                    }
                }
                .onAppear { if !narrow && !showPDF { showPDF = true } }
            }
            Divider()
            StatusBar(project: project, engine: store.engine, git: project.git)
            if keyboard.visible && project.active != nil && !showPDFOnly { KeyBar(project: project) }
        }
        .background(Color(.systemBackground))
        .overlay { if let m = palette { PaletteView(mode: m, project: project, dismiss: { palette = nil }, actions: paletteActions) } }
        .sheet(isPresented: $showSettings) { SettingsView(project: project) }
        .overlay(alignment: .bottom) { ToastView(message: $project.toast) }
        .background(shortcuts)
        .onChange(of: theme) { _, v in project.editor.setTheme(v) }
        .onChange(of: fontSize) { _, v in project.editor.setFontSize(v) }
        .onChange(of: wrap) { _, v in project.editor.setWrap(v) }
        .onReceive(NotificationCenter.default.publisher(for: .editorShortcut)) { n in
            switch n.object as? String { case "palette": palette = .commands; case "quickOpen": palette = .files; case "search": sidebarTab = .search; default: break }
        }
        .onChange(of: project.diagnostics) { _, d in if d.contains(where: { $0.severity == .error }) { showBottom = true; bottomTab = .problems } }
    }

    // Hidden buttons give hardware-keyboard shortcuts when the editor isn't focused.
    private var shortcuts: some View {
        ZStack {
            Button("") { project.build() }.keyboardShortcut("b", modifiers: .command)
            Button("") { project.saveAll() }.keyboardShortcut("s", modifiers: .command)
            Button("") { palette = .commands }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { palette = .files }.keyboardShortcut("p", modifiers: .command)
            Button("") { sidebarTab = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { sidebarTab = sidebarTab == nil ? .explorer : nil }.keyboardShortcut("0", modifiers: .command)
            Button("") { showPDF.toggle() }.keyboardShortcut("1", modifiers: .command)
            Button("") { showBottom.toggle() }.keyboardShortcut("j", modifiers: .command)
        }.opacity(0).allowsHitTesting(false)
    }

    private var paletteActions: [PaletteAction] {
        [
            .init("Build", "⌘B", "play.fill") { project.build() },
            .init("Save All", "⌘S", "square.and.arrow.down") { project.saveAll() },
            .init("Go to File…", "⌘P", "doc") { palette = .files },
            .init("Search in Files", "⇧⌘F", "magnifyingglass") { sidebarTab = .search },
            .init("Toggle Sidebar", "⌘0", "sidebar.left") { sidebarTab = sidebarTab == nil ? .explorer : nil },
            .init("Toggle PDF Preview", "⌘1", "doc.richtext") { showPDF.toggle() },
            .init("Toggle Problems Panel", "⌘J", "exclamationmark.triangle") { showBottom.toggle() },
            .init("Show Outline", nil, "list.bullet.indent") { sidebarTab = .outline },
            .init("Insert Snippet / Symbol…", nil, "function") { sidebarTab = .symbols },
            .init("Find in File", nil, "text.magnifyingglass") { project.editor.find() },
            .init("Set Current File as Main", nil, "star") { if let a = project.active { project.setMainFile(a) } },
            .init("Clear Main File Override", nil, "star.slash") { project.setMainFile(nil) },
            .init("Toggle Word Wrap", nil, "text.alignleft") { wrap.toggle() },
            .init("Increase Font Size", nil, "textformat.size.larger") { fontSize = min(28, fontSize + 1) },
            .init("Decrease Font Size", nil, "textformat.size.smaller") { fontSize = max(10, fontSize - 1) },
            .init("Settings", nil, "gearshape") { showSettings = true },
            .init("Close Project", nil, "xmark.circle") { store.closeProject() },
        ]
    }
}

struct DragHandle: View {
    var onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0
    var body: some View {
        Rectangle().fill(Color(.separator)).frame(width: 1)
            .overlay(Color.clear.frame(width: 14).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in onDrag(v.translation.width - last); last = v.translation.width }
                    .onEnded { _ in last = 0 }))
    }
}

struct ToastView: View {
    @Binding var message: String?
    var body: some View {
        if let m = message {
            Text(m).padding(.horizontal, 16).padding(.vertical, 10).background(.thinMaterial, in: Capsule()).padding(.bottom, 40)
                .task(id: m) { try? await Task.sleep(nanoseconds: 3_000_000_000); message = nil }
                .transition(.opacity)
        }
    }
}
