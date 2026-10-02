import Foundation

/// 从模型回复中提取 unified diff 文本。
enum DiffExtractor {

    private static let fence = "\u{0060}\u{0060}\u{0060}"

    static func extract(from text: String) -> String {
        if let fenced = fencedBlock(in: text) {
            return fenced
        }
        return fromFirstHeader(in: text)
    }

    /// 取第一个包含 hunk 头的代码块。
    private static func fencedBlock(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            if lines[index].hasPrefix(fence) {
                var body: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                let content = body.joined(separator: "\n")
                if content.contains("@@ -") || content.contains("--- ") {
                    return content
                }
            }
            index += 1
        }
        return nil
    }

    /// 退回策略：从第一处 diff 头开始直到结尾。
    private static func fromFirstHeader(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("diff --git ") || $0.hasPrefix("--- ")
        }) else {
            return text
        }
        return lines[start...].joined(separator: "\n")
    }
    /// 去掉 diff 部分后剩下的说明文字，用于对话界面展示。
    static func prose(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            if lines[index].hasPrefix(fence) {
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count && !lines[cursor].hasPrefix(fence) {
                    body.append(lines[cursor])
                    cursor += 1
                }
                let content = body.joined(separator: "\n")
                let isDiff = content.contains("@@ -") || content.contains("--- ")
                if isDiff {
                    index = cursor < lines.count ? cursor + 1 : cursor
                    continue
                }
            }
            kept.append(lines[index])
            index += 1
        }

        var result = kept.joined(separator: "\n")
        let remaining = result.components(separatedBy: "\n")
        if let start = remaining.firstIndex(where: {
            $0.hasPrefix("diff --git ") || $0.hasPrefix("@@ -")
        }) {
            result = remaining[..<start].joined(separator: "\n")
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "已根据你的要求更新项目。" : trimmed
    }
}
