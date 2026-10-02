import Foundation

/// 单个文件的 unified diff 改动。
struct FilePatch: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case modified
        case added
        case deleted
    }

    var id: UUID
    var oldPath: String?
    var newPath: String?
    var hunks: [DiffHunk]
    /// 由 diff 头部（new file mode / deleted file mode）显式声明的类型。
    var declaredKind: Kind?

    init(
        id: UUID = UUID(),
        oldPath: String?,
        newPath: String?,
        hunks: [DiffHunk],
        declaredKind: Kind? = nil
    ) {
        self.id = id
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.declaredKind = declaredKind
    }

    /// 改动后的路径，删除文件时回退到旧路径。
    var path: String { newPath ?? oldPath ?? "" }

    var kind: Kind {
        if let declaredKind { return declaredKind }
        if oldPath == nil { return .added }
        if newPath == nil { return .deleted }
        return .modified
    }

    var addedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    var removedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removal }.count }
    }
}

/// 一个 @@ ... @@ 块。
struct DiffHunk: Codable, Hashable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [DiffLine]

    init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

/// hunk 中的一行，text 不含前导的 +/-/空格。
struct DiffLine: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case context
        case addition
        case removal
    }

    var kind: Kind
    var text: String

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}
