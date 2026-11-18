// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

enum PaletteMode { case commands, files }

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let icon: String
    let run: () -> Void
    init(_ title: String, _ shortcut: String?, _ icon: String, run: @escaping () -> Void) {
        self.title = title; self.shortcut = shortcut; self.icon = icon; self.run = run
    }
}

struct PaletteView: View {
    let mode: PaletteMode
    @ObservedObject var project: Project
    let dismiss: () -> Void
    let actions: [PaletteAction]
    @State private var query = ""
    @FocusState private var focused: Bool

    private var files: [FileNode] { FileTree.flatten(project.tree).filter { !$0.isDirectory } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: mode == .commands ? "command" : "doc").foregroundStyle(.secondary)
                    TextField(mode == .commands ? "Type a command" : "Go to file", text: $query)
                        .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { pickFirst() }
                }.padding(14)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if mode == .commands {
                            ForEach(filteredActions) { a in
                                Button { dismiss(); a.run() } label: {
                                    HStack { Image(systemName: a.icon).frame(width: 24); Text(a.title); Spacer(); if let s = a.shortcut { Text(s).foregroundStyle(.secondary).font(.caption) } }
                                        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        } else {
                            ForEach(filteredFiles) { f in
                                Button { dismiss(); project.open(f.path) } label: {
                                    HStack { Image(systemName: "doc.text").frame(width: 24); Text(f.name); Text((f.path as NSString).deletingLastPathComponent).foregroundStyle(.secondary).font(.caption); Spacer() }
                                        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxHeight: 380)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 560).padding(.top, 70).shadow(radius: 20)
        }
        .onAppear { focused = true }
    }

    private var filteredActions: [PaletteAction] { query.isEmpty ? actions : actions.filter { Self.fuzzy(query, $0.title) } }
    private var filteredFiles: [FileNode] { query.isEmpty ? files : files.filter { Self.fuzzy(query, $0.path) } }
    private func pickFirst() {
        if mode == .commands, let a = filteredActions.first { dismiss(); a.run() }
        if mode == .files, let f = filteredFiles.first { dismiss(); project.open(f.path) }
    }

    /// Subsequence match, VS Code style.
    static func fuzzy(_ q: String, _ s: String) -> Bool {
        var it = s.lowercased().makeIterator()
        for c in q.lowercased() where c != " " { var found = false; while let x = it.next() { if x == c { found = true; break } }; if !found { return false } }
        return true
    }
}
