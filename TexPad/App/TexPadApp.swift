// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

@main
struct TexPadApp: App {
    @StateObject private var store = ProjectStore()
    @Environment(\.scenePhase) private var phase
    @AppStorage("theme") private var theme = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
                #if DEBUG
                .task { if AutoTest.path != nil { _ = await store.engine.prepare(); await AutoTest.run(engine: store.engine) } }
                #endif
                .onChange(of: phase) { _, p in
                    if p == .active { store.project?.refreshFromDisk() }
                    if p == .background { store.project?.saveAll() }
                }
        }
    }
}
