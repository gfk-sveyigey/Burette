import Foundation

/// 行级 diff（LCS），用于在改动页以 GitHub 风格展示增删。
enum LineDiff {
    enum Kind {
        case context
        case added
        case removed
    }

    struct Line: Identifiable {
        let id = UUID()
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    /// 计算 old → new 的行级差异。old 为 nil 表示新增文件。
    static func compute(from old: String?, to new: String) -> [Line] {
        let oldLines = split(old)
        let newLines = split(new)
        var result: [Line] = []
        var oldNo = 1
        var newNo = 1

        for op in lcsDiff(oldLines, newLines) {
            switch op {
            case .equal(let text):
                result.append(Line(kind: .context, oldNumber: oldNo, newNumber: newNo, text: text))
                oldNo += 1
                newNo += 1
            case .remove(let text):
                result.append(Line(kind: .removed, oldNumber: oldNo, newNumber: nil, text: text))
                oldNo += 1
            case .insert(let text):
                result.append(Line(kind: .added, oldNumber: nil, newNumber: newNo, text: text))
                newNo += 1
            }
        }
        return result
    }

    /// 统计新增 / 删除行数。
    static func stats(from old: String?, to new: String) -> (added: Int, removed: Int) {
        compute(from: old, to: new).reduce(into: (0, 0)) { acc, line in
            if line.kind == .added { acc.0 += 1 }
            if line.kind == .removed { acc.1 += 1 }
        }
    }

    // MARK: - 私有

    private enum Op {
        case equal(String)
        case remove(String)
        case insert(String)
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // 以换行结尾时，components 会多出一个空元素，展示时去掉。
        if lines.count > 1 && lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func lcsDiff(_ a: [String], _ b: [String]) -> [Op] {
        if a.isEmpty { return b.map { .insert($0) } }
        if b.isEmpty { return a.map { .remove($0) } }

        // 超大文件退化为“整段替换”，避免 O(n*m) 的 DP 占用过多内存。
        guard a.count * b.count <= 4_000_000 else {
            return a.map { .remove($0) } + b.map { .insert($0) }
        }

        let n = a.count
        let m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var ops: [Op] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.remove(a[i]))
                i += 1
            } else {
                ops.append(.insert(b[j]))
                j += 1
            }
        }
        while i < n { ops.append(.remove(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }
}
