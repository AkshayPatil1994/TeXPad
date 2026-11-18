// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

#if DEBUG
import Foundation

/// Headless build of a project folder, enabled by env IPADTEX_AUTOTEST=<dir> (simulator dev loop).
@MainActor
enum AutoTest {
    static var path: String? { ProcessInfo.processInfo.environment["IPADTEX_AUTOTEST"] }

    static func run(engine: TeXEngine) async {
        guard let path else { return }
        let root = URL(fileURLWithPath: path)
        var files: [String: Data] = [:]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in en {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(u.path.dropFirst(root.path.count + 1))
                if rel.hasPrefix("build/") { continue }
                files[rel] = try? Data(contentsOf: u)
            }
        }
        let main = ProcessInfo.processInfo.environment["IPADTEX_MAIN"] ?? "main.tex"
        do {
            let id = ProcessInfo.processInfo.environment["IPADTEX_RECIPE"] ?? BuildRecipe.default.id
            let recipe = BuildRecipe.builtIns.first { $0.id == id } ?? .default
            var pending: [EngineKind: (files: [String: Data], reset: Bool)] = [:]
            for kind in Set(recipe.steps.compactMap { $0.tool.engine }) { pending[kind] = (files, true) }
            let exec = EngineStepExecutor(engine: engine, pending: pending, timeout: 180)
            let out = try await RecipeRunner(executor: exec).run(recipe, main: main)
            print("[autotest] ok=\(out.ok) ms=\(out.totalMs) passes=\(out.latexRuns) pdf=\(out.pdf?.count ?? 0) recipe=\(recipe.id)")
            if let pdf = out.pdf { try? pdf.write(to: URL(fileURLWithPath: "/tmp/ipadtex-autotest.pdf")) }
            for d in Project.diagnostics(from: out) { print("[autotest] \(d.severity) \(d.file ?? "?"):\(d.line.map(String.init) ?? "?") \(d.message)") }
            if !out.ok || ProcessInfo.processInfo.environment["IPADTEX_VERBOSE"] != nil { print("[autotest] LOG\n\(out.combinedLog)") }
        } catch { print("[autotest] error \(error)") }
        print("[autotest] done")
    }
}

#endif
