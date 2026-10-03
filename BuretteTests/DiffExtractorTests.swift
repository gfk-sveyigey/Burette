import XCTest
@testable import Burette

final class DiffExtractorTests: XCTestCase {

    /// 用 \u{0060} 构造三反引号，避免源码里出现反引号。
    private let fence = String(repeating: "\u{0060}", count: 3)

    func testMergesAllFencedDiffBlocks() throws {
        // 每个文件一个代码块：必须全部合并，否则多文件改动只会应用一个文件。
        let reply = [
            "我来改两个文件。",
            fence + "diff",
            "--- a/A.swift",
            "+++ b/A.swift",
            "@@ -1,2 +1,2 @@",
            " a",
            "-b",
            "+c",
            fence,
            "还有第二个文件：",
            fence,
            "--- a/B.swift",
            "+++ b/B.swift",
            "@@ -1,1 +1,1 @@",
            "-x",
            "+y",
            fence,
            "完成。"
        ].joined(separator: "\n")

        let extracted = DiffExtractor.extract(from: reply)
        let patches = try DiffParser.parse(extracted)

        XCTAssertEqual(patches.map(\.path), ["A.swift", "B.swift"])
    }

    func testIgnoresNonDiffFencedBlock() {
        let reply = [
            fence + "sh",
            "echo hello",
            fence,
            fence + "diff",
            "--- a/A.swift",
            "+++ b/A.swift",
            "@@ -1,1 +1,1 @@",
            "-a",
            "+b",
            fence
        ].joined(separator: "\n")

        let extracted = DiffExtractor.extract(from: reply)

        XCTAssertTrue(extracted.contains("--- a/A.swift"))
        XCTAssertFalse(extracted.contains("echo hello"))
    }

    func testProseRemovesAllDiffBlocks() {
        let reply = [
            "开头。",
            fence + "diff",
            "--- a/A.swift",
            "+++ b/A.swift",
            "@@ -1,1 +1,1 @@",
            "-a",
            "+b",
            fence,
            "中间。",
            fence,
            "--- a/B.swift",
            "+++ b/B.swift",
            "@@ -1,1 +1,1 @@",
            "-x",
            "+y",
            fence,
            "结尾。"
        ].joined(separator: "\n")

        let prose = DiffExtractor.prose(from: reply)

        XCTAssertEqual(prose, "开头。\n中间。\n结尾。")
    }
}
