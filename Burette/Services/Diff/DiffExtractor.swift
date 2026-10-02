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
}
