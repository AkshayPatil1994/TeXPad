// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

/// Lists built-in recipes (read-only, duplicable) and the project's custom recipes.
struct RecipeEditorView: View {
    @ObservedObject var project: Project
    @State private var customs: [BuildRecipe] = []

    var body: some View {
        List {
            Section("Built-in") {
                ForEach(BuildRecipe.builtIns) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name)
                        Text(Self.summary(r)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Duplicate") { duplicate(r) }.tint(.blue) }
                    .contextMenu { Button("Duplicate as custom recipe") { duplicate(r) } }
                }
            }
            Section("Custom") {
                if customs.isEmpty { Text("None yet. Duplicate a built-in recipe or create a new one.").font(.caption).foregroundStyle(.secondary) }
                ForEach($customs) { $r in
                    NavigationLink { RecipeDetailView(recipe: $r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            Text(Self.summary(r)).font(.caption).foregroundStyle(r.validated() == nil ? .red : .secondary)
                        }
                    }
                }
                .onDelete { customs.remove(atOffsets: $0) }
                Button { customs.append(.newCustom()) } label: { Label("New recipe", systemImage: "plus") }
            }
        }
        .navigationTitle("Build recipes")
        .toolbar { EditButton() }
        .onAppear { customs = project.settings.recipes }
        .onChange(of: customs) { _, v in project.saveRecipes(v) }
    }

    private func duplicate(_ r: BuildRecipe) {
        var copy = BuildRecipe.newCustom(named: r.name + " copy")
        copy.steps = r.steps.map { BuildStep($0.tool, onlyIfNeeded: $0.onlyIfNeeded) }
        customs.append(copy)
    }

    static func summary(_ r: BuildRecipe) -> String {
        r.steps.map { $0.tool == .bibtex && $0.onlyIfNeeded ? "BibTeX (if needed)" : $0.tool.title }.joined(separator: " → ")
    }
}

struct RecipeDetailView: View {
    @Binding var recipe: BuildRecipe

    var body: some View {
        Form {
            Section("Name") { TextField("Recipe name", text: $recipe.name) }
            Section {
                ForEach($recipe.steps) { $step in
                    HStack {
                        Picker("Tool", selection: $step.tool) { ForEach(BuildTool.allCases) { Text($0.title).tag($0) } }
                        if step.tool == .bibtex { Toggle("Only if needed", isOn: $step.onlyIfNeeded).labelsHidden().help("Skip when there are no citations") }
                    }
                }
                .onMove { recipe.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { recipe.steps.remove(atOffsets: $0) }
                if recipe.steps.count < BuildRecipe.maxSteps {
                    Button { recipe.steps.append(BuildStep(.pdflatex)) } label: { Label("Add step", systemImage: "plus") }
                }
            } header: { Text("Steps (top to bottom)") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecipeEditorView.summary(recipe))
                    if recipe.validated() == nil { Text("A recipe needs 1–\(BuildRecipe.maxSteps) steps and at least one LaTeX step, otherwise it is ignored.").foregroundStyle(.red) }
                    Text("“Rerun if needed” repeats the previous LaTeX step (up to \(RecipeRunner.maxReruns)×) while the log asks for another run. BibTeX failures don't stop the build.")
                }
            }
        }
        .navigationTitle(recipe.name)
        .toolbar { EditButton() }
    }
}
