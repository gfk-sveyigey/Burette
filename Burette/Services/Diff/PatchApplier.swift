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
            return "\(path) 第 \(hunkIndex + 1) 个 hunk 无法定位（原文第 \(line) 行）：期望「\(expected)」，实际「\(actual)」。"
        case .invalidRange(let path, let hunkIndex):
            return "\(path) 第 \(hunkIndex + 1) 个 hunk 的行号超出文件范围。"
        }
    }
}

/// 把 FilePatch 写回文件内容。
///
/// 优先按 hunk 里给出的行号定位，同时校验上下文；如果行号不准确（模型常见问题），
/// 会在附近乃至全文件按内容搜索来纠正位置，尽量避免因为行号偏差而整条失败。
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
            do {
                return try applyHunks(patch, to: original)
            } catch {
                // 单个 hunk 且几乎覆盖整个文件时，视为整文件重写，直接采用新内容。
                if let fallback = wholeFileRewrite(patch, original: original) {
                    Log.warning("hunk 定位失败，按整文件重写应用：\(patch.path)", .diff)
                    return fallback
                }
                throw error
            }
        }
    }

    /// 判断该 patch 能否在给定内容中定位并应用（用于校验模型给的路径是否正确）。
    static func canLocate(_ patch: FilePatch, in original: String) -> Bool {
        guard !patch.hunks.isEmpty else { return true }
        return (try? applyHunks(patch, to: original)) != nil
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
            let oldLines = hunk.lines.filter { $0.kind != .addition }.map(\.text)
            let preferred = max(cursor, hunk.oldStart - 1)

            let start: Int
            if let located = locate(oldLines, in: sourceLines, preferred: preferred, minimum: cursor) {
                start = located
            } else if oldLines.isEmpty {
                // 纯新增：夹到文件范围内插入。
                start = min(preferred, sourceLines.count)
            } else {
                let probe = min(preferred, max(sourceLines.count - 1, 0))
                throw PatchApplyError.contextMismatch(
                    path: patch.path,
                    hunkIndex: hunkIndex,
                    line: probe + 1,
                    expected: oldLines.first ?? "",
                    actual: probe < sourceLines.count ? sourceLines[probe] : "EOF"
                )
            }

            while cursor < start {
                output.append(sourceLines[cursor])
                cursor += 1
            }

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    guard cursor < sourceLines.count else {
                        throw PatchApplyError.contextMismatch(
                            path: patch.path,
                            hunkIndex: hunkIndex,
                            line: cursor + 1,
                            expected: line.text,
                            actual: "EOF"
                        )
                    }
                    // 定位阶段已按内容校验，这里采用文件里的真实行，避免空白差异写错。
                    output.append(sourceLines[cursor])
                    cursor += 1
                case .removal:
                    guard cursor < sourceLines.count else {
                        throw PatchApplyError.contextMismatch(
                            path: patch.path,
                            hunkIndex: hunkIndex,
                            line: cursor + 1,
                            expected: line.text,
                            actual: "EOF"
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

    /// 在文件中寻找 hunk 旧内容的位置：优先用给定行号，其次向两侧扩散，最后按内容全文件搜索。
    private static func locate(
        _ oldLines: [String],
        in sourceLines: [String],
        preferred: Int,
        minimum: Int
    ) -> Int? {
        guard !oldLines.isEmpty else {
            return min(max(preferred, minimum), sourceLines.count)
        }
        guard oldLines.count <= sourceLines.count else { return nil }

        let upper = sourceLines.count - oldLines.count
        let clamped = min(max(preferred, minimum), upper)

        if matches(oldLines, in: sourceLines, at: clamped, exact: true) { return clamped }
        if let found = search(oldLines, in: sourceLines, around: clamped, minimum: minimum, exact: true) {
            return found
        }
        return search(oldLines, in: sourceLines, around: clamped, minimum: minimum, exact: false)
    }

    private static func search(
        _ oldLines: [String],
        in sourceLines: [String],
        around position: Int,
        minimum: Int,
        exact: Bool
    ) -> Int? {
        let upper = sourceLines.count - oldLines.count
        guard upper >= 0 else { return nil }
        let maxDistance = max(upper, 1)
        var distance = 1
        while distance <= maxDistance {
            let up = position - distance
            if up >= minimum, up <= upper, matches(oldLines, in: sourceLines, at: up, exact: exact) {
                return up
            }
            let down = position + distance
            if down >= minimum, down <= upper, matches(oldLines, in: sourceLines, at: down, exact: exact) {
                return down
            }
            distance += 1
        }
        return nil
    }

    private static func matches(
        _ oldLines: [String],
        in sourceLines: [String],
        at index: Int,
        exact: Bool
    ) -> Bool {
        guard index >= 0, index + oldLines.count <= sourceLines.count else { return false }
        for (offset, expected) in oldLines.enumerated() {
            let actual = sourceLines[index + offset]
            if exact {
                if actual != expected { return false }
            } else if actual.trimmingCharacters(in: .whitespaces) != expected.trimmingCharacters(in: .whitespaces) {
                return false
            }
        }
        return true
    }

    /// 单 hunk 且几乎覆盖整个文件时，视为整文件重写。
    private static func wholeFileRewrite(_ patch: FilePatch, original: String) -> String? {
        guard patch.hunks.count == 1, let hunk = patch.hunks.first else { return nil }
        var originalLines = original.components(separatedBy: "\n")
        if original.hasSuffix("\n") { originalLines.removeLast() }
        let oldCount = hunk.lines.filter { $0.kind != .addition }.count
        guard hunk.oldStart <= 1, oldCount >= max(1, originalLines.count - 2) else { return nil }
        return renderNewFile(patch)
    }
}
