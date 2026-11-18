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
            let r = try await engine.build(files: files, main: main, reset: true)
            print("[autotest] ok=\(r.ok) ms=\(r.ms) passes=\(r.passes) pdf=\(r.pdf?.count ?? 0)")
            if let pdf = r.pdf { try? pdf.write(to: URL(fileURLWithPath: "/tmp/ipadtex-autotest.pdf")) }
            let diags = LogParser.parse(r.log)
            for d in diags { print("[autotest] \(d.severity) \(d.file ?? "?"):\(d.line.map(String.init) ?? "?") \(d.message)") }
            if !r.ok || ProcessInfo.processInfo.environment["IPADTEX_VERBOSE"] != nil { print("[autotest] LOG\n\(r.log)") }
        } catch { print("[autotest] error \(error)") }
        print("[autotest] done")
    }
}

#endif
