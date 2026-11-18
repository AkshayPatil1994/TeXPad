// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var project: Project
    let tab: SidebarTab

    var body: some View {
        VStack(spacing: 0) {
            Text(tab.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            switch tab {
            case .explorer: ExplorerView(project: project)
            case .search: SearchView(project: project)
            case .outline: OutlineView(project: project)
            case .symbols: SymbolsView(project: project)
            }
        }
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }
}

// MARK: - Explorer

struct ExplorerView: View {
    @ObservedObject var project: Project
    @State private var expanded: Set<String> = []
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var importing = false
    @State private var importDir = ""
    @State private var pendingDelete: String?

    struct Prompt: Identifiable { enum Kind { case newFile, newFolder, rename }; let kind: Kind; let dir: String; let path: String; var id: String { "\(kind)\(dir)\(path)" } }

    var rows: [(node: FileNode, depth: Int)] {
        func walk(_ nodes: [FileNode], _ d: Int) -> [(FileNode, Int)] {
            nodes.flatMap { n -> [(FileNode, Int)] in
                [(n, d)] + (n.isDirectory && expanded.contains(n.path) ? walk(n.children ?? [], d + 1) : [])
            }
        }
        return walk(project.tree, 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { promptText = ""; prompt = Prompt(kind: .newFile, dir: "", path: "") } label: { Image(systemName: "doc.badge.plus") }
                Button { promptText = ""; prompt = Prompt(kind: .newFolder, dir: "", path: "") } label: { Image(systemName: "folder.badge.plus") }
                Button { importDir = ""; importing = true } label: { Image(systemName: "square.and.arrow.down") }
                Button { project.refreshFromDisk() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 6).font(.system(size: 16))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.node.id) { row in rowView(row.node, row.depth) }
                }
                // dropping on empty area moves to root
                Color.clear.frame(height: 80).dropDestination(for: String.self) { items, _ in
                    for i in items { project.move(i, to: (i as NSString).lastPathComponent) }; return true
                }
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("OK") { commitPrompt() }
        }
        .confirmationDialog("Delete \((pendingDelete ?? "") as NSString).lastPathComponent)?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let p = pendingDelete { project.delete(p) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This can't be undone.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { project.importFiles(urls, into: importDir) }
        }
    }

    private var promptTitle: String {
        switch prompt?.kind { case .newFile: "New File"; case .newFolder: "New Folder"; case .rename: "Rename"; case nil: "" }
    }

    private func commitPrompt() {
        guard let p = prompt, !promptText.isEmpty else { return }
        switch p.kind {
        case .newFile:
            var name = promptText
            if (name as NSString).pathExtension.isEmpty { name += ".tex" }
            project.createFile(in: p.dir, name: name, contents: name.hasSuffix(".tex") ? "" : "")
        case .newFolder: project.createFolder(in: p.dir, name: promptText)
        case .rename: project.rename(p.path, to: promptText)
        }
    }

    @ViewBuilder private func rowView(_ n: FileNode, _ depth: Int) -> some View {
        let isActive = project.active == n.path
        let isMain = project.mainName == n.path
        HStack(spacing: 6) {
            Image(systemName: n.isDirectory ? (expanded.contains(n.path) ? "chevron.down" : "chevron.right") : "").font(.system(size: 10, weight: .bold))
                .frame(width: 12).foregroundStyle(.secondary)
            Image(systemName: icon(n)).foregroundStyle(color(n)).frame(width: 20)
            Text(n.name).lineLimit(1).font(.system(size: 15))
            if isMain { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            if project.dirty.contains(n.path) { Circle().fill(Color.secondary).frame(width: 7, height: 7) }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8).padding(.vertical, 7).padding(.trailing, 8)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if n.isDirectory { if expanded.contains(n.path) { expanded.remove(n.path) } else { expanded.insert(n.path) } }
            else { project.open(n.path) }
        }
        .draggable(n.path)
        .dropDestination(for: String.self) { items, _ in
            let dir = n.isDirectory ? n.path : (n.path as NSString).deletingLastPathComponent
            for i in items { project.move(i, to: dir.isEmpty ? (i as NSString).lastPathComponent : dir + "/" + (i as NSString).lastPathComponent) }
            return true
        }
        .contextMenu {
            let dir = n.isDirectory ? n.path : (n.path as NSString).deletingLastPathComponent
            Button { promptText = ""; prompt = Prompt(kind: .newFile, dir: dir, path: n.path); if n.isDirectory { expanded.insert(n.path) } } label: { Label("New File", systemImage: "doc.badge.plus") }
            Button { promptText = ""; prompt = Prompt(kind: .newFolder, dir: dir, path: n.path) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { importDir = dir; importing = true } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
            Divider()
            if n.ext == "tex" { Button { project.setMainFile(n.path) } label: { Label("Set as Main File", systemImage: "star") } }
            Button { promptText = n.name; prompt = Prompt(kind: .rename, dir: dir, path: n.path) } label: { Label("Rename", systemImage: "pencil") }
            if !n.isDirectory { Button { project.duplicate(n.path) } label: { Label("Duplicate", systemImage: "plus.square.on.square") } }
            Button(role: .destructive) { pendingDelete = n.path } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func icon(_ n: FileNode) -> String {
        if n.isDirectory { return expanded.contains(n.path) ? "folder.fill" : "folder" }
        switch n.ext {
        case "tex": return "doc.text"
        case "bib": return "books.vertical"
        case "sty", "cls", "bst": return "puzzlepiece"
        case "pdf": return "doc.richtext"
        case _ where FileKind.imageExts.contains(n.ext): return "photo"
        default: return "doc"
        }
    }
    private func color(_ n: FileNode) -> Color {
        if n.isDirectory { return .blue }
        switch n.ext { case "tex": return .green; case "bib": return .orange; case "sty", "cls": return .purple; case "pdf": return .red; default: return .secondary }
    }
}

// MARK: - Search

struct SearchView: View {
    @ObservedObject var project: Project
    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var regex = false
    @State private var wholeWord = false
    @State private var showReplace = false
    @State private var results: [SearchMatch] = []
    @State private var searchTask: Task<Void, Never>?

    var grouped: [(String, [SearchMatch])] {
        Dictionary(grouping: results, by: \.path).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit(run)
                toggle("textformat", $caseSensitive); toggle("w.circle", $wholeWord); toggle("asterisk", $regex)
            }
            if showReplace {
                HStack {
                    TextField("Replace", text: $replacement).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("All") {
                        let n = project.replaceAll(query, with: replacement, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
                        project.toast = "Replaced in \(n) file\(n == 1 ? "" : "s")"; run()
                    }.buttonStyle(.bordered).disabled(query.isEmpty)
                }
            }
            HStack {
                Button { showReplace.toggle() } label: { Label(showReplace ? "Hide Replace" : "Replace", systemImage: "arrow.left.arrow.right") }.font(.caption)
                Spacer()
                Text("\(results.count) result\(results.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(grouped, id: \.0) { path, matches in
                    Section(path) {
                        ForEach(matches) { m in
                            Button { project.open(m.path, line: m.line, col: m.column) } label: {
                                HStack(alignment: .top) {
                                    Text("\(m.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                                    Text(highlighted(m)).font(.system(size: 13, design: .monospaced)).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.plain)
        }
        .padding(.horizontal, 10)
        .onChange(of: query) { _, _ in debounce() }
        .onChange(of: caseSensitive) { _, _ in run() }
        .onChange(of: regex) { _, _ in run() }
        .onChange(of: wholeWord) { _, _ in run() }
    }

    private func toggle(_ icon: String, _ b: Binding<Bool>) -> some View {
        Button { b.wrappedValue.toggle() } label: {
            Image(systemName: icon).frame(width: 30, height: 30)
                .background(b.wrappedValue ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    private func debounce() {
        searchTask?.cancel()
        searchTask = Task { try? await Task.sleep(nanoseconds: 250_000_000); if !Task.isCancelled { run() } }
    }
    private func run() { results = project.search(query, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord) }

    private func highlighted(_ m: SearchMatch) -> AttributedString {
        var a = AttributedString(m.text)
        if let r = m.matchRange, r.upperBound <= m.text.count {
            let s = a.index(a.startIndex, offsetByCharacters: r.lowerBound), e = a.index(a.startIndex, offsetByCharacters: r.upperBound)
            a[s..<e].backgroundColor = .yellow.opacity(0.4)
        }
        return a
    }
}

// MARK: - Outline

struct OutlineView: View {
    @ObservedObject var project: Project
    var body: some View {
        if project.index.outline.isEmpty {
            VStack { Spacer(); Text("No sections found").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
        } else {
            List(project.index.outline) { item in
                Button { project.open(item.path, line: item.line) } label: {
                    HStack {
                        Text(item.title.isEmpty ? "(untitled)" : item.title)
                            .font(.system(size: item.level <= 1 ? 15 : 14, weight: item.level <= 2 ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        Text("\(item.line)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.leading, CGFloat(max(0, item.level - 1)) * 14)
                }.buttonStyle(.plain)
            }.listStyle(.plain)
        }
    }
}

// MARK: - Symbols & snippets

struct SymbolsView: View {
    @ObservedObject var project: Project

    struct Snip: Identifiable { let id = UUID(); let title: String; let icon: String; let tpl: String }
    static let snippets: [Snip] = [
        .init(title: "Itemize", icon: "list.bullet", tpl: "\\begin{itemize}\n\t\\item ${1}\n\\end{itemize}"),
        .init(title: "Enumerate", icon: "list.number", tpl: "\\begin{enumerate}\n\t\\item ${1}\n\\end{enumerate}"),
        .init(title: "Equation", icon: "function", tpl: "\\begin{equation}\n\t${1}\n\\end{equation}"),
        .init(title: "Align", icon: "equal", tpl: "\\begin{align}\n\t${1} &= ${2} \\\\\n\\end{align}"),
        .init(title: "Figure", icon: "photo", tpl: "\\begin{figure}[htbp]\n\t\\centering\n\t\\includegraphics[width=0.8\\textwidth]{${1}}\n\t\\caption{${2}}\n\t\\label{fig:${3}}\n\\end{figure}"),
        .init(title: "Table", icon: "tablecells", tpl: "\\begin{table}[htbp]\n\t\\centering\n\t\\begin{tabular}{${1:lcc}}\n\t\t\\toprule\n\t\t${2} \\\\\n\t\t\\midrule\n\t\t${3} \\\\\n\t\t\\bottomrule\n\t\\end{tabular}\n\t\\caption{${4}}\n\t\\label{tab:${5}}\n\\end{table}"),
        .init(title: "Matrix", icon: "square.grid.2x2", tpl: "\\begin{pmatrix}\n\t${1} & ${2} \\\\\n\t${3} & ${4}\n\\end{pmatrix}"),
        .init(title: "Cases", icon: "curlybraces", tpl: "\\begin{cases}\n\t${1} & \\text{if } ${2} \\\\\n\t${3} & \\text{otherwise}\n\\end{cases}"),
        .init(title: "Theorem", icon: "t.square", tpl: "\\begin{theorem}\\label{thm:${1}}\n\t${2}\n\\end{theorem}"),
        .init(title: "Proof", icon: "checkmark.square", tpl: "\\begin{proof}\n\t${1}\n\\end{proof}"),
        .init(title: "TikZ", icon: "scribble", tpl: "\\begin{tikzpicture}\n\t\\draw (0,0) -- (${1:2},${2:1});\n\\end{tikzpicture}"),
        .init(title: "Code listing", icon: "chevron.left.forwardslash.chevron.right", tpl: "\\begin{lstlisting}[language=${1:Python}]\n${2}\n\\end{lstlisting}"),
        .init(title: "Beamer frame", icon: "rectangle.on.rectangle", tpl: "\\begin{frame}{${1}}\n\t${2}\n\\end{frame}"),
        .init(title: "Article preamble", icon: "doc.text", tpl: "\\documentclass[11pt]{article}\n\\usepackage[utf8]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage{amsmath,amssymb}\n\\usepackage{graphicx}\n\\usepackage[margin=1in]{geometry}\n\\usepackage{hyperref}\n\n\\title{${1}}\n\\author{${2}}\n\n\\begin{document}\n\\maketitle\n${3}\n\\end{document}\n"),
    ]
    static let groups: [(String, [(String, String)])] = [
        ("Greek", [("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"), ("ε", "\\epsilon"), ("ζ", "\\zeta"), ("η", "\\eta"), ("θ", "\\theta"), ("λ", "\\lambda"), ("μ", "\\mu"), ("π", "\\pi"), ("ρ", "\\rho"), ("σ", "\\sigma"), ("τ", "\\tau"), ("φ", "\\phi"), ("χ", "\\chi"), ("ψ", "\\psi"), ("ω", "\\omega"), ("Γ", "\\Gamma"), ("Δ", "\\Delta"), ("Θ", "\\Theta"), ("Λ", "\\Lambda"), ("Σ", "\\Sigma"), ("Φ", "\\Phi"), ("Ψ", "\\Psi"), ("Ω", "\\Omega")]),
        ("Operators", [("±", "\\pm"), ("×", "\\times"), ("÷", "\\div"), ("·", "\\cdot"), ("∑", "\\sum"), ("∏", "\\prod"), ("∫", "\\int"), ("∂", "\\partial"), ("∇", "\\nabla"), ("√", "\\sqrt{}"), ("∞", "\\infty"), ("∪", "\\cup"), ("∩", "\\cap"), ("⊕", "\\oplus"), ("⊗", "\\otimes")]),
        ("Relations", [("≤", "\\leq"), ("≥", "\\geq"), ("≠", "\\neq"), ("≈", "\\approx"), ("≡", "\\equiv"), ("∼", "\\sim"), ("∝", "\\propto"), ("∈", "\\in"), ("∉", "\\notin"), ("⊂", "\\subset"), ("⊆", "\\subseteq"), ("∀", "\\forall"), ("∃", "\\exists"), ("¬", "\\neg"), ("∧", "\\wedge"), ("∨", "\\vee")]),
        ("Arrows", [("→", "\\to"), ("←", "\\leftarrow"), ("↔", "\\leftrightarrow"), ("⇒", "\\Rightarrow"), ("⇐", "\\Leftarrow"), ("⇔", "\\Leftrightarrow"), ("↦", "\\mapsto"), ("↑", "\\uparrow"), ("↓", "\\downarrow")]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Snippets").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(Self.snippets) { s in
                        Button { project.editor.insertSnippet(s.tpl) } label: {
                            VStack(spacing: 4) { Image(systemName: s.icon).font(.system(size: 18)); Text(s.title).font(.caption).lineLimit(1) }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                ForEach(Self.groups, id: \.0) { name, items in
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                        ForEach(items, id: \.1) { glyph, cmd in
                            Button { project.editor.insert(cmd) } label: {
                                Text(glyph).font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 38)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(10)
        }
    }
}
