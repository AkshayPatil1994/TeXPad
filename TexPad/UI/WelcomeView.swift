// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var picking = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TexPad").font(.system(size: 44, weight: .bold))
                    Text("LaTeX that compiles on your iPad, offline.").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button { picking = true } label: { Label("Open Folder…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { store.openSample("Thesis") } label: { Label("Open Sample Project", systemImage: "doc.text") }
                        .buttonStyle(.bordered).controlSize(.large)
                    Button { store.openSample("Manuscript") } label: { Label("Open Sample Manuscript (many packages)", systemImage: "doc.richtext") }
                        .buttonStyle(.bordered).controlSize(.large)
                    Button { store.openSample("XeLaTeX") } label: { Label("Open Sample XeLaTeX (fontspec, Unicode)", systemImage: "textformat") }
                        .buttonStyle(.bordered).controlSize(.large)
                    Button { store.openSample("Broken") } label: { Label("Open Sample With Errors", systemImage: "exclamationmark.triangle") }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                engineStatus
                Spacer()
            }
            .padding(40).frame(maxWidth: 460, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Recent").font(.headline)
                if store.recents.isEmpty {
                    Text("Projects you open will appear here.").foregroundStyle(.secondary)
                } else {
                    List(store.recents) { r in
                        Button { store.open(recent: r) } label: {
                            VStack(alignment: .leading) {
                                Text(r.name).font(.body.weight(.medium))
                                Text(r.lastOpened, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.listStyle(.plain)
                }
                Spacer()
            }
            .padding(40).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(.systemBackground))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.open(url: url) }
        }
    }

    @ViewBuilder private var engineStatus: some View {
        switch store.engine.status {
        case .idle, .loading: Label("Starting LaTeX engine…", systemImage: "gearshape").foregroundStyle(.secondary)
        case .buildingFormat: Label("Preparing LaTeX (first launch only)…", systemImage: "gearshape.2").foregroundStyle(.secondary)
        case .ready: Label("LaTeX engine ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let e): Label("Engine failed: \(e.prefix(120))", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
