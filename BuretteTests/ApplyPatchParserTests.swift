import XCTest
@testable import Burette

final class ApplyPatchParserTests: XCTestCase {

    func testParsesUpdateHunk() throws {
        let text = [
            "*** Begin Patch",
            "*** Update File: hello.txt",
            "@@",
            " line one",
            "-line two",
            "+line 2",
            " line three",
            "*** End Patch"
        ].joined(separator: "\n")

        let patches = try ApplyPatchParser.parse(text)

        XCTAssertEqual(patches.count, 1)
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.path, "hello.txt")
        XCTAssertEqual(patch.kind, .modified)
        XCTAssertEqual(patch.hunks.count, 1)
        XCTAssertEqual(patch.hunks[0].lines.count, 4)
        XCTAssertEqual(patch.addedLineCount, 1)
        XCTAssertEqual(patch.removedLineCount, 1)
    }

    func testParsesMultipleFiles() throws {
        let text = [
            "*** Begin Patch",
            "*** Update File: a.txt",
            "@@",
            "-old",
            "+new",
            "*** Add File: b.txt",
            "+first",
            "+second",
            "*** Delete File: c.txt",
            "*** End Patch"
        ].joined(separator: "\n")

        let patches = try ApplyPatchParser.parse(text)

        XCTAssertEqual(patches.map(\.path), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(patches[0].kind, .modified)
        XCTAssertEqual(patches[1].kind, .added)
        XCTAssertEqual(patches[2].kind, .deleted)
        XCTAssertEqual(PatchApplier.renderNewFile(patches[1]), "first\nsecond\n")
    }

    func testAppliesUpdateByContentWithoutLineNumbers() throws {
        let text = [
            "*** Begin Patch",
            "*** Update File: hello.txt",
            "@@",
            " line one",
            "-line two",
            "+line 2",
            " line three",
            "*** End Patch"
        ].joined(separator: "\n")

        let patch = try XCTUnwrap(try ApplyPatchParser.parse(text).first)
        let original = "line one\nline two\nline three\n"
        let updated = try PatchApplier.apply(patch, to: original)

        XCTAssertEqual(updated, "line one\nline 2\nline three\n")
    }

    func testThrowsWhenEmpty() {
        XCTAssertThrowsError(try ApplyPatchParser.parse("没有任何补丁内容"))
    }
}
