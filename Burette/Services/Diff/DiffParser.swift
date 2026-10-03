import Foundation

enum DiffParseError: Error, LocalizedError, Equatable {
    case noFilesFound
    case malformedHunkHeader(String)

    var errorDescription: String? {
        switch self {
        case .noFilesFound:
            return "没有在模型回复中找到 unified diff。"
        case .malformedHunkHeader(let header):
            return "无法解析 hunk 头部：\(header)"
        }
    }
}

/// 把 unified diff 文本解析为结构化的 FilePatch 列表。
///
/// 支持多文件、多个 hunk、新增/删除文件，以及 diff 中的
/// "No newline at end of file" 标记行。
enum DiffParser {

    static func parse(_ raw: String) throws -> [FilePatch] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var patches: [FilePatch] = []
        var builder = Builder()
        var index = 0

        func flush() {
            if let patch = builder.build() {
                patches.append(patch)
            }
            builder = Builder()
        }

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("diff --git ") {
                flush()
                let remainder = line.dropFirst("diff --git ".count)
                let parts = remainder
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                if parts.count >= 2 {
                    builder.headerOld = normalizePath(parts[0])
                    builder.headerNew = normalizePath(parts[1])
                }
                index += 1
                continue
            }

            if line.hasPrefix("new file mode") {
                builder.declaredKind = .added
                index += 1
                continue
            }

            if line.hasPrefix("deleted file mode") {
                builder.declaredKind = .deleted
                index += 1
                continue
            }

            if line.hasPrefix("--- ") {
                // 模型有时不给 diff --git 头，而是直接连续拼接多个
                // "--- a/x / +++ b/x" 段落。遇到新的文件头时先收尾上一个文件，
                // 否则多个文件的 hunk 会被并进同一个 patch。
                if builder.sawOldHeader || !builder.hunks.isEmpty {
                    flush()
                }
                builder.oldPath = normalizePath(String(line.dropFirst(4)))
                builder.sawOldHeader = true
                index += 1
                continue
            }

            if line.hasPrefix("+++ ") {
                builder.newPath = normalizePath(String(line.dropFirst(4)))
                builder.sawNewHeader = true
                index += 1
                continue
            }

            if line.hasPrefix("@@") {
                let (hunk, consumed) = try parseHunk(lines: lines, from: index)
                builder.hunks.append(hunk)
                index += consumed
                continue
            }

            index += 1
        }

        flush()

        if patches.isEmpty {
            throw DiffParseError.noFilesFound
        }
        return patches
    }

    // MARK: - Hunk

    private static func parseHunk(lines: [String], from start: Int) throws -> (DiffHunk, Int) {
        let header = lines[start]
        guard let headerRange = header.range(of: "@@ -") else {
            throw DiffParseError.malformedHunkHeader(header)
        }
        let rest = String(header[headerRange.upperBound...])
        let tokens = rest
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        guard tokens.count >= 2,
              let oldRange = parseRange(tokens[0]),
              let newRange = parseRange(tokens[1].hasPrefix("+") ? String(tokens[1].dropFirst()) : tokens[1])
        else {
            throw DiffParseError.malformedHunkHeader(header)
        }

        var oldLeft = oldRange.count
        var newLeft = newRange.count
        var body: [DiffLine] = []
        var index = start + 1

        scan: while index < lines.count {
            if oldLeft <= 0 && newLeft <= 0 { break }

            let line = lines[index]

            if line.hasPrefix("\\") {
                index += 1
                continue
            }

            // 模型给出的行号/计数经常有小误差；一旦遇到下一个文件头或 hunk 头，
            // 说明当前 hunk 已经结束，必须停下来交给外层解析，否则会把 "--- a/x"
            // 当成删除行吃掉，导致后续文件的改动丢失。
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@") || isFileHeaderStart(lines, at: index) {
                break scan
            }

            if line.isEmpty {
                body.append(DiffLine(kind: .context, text: ""))
                oldLeft -= 1
                newLeft -= 1
                index += 1
                continue
            }

            switch line.first! {
            case "+":
                body.append(DiffLine(kind: .addition, text: String(line.dropFirst())))
                newLeft -= 1
            case "-":
                body.append(DiffLine(kind: .removal, text: String(line.dropFirst())))
                oldLeft -= 1
            case " ":
                body.append(DiffLine(kind: .context, text: String(line.dropFirst())))
                oldLeft -= 1
                newLeft -= 1
            default:
                break scan
            }
            index += 1
        }

        let hunk = DiffHunk(
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count,
            lines: body
        )
        return (hunk, index - start)
    }

    private static func parseRange(_ token: String) -> (start: Int, count: Int)? {
        let parts = token.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = parts.first, let start = Int(first) else { return nil }
        let count = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
        return (start, count)
    }

    /// 判断 index 处是否是 "--- x" / "+++ y" 这样的文件头对。
    private static func isFileHeaderStart(_ lines: [String], at index: Int) -> Bool {
        guard lines[index].hasPrefix("--- "), index + 1 < lines.count else { return false }
        return lines[index + 1].hasPrefix("+++ ")
    }

    private static func normalizePath(_ raw: String) -> String? {
        var value = raw
        if let tabIndex = value.firstIndex(of: "\t") {
            value = String(value[value.startIndex..<tabIndex])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value == "/dev/null" { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value.isEmpty ? nil : value
    }

    // MARK: - Builder

    private struct Builder {
        var headerOld: String?
        var headerNew: String?
        var oldPath: String?
        var newPath: String?
        var sawOldHeader = false
        var sawNewHeader = false
        var declaredKind: FilePatch.Kind?
        var hunks: [DiffHunk] = []

        func build() -> FilePatch? {
            guard !hunks.isEmpty else { return nil }
            let old = sawOldHeader ? oldPath : headerOld
            let new = sawNewHeader ? newPath : headerNew
            return FilePatch(
                oldPath: old,
                newPath: new,
                hunks: hunks,
                declaredKind: declaredKind
            )
        }
    }
}
