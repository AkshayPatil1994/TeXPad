// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

struct TopBar: View {
    @ObservedObject var project: Project
    @EnvironmentObject var store: ProjectStore
    @Binding var sidebarTab: SidebarTab?
    @Binding var showPDF: Bool
    @Binding var showBottom: Bool
    @Binding var palette: PaletteMode?
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button { sidebarTab = sidebarTab == nil ? .explorer : nil } label: { Image(systemName: "sidebar.left") }
            Text(project.name).font(.headline).lineLimit(1)
            if let m = project.mainName { Text("· \(m)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button { palette = .commands } label: {
                HStack { Image(systemName: "command"); Text("Commands").font(.subheadline) }
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            buildButton
            Menu {
                ForEach(project.settings.allRecipes) { r in
                    Button { project.setActiveRecipe(r.id) } label: {
                        if r.id == project.settings.activeRecipeResolved.id { Label(r.name, systemImage: "checkmark") } else { Text(r.name) }
                    }
                }
                Divider()
                Button { showSettings = true } label: { Label("Edit Recipes…", systemImage: "slider.horizontal.3") }
            } label: { Image(systemName: "list.bullet.rectangle") }
            .accessibilityLabel("Build recipe")
            Button { showBottom.toggle() } label: {
                Image(systemName: "exclamationmark.triangle")
                    .symbolVariant(project.errorCount > 0 ? .fill : .none)
                    .foregroundStyle(project.errorCount > 0 ? .red : project.warningCount > 0 ? .orange : .primary)
            }
            Button { showPDF.toggle() } label: { Image(systemName: "doc.richtext").symbolVariant(showPDF ? .fill : .none) }
            Menu {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { store.closeProject() } label: { Label("Close Project", systemImage: "xmark.circle") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var buildButton: some View {
        switch project.buildState {
        case .preparing, .building:
            ProgressView().frame(width: 34)
        default:
            Button { project.build() } label: {
                Label("Build", systemImage: "play.fill").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
            }
        }
    }
}

struct ActivityBar: View {
    @Binding var selection: SidebarTab?
    var problems: Int
    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarTab.allCases) { t in
                Button { selection = selection == t ? nil : t } label: {
                    Image(systemName: t.icon).font(.system(size: 20))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
                        .background(selection == t ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel(t.title)
            }
            Spacer()
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(Color(.secondarySystemBackground))
    }
}

struct StatusBar: View {
    @ObservedObject var project: Project
    @ObservedObject var engine: TeXEngine

    var body: some View {
        HStack(spacing: 16) {
            switch project.buildState {
            case .idle: Label("Ready", systemImage: "checkmark.circle")
            case .preparing: Label("Preparing engine…", systemImage: "gearshape")
            case .building: Label("Building \(project.buildStep ?? "")…", systemImage: "hammer")
            case .succeeded(let ms, let passes): Label("Built in \(ms) ms (\(passes) pass\(passes == 1 ? "" : "es"))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Label("Build failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Label("\(project.errorCount)", systemImage: "xmark.circle").foregroundStyle(project.errorCount > 0 ? .red : .secondary)
            Label("\(project.warningCount)", systemImage: "exclamationmark.triangle").foregroundStyle(project.warningCount > 0 ? .orange : .secondary)
            Spacer()
            if engine.status != .ready { Text(engineText).foregroundStyle(.secondary) }
            if project.active != nil { Text("Ln \(project.cursor.line), Col \(project.cursor.col)") }
            Text("LaTeX")
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
    }

    private var engineText: String {
        switch engine.status {
        case .idle, .loading: return "Engine starting…"
        case .buildingFormat: return "Building format (first launch)…"
        case .failed(let e): return "Engine error: \(e.prefix(60))"
        case .ready: return ""
        }
    }
}
