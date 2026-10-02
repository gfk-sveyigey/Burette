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
/// 定位策略（越往后越宽松）：
/// 1. 按 @@ 行号精确匹配整段旧内容；
/// 2. 在文件里按内容搜索（先精确、再忽略首尾空白）；
/// 3. fuzz：保留所有删除行，逐步丢弃首尾上下文行再匹配（模型上下文常有个别行对不上）；
/// 4. 如果文件里已经是改动后的内容，视为「已应用」跳过；
/// 5. 单 hunk 覆盖整个文件时按整文件重写。
/// 只有当以上都失败时才报错。
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
                if let fallback = wholeFileRewrite(patch, original: original) {
                    Log.warning("hunk 定位失败，按整文件重写应用：\(patch.path)", .diff)
                    return fallback
                }
                throw error
            }
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

    /// 判断该 patch 能否在给定内容中定位并应用（用于校验模型给的路径是否正确）。
    static func canLocate(_ patch: FilePatch, in original: String) -> Bool {
        guard !patch.hunks.isEmpty else { return true }
        return (try? applyHunks(patch, to: original)) != nil
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
            let oldBlock = hunk.lines.filter { $0.kind != .addition }.map(\.text)
            let newBlock = hunk.lines.filter { $0.kind != .removal }.map(\.text)
            let preferred = max(cursor, hunk.oldStart - 1)

            let start: Int
            if let located = locateBlock(oldBlock, in: sourceLines, preferred: preferred, minimum: cursor, hunk: hunk) {
                start = located
            } else if isAlreadyApplied(oldBlock: oldBlock, newBlock: newBlock, in: sourceLines, preferred: preferred) {
                Log.debug("hunk 已经是改动后的状态，跳过：\(patch.path)", .diff)
                continue
            } else {
                let probe = min(preferred, max(sourceLines.count - 1, 0))
                throw PatchApplyError.contextMismatch(
                    path: patch.path,
                    hunkIndex: hunkIndex,
                    line: probe + 1,
                    expected: oldBlock.first ?? "",
                    actual: probe < sourceLines.count ? sourceLines[probe] : "EOF"
                )
            }

            while cursor < start {
                output.append(sourceLines[cursor])
                cursor += 1
            }

            var oldIndex = start
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    // 用文件里的真实行，避免模型上下文里的空白差异写回文件。
                    output.append(oldIndex < sourceLines.count ? sourceLines[oldIndex] : line.text)
                    oldIndex += 1
                case .removal:
                    oldIndex += 1
                case .addition:
                    output.append(line.text)
                }
            }
            cursor = oldIndex
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

    /// 定位 hunk 旧内容：精确 → 搜索 → 忽略空白 → fuzz（丢上下文但保留删除行）。
    private static func locateBlock(
        _ oldBlock: [String],
        in sourceLines: [String],
        preferred: Int,
        minimum: Int,
        hunk: DiffHunk
    ) -> Int? {
        if oldBlock.isEmpty {
            return min(max(preferred, minimum), sourceLines.count)
        }
        guard oldBlock.count <= sourceLines.count else { return nil }

        if let exact = searchBlock(oldBlock, in: sourceLines, preferred: preferred, minimum: minimum, exact: true) {
            return exact
        }
        if let loose = searchBlock(oldBlock, in: sourceLines, preferred: preferred, minimum: minimum, exact: false) {
            return loose
        }

        // fuzz：hunk 里所有删除行必须一起匹配，首尾上下文可以逐个丢弃。
        let removalLineIndices = hunk.lines.indices.filter { hunk.lines[$0].kind == .removal }
        guard let firstRemovalLine = removalLineIndices.first,
              let lastRemovalLine = removalLineIndices.last else {
            return insertAnchor(hunk, in: sourceLines, preferred: preferred, minimum: minimum)
        }

        var oldIndexOfLine: [Int?] = []
        var counter = 0
        for line in hunk.lines {
            if line.kind == .addition {
                oldIndexOfLine.append(nil)
            } else {
                oldIndexOfLine.append(counter)
                counter += 1
            }
        }
        guard let firstOld = oldIndexOfLine[firstRemovalLine],
              let lastOld = oldIndexOfLine[lastRemovalLine] else { return nil }

        var dropLead = firstOld
        while dropLead >= 0 {
            var dropTrail = lastOld
            while dropTrail < oldBlock.count {
                if dropLead <= dropTrail {
                    let sub = Array(oldBlock[dropLead...dropTrail])
                    if !sub.isEmpty,
                       let found = searchBlock(
                           sub,
                           in: sourceLines,
                           preferred: preferred - dropLead,
                           minimum: 0,
                           exact: false
                       ) {
                        let candidate = found - dropLead
                        if candidate >= minimum, candidate + oldBlock.count <= sourceLines.count {
                            return candidate
                        }
                    }
                }
                dropTrail += 1
            }
            dropLead -= 1
        }
        return nil
    }

    /// 纯新增 hunk 的锚点：优先用它前后的上下文行定位。
    private static func insertAnchor(
        _ hunk: DiffHunk,
        in sourceLines: [String],
        preferred: Int,
        minimum: Int
    ) -> Int? {
        guard let firstAddition = hunk.lines.firstIndex(where: { $0.kind == .addition }) else { return nil }
        let leading = hunk.lines[..<firstAddition].filter { $0.kind == .context }.map(\.text)
        if !leading.isEmpty,
           let found = searchBlock(leading, in: sourceLines, preferred: preferred, minimum: minimum, exact: false) {
            return min(found + leading.count, sourceLines.count)
        }
        let trailing = hunk.lines[firstAddition...].filter { $0.kind == .context }.map(\.text)
        if !trailing.isEmpty,
           let found = searchBlock(trailing, in: sourceLines, preferred: preferred, minimum: minimum, exact: false) {
            return found
        }
        return min(max(preferred, minimum), sourceLines.count)
    }

    /// 文件里是否已经是改动后的状态（用于重复应用时跳过）。
    private static func isAlreadyApplied(
        oldBlock: [String],
        newBlock: [String],
        in sourceLines: [String],
        preferred: Int
    ) -> Bool {
        guard !newBlock.isEmpty else { return false }
        if oldBlock == newBlock {
            // 没有任何变化的 hunk（只有上下文）。
            return searchBlock(oldBlock, in: sourceLines, preferred: preferred, minimum: 0, exact: false) != nil
        }
        return searchBlock(newBlock, in: sourceLines, preferred: preferred, minimum: 0, exact: false) != nil
    }

    /// 从 preferred 开始向两侧扩散搜索 block。
    private static func searchBlock(
        _ block: [String],
        in sourceLines: [String],
        preferred: Int,
        minimum: Int,
        exact: Bool
    ) -> Int? {
        guard !block.isEmpty, block.count <= sourceLines.count else { return nil }
        let upper = sourceLines.count - block.count
        let lower = min(max(minimum, 0), upper)
        let start = min(max(preferred, lower), upper)

        if matches(block, in: sourceLines, at: start, exact: exact) { return start }

        let maxDistance = max(upper - lower, 1)
        var distance = 1
        while distance <= maxDistance {
            let up = start - distance
            if up >= lower, matches(block, in: sourceLines, at: up, exact: exact) { return up }
            let down = start + distance
            if down <= upper, matches(block, in: sourceLines, at: down, exact: exact) { return down }
            distance += 1
        }
        return nil
    }

    private static func matches(
        _ block: [String],
        in sourceLines: [String],
        at index: Int,
        exact: Bool
    ) -> Bool {
        guard index >= 0, index + block.count <= sourceLines.count else { return false }
        for (offset, expected) in block.enumerated() {
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
