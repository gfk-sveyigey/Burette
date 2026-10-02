import Foundation

/// 工作区中相对 base commit 的一处文件改动。
struct FileChange: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case added
        case modified
        case deleted
    }

    var id: UUID
    var path: String
    var status: Status

    /// base commit 中的内容，新增文件为 nil。
    var original: String?

    /// 当前工作区内容，删除文件为空字符串。
    var current: String

    /// 是否勾选进入下一次提交。
    var isStaged: Bool

    init(
        id: UUID = UUID(),
        path: String,
        status: Status,
        original: String?,
        current: String,
        isStaged: Bool = false
    ) {
        self.id = id
        self.path = path
        self.status = status
        self.original = original
        self.current = current
        self.isStaged = isStaged
    }

    /// 生成用于显示的 unified diff 文本。
    func unifiedDiff() -> String {
        var out = ""
        let oldPath = status == .added ? "/dev/null" : "a/\(path)"
        let newPath = status == .deleted ? "/dev/null" : "b/\(path)"
        out += "--- \(oldPath)\n"
        out += "+++ \(newPath)\n"
        for line in Self.makeHunkLines(from: original, to: current) {
            out += line + "\n"
        }
        return out
    }

    /// 极简的行级 diff：整段替换为单个 hunk，够用于预览。
    static func makeHunkLines(from old: String?, to new: String) -> [String] {
        let oldText = old ?? ""
        let oldLines = oldText.isEmpty ? [] : oldText.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var lines: [String] = []
        lines.append("@@ -1,\(oldLines.count) +1,\(newLines.count) @@")
        lines.append(contentsOf: oldLines.map { "-" + $0 })
        lines.append(contentsOf: newLines.map { "+" + $0 })
        return lines
    }
}
