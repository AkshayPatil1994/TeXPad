// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

struct SettingsView: View {
    @ObservedObject var project: Project
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = "system"
    @AppStorage("fontSize") private var fontSize = 15
    @AppStorage("wrap") private var wrap = true
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("autoBuild") private var autoBuild = true
    @State private var main: String = ""
    @EnvironmentObject private var store: ProjectStore
    @State private var extrasCount = 0
    @AppStorage("gitName") private var gitName = ""
    @AppStorage("gitEmail") private var gitEmail = ""
    @State private var tokenHosts: [String] = []
    @State private var addToken = false

    private var texFiles: [String] { FileTree.flatten(project.tree).filter { $0.ext == "tex" }.map(\.path) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    Stepper("Font size: \(fontSize)", value: $fontSize, in: 10...28)
                    Toggle("Word wrap", isOn: $wrap)
                }
                Section("Editing") {
                    Toggle("Autosave", isOn: $autoSave)
                    Toggle("Build automatically after saving", isOn: $autoBuild)
                }
                Section("Project: \(project.name)") {
                    NavigationLink { RecipeEditorView(project: project) } label: {
                        HStack { Text("Build recipe"); Spacer(); Text(project.effectiveRecipe().name).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Picker("Main file", selection: $main) {
                        Text("Automatic").tag("")
                        ForEach(texFiles, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: main) { _, v in project.setMainFile(v.isEmpty ? nil : v); project.rebuildIndex() }
                    Text("Output goes to \(project.settings.outputDir)/ inside the project.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Name", text: $gitName).textInputAutocapitalization(.words).autocorrectionDisabled()
                    TextField("Email", text: $gitEmail).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    ForEach(tokenHosts, id: \.self) { h in
                        Label("Token saved for \(h)", systemImage: "key.fill")
                            .swipeActions { Button("Remove", role: .destructive) { GitCredentialStore.delete(host: h); tokenHosts = GitCredentialStore.hosts() } }
                    }
                    Button { addToken = true } label: { Label("Add access token…", systemImage: "plus") }
                } header: { Text("Git") } footer: {
                    Text("Name and email are written into your commits (use a no-reply address if you will publish them). Tokens live in the iOS Keychain and are only sent to their own host over HTTPS.")
                }
                Section("Extra TeX files") {
                    Text("Missing a package or font? Copy the .sty / .cls / .bst / .tfm files into TexPad/TeXExtras in the Files app (On My iPad), then rescan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Rescan TeX extras (\(extrasCount) files)") { extrasCount = store.engine.handler.rescanExtras() }
                }
                Section("About") {
                    Text("TexPad compiles LaTeX on-device with pdfTeX (SwiftLaTeX WebAssembly build) and an offline TeX Live subset. Editor: CodeMirror 6.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Limits: pdfLaTeX + BibTeX only (no biber/LuaTeX/XeTeX); stops at the first TeX error; PDF↔source jumps are text-based, not SyncTeX.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { main = project.settings.mainFile ?? ""; extrasCount = store.engine.handler.extrasCount; tokenHosts = GitCredentialStore.hosts() }
            .sheet(isPresented: $addToken, onDismiss: { tokenHosts = GitCredentialStore.hosts() }) { GitTokenSheet(host: "github.com") }
        }
    }
}
