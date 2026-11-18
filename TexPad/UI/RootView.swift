// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

struct WebHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Re-renders when the engine swaps in a fresh web view after a crash or timeout.
struct EngineHost: View {
    @ObservedObject var engine: TeXEngine
    var body: some View { WebHost(view: engine.webView).id(ObjectIdentifier(engine.webView)) }
}

struct RootView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        ZStack {
            if let project = store.project {
                IDEView(project: project)
                    .id(project.root)
            } else {
                WelcomeView()
            }
            // The TeX engine lives in an off-screen web view that must stay in the view hierarchy.
            EngineHost(engine: store.engine).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
        .alert("Couldn't open project", isPresented: Binding(get: { store.openError != nil }, set: { if !$0 { store.openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.openError ?? "") }
    }
}
