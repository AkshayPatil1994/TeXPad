// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI
import UniformTypeIdentifiers

/// Clone a repository from an https:// URL into TexPad's folder (visible in Files) or a folder the user picks.
struct CloneSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var username = "git"
    @State private var parent: URL?
    @State private var picking = false
    @State private var progress: Double?
    @State private var status = ""
    @State private var error: String?
    @State private var cloning = false
    @State private var cancel = GitCancelToken()

    private var host: String { URL(string: url.trimmingCharacters(in: .whitespaces))?.host ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repo.git", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Repository URL") } footer: { Text("HTTPS only. SSH (git@…) URLs aren't supported yet.") }

                Section {
                    if !host.isEmpty, GitCredentialStore.load(host: host) != nil {
                        Label("A token for \(host) is already saved", systemImage: "key.fill").foregroundStyle(.green)
                    }
                    TextField("Username (any for GitHub)", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Personal access token (private repositories)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Access (optional for public repositories)") } footer: {
                    Text("Stored in the iOS Keychain and sent only to \(host.isEmpty ? "that host" : host) over HTTPS.")
                }

                Section("Clone into") {
                    Label(parent == nil ? "TexPad folder (Files › On My iPad › TexPad)" : parent!.lastPathComponent, systemImage: "folder")
                    Button("Choose another folder…") { picking = true }
                    if parent != nil { Button("Use the TexPad folder") { parent = nil } }
                }

                if cloning {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(status.isEmpty ? "Connecting…" : status).font(.caption)
                            if let p = progress { ProgressView(value: min(1, max(0, p))) } else { ProgressView() }
                            Button("Cancel", role: .destructive) { cancel.cancel() }
                        }
                    }
                }
                if let e = error { Section { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .navigationTitle("Clone Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { cancel.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") { Task { await clone() } }.disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || cloning)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { parent = u } }
        }
    }

    private func clone() async {
        error = nil; cloning = true; cancel = GitCancelToken(); progress = nil; status = ""
        defer { cloning = false }
        do {
            try await store.cloneRepository(urlString: url, username: username, token: token, parent: parent, cancel: cancel) { p, text in
                Task { @MainActor in progress = p; status = text }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
