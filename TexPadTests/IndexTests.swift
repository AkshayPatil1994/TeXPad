// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
@testable import TexPad

final class IndexTests: XCTestCase {
    func testBibParserReadsEntries() {
        let bib = """
        @book{knuth84,
          author    = {Donald E. Knuth},
          title     = {The {\\TeX}book},
          year      = {1984}
        }
        @article{doe20, author = "Doe, Jane and Roe, Rick", title = "A Study", year = 2020}
        @comment{ignored}
        @string{foo = "bar"}
        """
        let e = BibParser.parse(bib)
        XCTAssertEqual(e.map(\.key), ["knuth84", "doe20"])
        XCTAssertEqual(e[0].title, "The \\TeXbook")
        XCTAssertEqual(e[0].year, "1984")
        XCTAssertEqual(e[0].shortAuthor, "Knuth")
        XCTAssertEqual(e[1].shortAuthor, "Doe et al.")
        XCTAssertEqual(e[1].year, "2020")
        XCTAssertEqual(e[0].line, 1)
    }

    func testIndexFindsOutlineLabelsAndPackages() {
        let main = """
        \\documentclass{article}
        \\usepackage{amsmath, graphicx}
        \\begin{document}
        \\section{Intro}\\label{sec:intro}
        % \\section{Commented out}
        \\input{chapters/two}
        \\end{document}
        """
        let two = "\\subsection{Details}\n\\label{eq:a} text \\label{eq:b}\n"
        let idx = ProjectIndex.build(texts: ["main.tex": main, "chapters/two.tex": two, "refs.bib": "@book{k, title={T}}"], mainFirst: "main.tex")
        XCTAssertEqual(idx.outline.map(\.title), ["Intro", "Details"])
        XCTAssertEqual(idx.outline.map(\.level), [2, 3])
        XCTAssertEqual(idx.labels.map(\.key), ["sec:intro", "eq:a", "eq:b"])
        XCTAssertEqual(idx.packages, ["amsmath", "graphicx"])
        XCTAssertEqual(idx.includes["main.tex"], ["chapters/two.tex"])
        XCTAssertEqual(idx.citations.map(\.key), ["k"])
        XCTAssertEqual(idx.location(ofLabel: "eq:b")?.path, "chapters/two.tex")
        XCTAssertEqual(idx.location(ofLabel: "eq:b")?.line, 2)
    }

    func testSearchAndReplace() {
        let texts = ["a.tex": "Hello world\nhello again\nnothing", "b.tex": "say HELLO"]
        let ci = ProjectSearch.search(query: "hello", texts: texts, caseSensitive: false, regex: false, wholeWord: false)
        XCTAssertEqual(ci.count, 3)
        let cs = ProjectSearch.search(query: "hello", texts: texts, caseSensitive: true, regex: false, wholeWord: false)
        XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs.first?.line, 2)
        let changed = ProjectSearch.replace(query: "hello", with: "bye", texts: texts, caseSensitive: false, regex: false, wholeWord: false)
        XCTAssertEqual(changed["a.tex"], "bye world\nbye again\nnothing")
        XCTAssertEqual(changed["b.tex"], "say bye")
    }

    func testSyncGuessRoundTrip() {
        let q = SyncGuess.pdfQuery(forSourceLine: "This chapter \\emph{introduces} the topic. \\label{x}")
        XCTAssertEqual(q, "This chapter introduces the topic.")
        let texts = ["main.tex": "\\section{A}\nsome filler\nThis chapter introduces the topic.\n"]
        let hit = SyncGuess.source(forPDFText: "chapter introduces the", texts: texts)
        XCTAssertEqual(hit?.path, "main.tex")
        XCTAssertEqual(hit?.line, 3)
        XCTAssertNil(SyncGuess.source(forPDFText: "zzzz qqqq", texts: texts))
    }

    func testFileKindDetection() {
        XCTAssertTrue(FileKind.isText(ext: "tex", name: "a.tex"))
        XCTAssertTrue(FileKind.isText(ext: "", name: "Makefile"))
        XCTAssertFalse(FileKind.isText(ext: "png", name: "a.png"))
        XCTAssertFalse(FileKind.isText(ext: "pdf", name: "a.pdf"))
    }
}
