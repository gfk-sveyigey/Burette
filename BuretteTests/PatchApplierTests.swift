import XCTest
@testable import Burette

final class PatchApplierTests: XCTestCase {

    private func patch(from diff: [String]) throws -> FilePatch {
        try XCTUnwrap(try DiffParser.parse(diff.joined(separator: "\n")).first)
    }

    func testAppliesModificationPreservingTrailingNewline() throws {
        let original = "line one\nline two\nline three\n"
        let filePatch = try patch(from: [
            "--- a/hello.txt",
            "+++ b/hello.txt",
            "@@ -1,3 +1,4 @@",
            " line one",
            "-line two",
            "+line 2",
            "+line 2.5",
            " line three"
        ])

        let result = try PatchApplier.apply(filePatch, to: original)

        XCTAssertEqual(result, "line one\nline 2\nline 2.5\nline three\n")
    }

    func testAppliesMultipleHunks() throws {
        let original = "a\nb\nc\nd\ne\nf\n"
        let filePatch = try patch(from: [
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,3 +1,3 @@",
            " a",
            "-b",
            "+B",
            " c",
            "@@ -4,3 +4,3 @@",
            " d",
            "-e",
            "+E",
            " f"
        ])

        let result = try PatchApplier.apply(filePatch, to: original)

        XCTAssertEqual(result, "a\nB\nc\nd\nE\nf\n")
    }

    func testCreatesNewFile() throws {
        let filePatch = try patch(from: [
            "--- /dev/null",
            "+++ b/new.txt",
            "@@ -0,0 +1,2 @@",
            "+hello",
            "+world"
        ])

        let result = try PatchApplier.apply(filePatch, to: nil)

        XCTAssertEqual(result, "hello\nworld\n")
    }

    func testDeletesFile() throws {
        let filePatch = try patch(from: [
            "--- a/gone.txt",
            "+++ /dev/null",
            "@@ -1,2 +0,0 @@",
            "-a",
            "-b"
        ])

        let result = try PatchApplier.apply(filePatch, to: "a\nb\n")

        XCTAssertEqual(result, "")
    }

    func testThrowsOnContextMismatch() throws {
        let filePatch = try patch(from: [
            "--- a/x.txt",
            "+++ b/x.txt",
            "@@ -1,3 +1,3 @@",
            " a",
            "-b",
            "+B",
            " c"
        ])

        XCTAssertThrowsError(try PatchApplier.apply(filePatch, to: "a\nx\nc\n")) { error in
            guard let applyError = error as? PatchApplyError,
                  case .contextMismatch = applyError else {
                return XCTFail("期望 contextMismatch，实际 \(error)")
            }
        }
    }

    func testThrowsWhenModifiedFileMissing() throws {
        let filePatch = try patch(from: [
            "--- a/x.txt",
            "+++ b/x.txt",
            "@@ -1,1 +1,1 @@",
            "-a",
            "+b"
        ])

        XCTAssertThrowsError(try PatchApplier.apply(filePatch, to: nil)) { error in
            guard let applyError = error as? PatchApplyError,
                  case .fileNotFound = applyError else {
                return XCTFail("期望 fileNotFound，实际 \(error)")
            }
        }
    }
}
