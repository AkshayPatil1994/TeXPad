// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation

/// Runs recipe steps in the real WebAssembly engine. Project files are synced to an engine's file system
/// on the first step that uses it; later steps (BibTeX, reruns) reuse what the engine already holds.
@MainActor
final class EngineStepExecutor: StepExecutor {
    private let engine: TeXEngine
    private var pending: [EngineKind: (files: [String: Data], reset: Bool)]
    private let timeout: TimeInterval

    init(engine: TeXEngine, pending: [EngineKind: (files: [String: Data], reset: Bool)], timeout: TimeInterval) {
        self.engine = engine; self.pending = pending; self.timeout = timeout
    }

    func execute(_ request: StepRequest) async throws -> StepResult {
        guard await engine.prepare(request.engine) else {
            throw EngineUnavailable(engine: request.engine, detail: { if case .failed(let m) = engine.status { return m } else { return "" } }())
        }
        let sync = pending.removeValue(forKey: request.engine)
        let op = request.tool == .bibtex ? "bibtex" : "latex"
        return try await withTimeout(seconds: timeout) { [engine] in
            try await engine.run(engine: request.engine, op: op, main: request.main,
                                 files: sync?.files ?? [:], reset: sync?.reset ?? false, produce: request.produce)
        }
    }
}

struct EngineUnavailable: Error, CustomStringConvertible {
    var engine: EngineKind
    var detail: String
    var description: String { "The \(engine == .xetex ? "XeLaTeX" : "pdfTeX") engine couldn't start. \(detail.prefix(400))" }
}
