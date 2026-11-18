// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import PDFKit

struct EditorArea: View {
    @ObservedObject var project: Project
    @ObservedObject var pdf: PDFController

    private var activeNode: FileNode? { FileTree.flatten(project.tree).first { $0.path == project.active } }
    private var showEditor: Bool { project.active != nil && (activeNode?.isText ?? true) }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(project: project)
            ZStack(alignment: .bottom) {
                WebHost(view: project.editor.webView).opacity(showEditor ? 1 : 0).allowsHitTesting(showEditor)
                if let n = activeNode, !n.isText { viewer(n) }
                if project.active == nil { EmptyEditor(project: project) }
            }
        }
    }

    @ViewBuilder private func viewer(_ n: FileNode) -> some View {
        if n.isImage, let img = UIImage(contentsOfFile: project.url(n.path).path) {
            ScrollView([.horizontal, .vertical]) { Image(uiImage: img).resizable().scaledToFit().padding() }.background(Color(.secondarySystemBackground))
        } else if n.isPDF, let d = try? Data(contentsOf: project.url(n.path)) {
            PDFKitView(data: d, controller: nil)
        } else {
            VStack(spacing: 8) { Image(systemName: "doc.questionmark").font(.largeTitle); Text("Can't preview \(n.name)").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
        }
    }
}

struct EmptyEditor: View {
    @ObservedObject var project: Project
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.cursor").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Open a file from the Explorer").font(.title3).foregroundStyle(.secondary)
            Text("⌘P Go to File   ⇧⌘P Commands   ⌘B Build").font(.callout).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
    }
}

struct TabBar: View {
    @ObservedObject var project: Project
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(project.tabs, id: \.self) { path in
                    let active = project.active == path
                    HStack(spacing: 6) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 14)).lineLimit(1)
                        if project.dirty.contains(path) { Circle().fill(Color.primary.opacity(0.6)).frame(width: 8, height: 8) }
                        Button { project.close(path) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(active ? Color(.systemBackground) : Color(.secondarySystemBackground))
                    .overlay(alignment: .top) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { project.open(path) }
                    Divider().frame(height: 22)
                }
            }
        }
        .frame(height: 36)
        .background(Color(.secondarySystemBackground))
    }
}

struct BottomPanel: View {
    @ObservedObject var project: Project
    @Binding var tab: BottomTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 260)
                Spacer()
                if tab == .problems { Text("\(project.errorCount) errors, \(project.warningCount) warnings").font(.caption).foregroundStyle(.secondary) }
            }.padding(8).background(Color(.secondarySystemBackground))
            Divider()
            if tab == .problems { problems } else { log }
        }
    }

    private var problems: some View {
        Group {
            if project.diagnostics.isEmpty {
                VStack { Spacer(); Text(project.buildState == .idle ? "Build to check for problems" : "No problems").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
            } else {
                List(project.diagnostics.sorted { $0.severity.rawValue < $1.severity.rawValue }) { d in
                    Button { project.jump(to: d) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(d.severity == .error ? .red : d.severity == .warning ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.message).font(.system(size: 14)).lineLimit(3)
                                HStack(spacing: 6) {
                                    if let f = d.file { Text((f as NSString).lastPathComponent + (d.line.map { ":\($0)" } ?? "")).font(.caption).foregroundStyle(.secondary) }
                                    if let c = d.context, !c.isEmpty { Text(c).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                            }
                        }
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }
    }

    private var log: some View {
        ScrollView {
            Text(project.buildLog.isEmpty ? "No build yet." : project.buildLog)
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.background(Color(.systemBackground))
    }
}
