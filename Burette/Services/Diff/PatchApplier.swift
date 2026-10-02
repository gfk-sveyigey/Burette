import Foundation

enum PatchApplyError: Error, LocalizedError, Equatable {
    case fileNotFound(String)
    case contextMismatch(path: String, hunkIndex: Int, line: Int, expected: String, actual: String)
    case invalidRange(path: String, hunkIndex: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "工作区中找不到文件：\(path)"
        case .contextMismatch(let path, let hunkIndex, let line, let expected, let actual):
            return "\(path) 第 \(hunkIndex + 1) 个 hunk 上下文不匹配（原文第 \(line) 行）：期望「\(expected)」，实际「\(actual)」。"
        case .invalidRange(let path, let hunkIndex):
            return "\(path) 第 \(hunkIndex + 1) 个 hunk 的行号超出文件范围。"
        }
    }
}

/// 把 FilePatch 写回文件内容。
///
/// 采用「行号定位 + 上下文校验」的方式，任何不匹配都会抛出
/// PatchApplyError.contextMismatch，避免静默写错位置。
enum PatchApplier {

    static func apply(_ patch: FilePatch, to original: String?) throws -> String {
        switch patch.kind {
        case .added:
            return renderNewFile(patch)
        case .deleted:
            return ""
        case .modified:
            guard let original else {
                throw PatchApplyError.fileNotFound(patch.path)
            }
            return try applyHunks(patch, to: original)
        }
    }

    /// 批量应用，返回 path -> 新内容（删除的文件为空字符串）。
    static func apply(_ patches: [FilePatch], existingContents: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for patch in patches {
            let original = existingContents[patch.path]
            result[patch.path] = try apply(patch, to: original)
        }
        return result
    }

    // MARK: - Private

    static func renderNewFile(_ patch: FilePatch) -> String {
        var lines: [String] = []
        for hunk in patch.hunks {
            for line in hunk.lines where line.kind != .removal {
                lines.append(line.text)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func applyHunks(_ patch: FilePatch, to original: String) throws -> String {
        let hadTrailingNewline = original.hasSuffix("\n")
        var sourceLines = original.components(separatedBy: "\n")
        if hadTrailingNewline { sourceLines.removeLast() }

        var output: [String] = []
        var cursor = 0

        for (hunkIndex, hunk) in patch.hunks.enumerated() {
            let start = max(0, hunk.oldStart - 1)
            if start > sourceLines.count {
                throw PatchApplyError.invalidRange(path: patch.path, hunkIndex: hunkIndex)
            }
            while cursor < start {
                output.append(sourceLines[cursor])
                cursor += 1
            }

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    guard cursor < sourceLines.count, sourceLines[cursor] == line.text else {
                        let actual = cursor < sourceLines.count ? sourceLines[cursor] : "EOF"
                        throw PatchApplyError.contextMismatch(
                            path: patch.path,
                            hunkIndex: hunkIndex,
                            line: cursor + 1,
                            expected: line.text,
                            actual: actual
                        )
                    }
                    output.append(line.text)
                    cursor += 1
                case .removal:
                    guard cursor < sourceLines.count, sourceLines[cursor] == line.text else {
                        let actual = cursor < sourceLines.count ? sourceLines[cursor] : "EOF"
                        throw PatchApplyError.contextMismatch(
                            path: patch.path,
                            hunkIndex: hunkIndex,
                            line: cursor + 1,
                            expected: line.text,
                            actual: actual
                        )
                    }
                    cursor += 1
                case .addition:
                    output.append(line.text)
                }
            }
        }

        while cursor < sourceLines.count {
            output.append(sourceLines[cursor])
            cursor += 1
        }

        var result = output.joined(separator: "\n")
        if hadTrailingNewline && !output.isEmpty {
            result += "\n"
        }
        return result
    }
}
