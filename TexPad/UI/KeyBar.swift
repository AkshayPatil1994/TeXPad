// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import SwiftUI

/// Tracks the on-screen keyboard. A hardware keyboard shows only the small shortcut bar, which we ignore.
final class KeyboardObserver: ObservableObject {
    @Published var frame: CGRect = .zero
    var visible: Bool { frame.height > 150 }
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            self?.frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.frame = .zero
        })
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}

/// LaTeX-specific keys that are awkward on the iPadOS soft keyboard.
struct KeyBar: View {
    @ObservedObject var project: Project

    private let keys: [(label: String, snippet: String)] = [
        ("⇥", "\t"),
        ("\\", "\\"),
        ("{ }", "{${1}}"),
        ("[ ]", "[${1}]"),
        ("$ $", "$${1}$"),
        ("( )", "(${1})"),
        ("&", "&"),
        ("^", "^{${1}}"),
        ("_", "_{${1}}"),
        ("%", "%"),
        ("~", "~"),
        ("\\\\", "\\\\\n"),
        ("\\begin", "\\begin{${1}}\n\t${2}\n\\end{${1}}"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.label) { key in
                    Button { project.editor.insertSnippet(key.snippet) } label: {
                        Text(key.label)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 4)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 24)
                Button { project.editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                Button { project.editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                Button { project.build() } label: { Image(systemName: "play.fill") }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
    }
}
