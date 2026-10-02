import XCTest
@testable import Burette

final class DiffParserTests: XCTestCase {

    func testParsesSingleFileSingleHunk() throws {
        let diff = [
            "--- a/hello.txt",
            "+++ b/hello.txt",
            "@@ -1,3 +1,4 @@",
            " line one",
            "-line two",
            "+line 2",
            "+line 2.5",
            " line three"
        ].joined(separator: "\n")

        let patches = try DiffParser.parse(diff)

        XCTAssertEqual(patches.count, 1)
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.path, "hello.txt")
        XCTAssertEqual(patch.kind, .modified)
        XCTAssertEqual(patch.hunks.count, 1)
        XCTAssertEqual(patch.hunks[0].oldStart, 1)
        XCTAssertEqual(patch.hunks[0].newCount, 4)
        XCTAssertEqual(patch.hunks[0].lines.count, 5)
        XCTAssertEqual(patch.addedLineCount, 2)
        XCTAssertEqual(patch.removedLineCount, 1)
    }

    func testParsesMultipleFiles() throws {
        let diff = [
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,1 +1,1 @@",
            "-old",
            "+new",
            "diff --git a/b.txt b/b.txt",
            "--- a/b.txt",
            "+++ b/b.txt",
            "@@ -1,1 +1,1 @@",
            "-foo",
            "+bar"
        ].joined(separator: "\n")

        let patches = try DiffParser.parse(diff)

        XCTAssertEqual(patches.map(\.path), ["a.txt", "b.txt"])
        XCTAssertTrue(patches.allSatisfy { $0.kind == .modified })
    }

    func testParsesAddedFile() throws {
        let diff = [
            "--- /dev/null",
            "+++ b/new.txt",
            "@@ -0,0 +1,2 @@",
            "+hello",
            "+world"
        ].joined(separator: "\n")

        let patches = try DiffParser.parse(diff)
        let patch = try XCTUnwrap(patches.first)

        XCTAssertEqual(patch.kind, .added)
        XCTAssertEqual(patch.oldPath, nil)
        XCTAssertEqual(patch.newPath, "new.txt")
        XCTAssertEqual(patch.addedLineCount, 2)
    }

    func testParsesDeletedFile() throws {
        let diff = [
            "--- a/gone.txt",
            "+++ /dev/null",
            "@@ -1,2 +0,0 @@",
            "-a",
            "-b"
        ].joined(separator: "\n")

        let patches = try DiffParser.parse(diff)
        let patch = try XCTUnwrap(patches.first)

        XCTAssertEqual(patch.kind, .deleted)
        XCTAssertEqual(patch.newPath, nil)
        XCTAssertEqual(patch.removedLineCount, 2)
    }

    func testNormalizesCRLF() throws {
        let diff = "--- a/x.txt\r\n+++ b/x.txt\r\n@@ -1,1 +1,1 @@\r\n-a\r\n+b\r\n"
        let patches = try DiffParser.parse(diff)
        XCTAssertEqual(patches.first?.hunks.first?.lines.first?.text, "a")
    }

    func testThrowsWhenNoDiffFound() {
        XCTAssertThrowsError(try DiffParser.parse("这里没有任何 diff。")) { error in
            XCTAssertEqual(error as? DiffParseError, .noFilesFound)
        }
    }

    func testIgnoresNoNewlineMarker() throws {
        let diff = [
            "--- a/x.txt",
            "+++ b/x.txt",
            "@@ -1,1 +1,1 @@",
            "-a",
            "+b",
            "\\ No newline at end of file"
        ].joined(separator: "\n")

        let patches = try DiffParser.parse(diff)
        XCTAssertEqual(patches.first?.hunks.first?.lines.count, 2)
    }
}
