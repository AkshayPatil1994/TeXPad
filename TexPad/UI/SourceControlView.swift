// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

struct SourceControlView: View {
    @ObservedObject var project: Project
    @ObservedObject var git: GitModel
    @State private var newBranchName = ""
    @State private var askNewBranch = false
    @State private var remoteDraft = ""
    @State private var askRemote = false
    @State private var showToken = false
    @State private var pendingDiscard: GitFileChange?

    var body: some View {
        Group {
            if !git.isRepo { notARepo } else { repoView }
        }
        .sheet(isPresented: $showToken) { GitTokenSheet(host: git.remoteHost ?? "github.com") }
        .onChange(of: git.needsTokenForHost) { _, h in if h != nil { showToken = true; git.needsTokenForHost = nil } }
        .alert("New branch", isPresented: $askNewBranch) {
            TextField("branch-name", text: $newBranchName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") { let n = newBranchName; Task { await git.createBranch(n) } }
        } message: { Text("Created from the current commit and checked out.") }
        .alert("Remote URL", isPresented: $askRemote) {
            TextField("https://github.com/owner/repo.git", text: $remoteDraft).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Save") { let u = remoteDraft; Task { await git.setRemote(u) } }
        } message: { Text("HTTPS URL of the repository (named “origin”). Access tokens are stored separately in the Keychain.") }
        .confirmationDialog("Discard changes to \((pendingDiscard?.path ?? "") as NSString).lastPathComponent)?",
                            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { if let c = pendingDiscard { Task { await git.discard(c) } }; pendingDiscard = nil }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { Text(pendingDiscard?.unstaged == .untracked ? "The new file will be deleted. This can't be undone." : "Your edits will be lost. This can't be undone.") }
    }

    // MARK: not a repository

    private var notARepo: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("This folder isn't a git repository").font(.callout).multilineTextAlignment(.center)
            Button { Task { await git.initialize() } } label: { Label("Initialize Repository", systemImage: "plus.circle").lineLimit(1).fixedSize() }
                .buttonStyle(PillButtonStyle(prominent: true))
            Text("Creates a repository here and a .gitignore for LaTeX build files. To work with a repository from GitHub, use “Clone Repository” on the start screen.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            errorBanner
            Spacer()
        }.padding(16)
    }

    // MARK: repository

    private var repoView: some View {
        List {
            Section { header }
            if let msg = git.lastError { Section { Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
            if git.busy != nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(git.busy ?? "").font(.caption).lineLimit(2)
                        if let p = git.progress { ProgressView(value: min(1, max(0, p))) } else { ProgressView() }
                    }
                }
            }
            Section("Commit") {
                TextField("Message", text: $git.commitMessage, axis: .vertical).lineLimit(1...5)
                HStack {
                    Button { Task { await git.commit() } } label: { Label("Commit", systemImage: "checkmark").lineLimit(1).fixedSize() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(git.stagedChanges.isEmpty || git.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || git.busy != nil)
                    if let oid = git.lastOID { Text("✓ \(oid)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                if git.identity.name.isEmpty || !git.identity.email.contains("@") {
                    Label("Set your name and email in Settings → Git before committing.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if !git.stagedChanges.isEmpty {
                Section {
                    ForEach(git.stagedChanges) { c in row(c, staged: true) }
                } header: {
                    HStack { Text("Staged Changes (\(git.stagedChanges.count))"); Spacer()
                        Button("Unstage All") { Task { await git.unstageAll() } }.font(.caption) }
                }
            }
            Section {
                if git.unstagedChanges.isEmpty && git.stagedChanges.isEmpty { Text("No changes").foregroundStyle(.secondary).font(.callout) }
                ForEach(git.unstagedChanges) { c in row(c, staged: false) }
            } header: {
                HStack { Text("Changes (\(git.unstagedChanges.count))"); Spacer()
                    if !git.unstagedChanges.isEmpty { Button("Stage All") { Task { await git.stageAll() } }.font(.caption) } }
            }
            Section("Remote") {
                if let u = git.remoteURL { Text(u).font(.caption).textSelection(.enabled).lineLimit(2) } else { Text("No remote").foregroundStyle(.secondary) }
                Button { remoteDraft = git.remoteURL ?? ""; askRemote = true } label: { Label(git.remoteURL == nil ? "Add Remote…" : "Change Remote…", systemImage: "link") }
                if git.remoteURL != nil {
                    Button { showToken = true } label: { Label("Access Token…", systemImage: "key") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await git.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    let locals = git.branches.filter { !$0.isRemote }
                    let remotes = git.branches.filter { r in r.isRemote && !locals.contains(where: { l in "origin/" + l.name == r.name }) }
                    ForEach(locals) { b in
                        Button { Task { await git.checkout(b.name) } } label: {
                            if b.isCurrent { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
                        }
                    }
                    if !remotes.isEmpty { Divider(); Text("Remote branches") }
                    ForEach(remotes) { b in Button(b.name) { Task { await git.checkout(b.name) } } }
                    Divider()
                    Button { newBranchName = ""; askNewBranch = true } label: { Label("New Branch…", systemImage: "plus") }
                } label: {
                    Label(git.status.detached ? "detached HEAD" : (git.status.branch ?? "no branch"), systemImage: "arrow.triangle.branch")
                        .font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                if git.status.ahead > 0 { Label("\(git.status.ahead)", systemImage: "arrow.up").font(.caption) }
                if git.status.behind > 0 { Label("\(git.status.behind)", systemImage: "arrow.down").font(.caption) }
            }
            HStack(spacing: 10) {
                syncButton("Fetch", "arrow.triangle.2.circlepath") { await git.fetch() }
                syncButton("Pull", "arrow.down.circle") {
                    if let r = await git.pull() { project.toast = r == .upToDate ? "Already up to date" : "Pulled the latest changes" }
                }
                syncButton("Push", "arrow.up.circle") { await git.push(); if git.lastError == nil { project.toast = "Pushed" } }
            }
        }
    }

    private func syncButton(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 18)); Text(title).font(.caption2).lineLimit(1) }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle())
        .disabled(git.busy != nil || git.remoteURL == nil)
    }

    private func row(_ c: GitFileChange, staged: Bool) -> some View {
        let kind = staged ? c.staged : c.unstaged
        return HStack(spacing: 8) {
            Text(kind?.mark ?? "").font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color(kind)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text((c.path as NSString).lastPathComponent).font(.system(size: 14)).lineLimit(1)
                let dir = (c.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if staged {
                Button { Task { await git.unstage(c) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            } else {
                Button { pendingDiscard = c } label: { Image(systemName: "arrow.uturn.backward.circle") }.buttonStyle(.borderless).foregroundStyle(.red)
                Button { Task { await git.stage(c) } } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if kind != .deleted { project.open(c.path) } }
    }

    private func color(_ k: GitChangeKind?) -> Color {
        switch k { case .added, .untracked: return .green; case .modified, .renamed, .typeChange: return .orange; case .deleted, .conflicted: return .red; case nil: return .secondary }
    }

    @ViewBuilder private var errorBanner: some View {
        if let e = git.lastError { Text(e).font(.caption).foregroundStyle(.red) }
    }
}

// MARK: - token sheet

struct GitTokenSheet: View {
    @State var host: String
    @State private var username = "git"
    @State private var token = ""
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(host: String) { _host = State(initialValue: host) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Personal access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Create a personal access token on your host (GitHub: Settings → Developer settings → Personal access tokens, with “repo” access). It is stored in the iOS Keychain on this device only and sent only to \(host.isEmpty ? "this host" : host) over HTTPS. For GitHub any username works.")
                }
                if GitCredentialStore.load(host: host) != nil {
                    Section { Button("Remove saved token for \(host)", role: .destructive) { GitCredentialStore.delete(host: host); saved = false } }
                }
            }
            .navigationTitle("Access token")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let h = host.trimmingCharacters(in: .whitespaces)
                        if !h.isEmpty, !token.isEmpty, GitCredentialStore.save(GitCredential(username: username.isEmpty ? "git" : username, token: token), host: h) { dismiss() }
                    }.disabled(host.isEmpty || token.isEmpty)
                }
            }
        }
    }
}


/// Rounded button that behaves inside List rows (system bordered styles collapse into circles there).
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(!enabled ? Color.secondary : (prominent ? Color.white : Color.accentColor))
            .background((!enabled ? Color(.tertiarySystemFill) : (prominent ? Color.accentColor : Color.accentColor.opacity(0.14)))
                            .opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
    }
}
