import Foundation

/// 解析 Codex 风格的 apply_patch 文本，转换成可应用的 FilePatch。
///
/// 格式示例：
/// *** Begin Patch
/// *** Update File: path/to/file.swift
/// @@
///  上下文
/// -旧行
/// +新行
/// *** Add File: path/to/new.swift
/// +新行
/// *** Delete File: path/to/old.swift
/// *** End Patch
///
/// hunk 不带行号，落盘时依赖 PatchApplier 的「按内容搜索 + fuzz」定位。
enum ApplyPatchParser {

    enum ParseError: Error, LocalizedError {
        case empty
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "补丁里没有找到任何文件改动。"
            case .malformed(let detail):
                return "无法解析补丁：\(detail)"
            }
        }
    }

    /// 快速判断一段文本是不是 apply_patch 格式。
    static func looksLikeApplyPatch(_ text: String) -> Bool {
        text.contains("*** Begin Patch")
            || text.contains("*** Update File:")
            || text.contains("*** Add File:")
            || text.contains("*** Delete File:")
    }

    static func parse(_ raw: String) throws -> [FilePatch] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var patches: [FilePatch] = []
        var section: Section?
        var index = 0

        func flush() {
            if let built = section?.build() { patches.append(built) }
            section = nil
        }

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("*** End Patch") {
                flush()
                break
            }
            if line.hasPrefix("*** Begin Patch") {
                flush()
                index += 1
                continue
            }

            if let path = value(after: "*** Update File:", in: line) {
                flush()
                section = Section(oldPath: path, newPath: path, kind: .modified)
                index += 1
                continue
            }
            if let path = value(after: "*** Add File:", in: line) {
                flush()
                section = Section(oldPath: nil, newPath: path, kind: .added)
                index += 1
                continue
            }
            if let path = value(after: "*** Delete File:", in: line) {
                flush()
                section = Section(oldPath: path, newPath: nil, kind: .deleted)
                index += 1
                continue
            }
            if let path = value(after: "*** Move to:", in: line) {
                section?.newPath = path
                index += 1
                continue
            }

            if line.hasPrefix("@@") {
                section?.startHunk()
            } else if line.hasPrefix("+") {
                section?.append(.addition, String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                section?.append(.removal, String(line.dropFirst()))
            } else if line.hasPrefix(" ") {
                section?.append(.context, String(line.dropFirst()))
            } else if line.isEmpty {
                section?.appendContextIfInHunk()
            }
            index += 1
        }

        flush()

        if patches.isEmpty { throw ParseError.empty }
        return patches
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let raw = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{0060}"))
        return cleaned.isEmpty ? nil : cleaned
    }

    private struct Section {
        var oldPath: String?
        var newPath: String?
        let kind: FilePatch.Kind
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        var inHunk = false

        mutating func startHunk() {
            closeHunk()
            inHunk = true
        }

        mutating func append(_ kind: DiffLine.Kind, _ text: String) {
            if !inHunk { inHunk = true }
            current.append(DiffLine(kind: kind, text: text))
        }

        mutating func appendContextIfInHunk() {
            guard inHunk else { return }
            current.append(DiffLine(kind: .context, text: ""))
        }

        mutating func closeHunk() {
            defer {
                current = []
                inHunk = false
            }
            guard inHunk, !current.isEmpty else { return }
            let oldCount = current.filter { $0.kind != .addition }.count
            let newCount = current.filter { $0.kind != .removal }.count
            hunks.append(
                DiffHunk(oldStart: 1, oldCount: oldCount, newStart: 1, newCount: newCount, lines: current)
            )
        }

        mutating func build() -> FilePatch? {
            closeHunk()
            switch kind {
            case .deleted:
                guard let old = oldPath else { return nil }
                return FilePatch(oldPath: old, newPath: nil, hunks: [], declaredKind: .deleted)
            case .added:
                guard let new = newPath else { return nil }
                return FilePatch(oldPath: nil, newPath: new, hunks: hunks, declaredKind: .added)
            case .modified:
                guard !hunks.isEmpty else { return nil }
                return FilePatch(oldPath: oldPath, newPath: newPath ?? oldPath, hunks: hunks, declaredKind: .modified)
            }
        }
    }
}
