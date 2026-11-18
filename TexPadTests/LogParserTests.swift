// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import XCTest
@testable import TexPad

final class LogParserTests: XCTestCase {
    func testUndefinedControlSequence() {
        let log = """
        (main.tex
        LaTeX2e <2023-11-01> patch level 1
        (/tex/article.cls) 
        ! Undefined control sequence.
        l.3 Hello \\undefinedcommand
                                    {world}.
        !  ==> Fatal error occurred, no output PDF file produced!
        """
        let d = LogParser.parse(log)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].severity, .error)
        XCTAssertEqual(d[0].file, "main.tex")
        XCTAssertEqual(d[0].line, 3)
        XCTAssertEqual(d[0].message, "Undefined control sequence.")
    }

    func testErrorInsideInputFile() {
        let log = """
        (./main.tex (./chapters/intro.tex
        ! Missing $ inserted.
        <inserted text> 
                        $
        l.12 x^2 y_
                   3
        """
        let d = LogParser.parse(log)
        XCTAssertEqual(d.first?.file, "chapters/intro.tex")
        XCTAssertEqual(d.first?.line, 12)
    }

    func testErrorInBundledFileIsReportedAsBundle() {
        let log = "(main.tex (/tex/fontenc.sty\n! Font foo not loadable.\nl.112 stuff\n"
        let d = LogParser.parse(log)
        XCTAssertEqual(d.first?.file, "/tex/fontenc.sty")
        XCTAssertFalse(LogParser.isProjectFile(d.first!.file!))
    }

    func testWarningsWithLineNumbers() {
        let log = """
        (main.tex
        LaTeX Warning: Citation `knuth84' on page 1 undefined on input line 46.

        LaTeX Warning: Reference `sec:x' on page 2 undefined on input line 60.

        Overfull \\hbox (12.0pt too wide) in paragraph at lines 20--21
        )
        """
        let d = LogParser.parse(log)
        XCTAssertEqual(d.filter { $0.severity == .warning }.count, 2)
        XCTAssertEqual(d[0].line, 46)
        XCTAssertEqual(d[0].file, "main.tex")
        XCTAssertEqual(d[1].line, 60)
        XCTAssertEqual(d.last?.severity, .info)
        XCTAssertEqual(d.last?.line, 20)
    }

    func testUnwrapJoinsHardWrappedLines() {
        let long = String(repeating: "a", count: 79)
        let lines = LogParser.unwrap(long + "bcd\nnext")
        XCTAssertEqual(lines, [long + "bcd", "next"])
    }

    func testParenthesesInTextDoNotBreakFileStack() {
        let log = "(main.tex\nSome text (not a file) and more\n! Oops.\nl.5 x\n"
        XCTAssertEqual(LogParser.parse(log).first?.file, "main.tex")
    }
}
