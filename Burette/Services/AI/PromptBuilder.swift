import Foundation

/// 一段提供给 AI 的文件内容。
struct FileContext: Sendable, Hashable {
    let path: String
    let content: String
}

/// 负责把仓库上下文与用户指令组装成对话消息。
enum PromptBuilder {

    static let systemPrompt = """
    你是一个严谨的代码修改助手，与 Burette（iOS 代码助手）配合工作。

    工作方式：
    1. 用户会给出仓库文件树，以及相关文件的完整内容。
    2. 根据用户的修改要求，直接给出 unified diff。
    3. 只输出 diff，不要输出解释性文字。

    diff 规范：
    - 每个文件以 "--- " 与 "+++ " 两行开头，路径带 a/ 与 b/ 前缀；新增文件用 /dev/null。
    - 每个修改块以 @@ -旧起始,行数 +新起始,行数 @@ 开头。
    - 上下文行以空格开头，新增行以 + 开头，删除行以 - 开头。
    - 不要臆造未提供的文件内容，上下文行必须与给定内容完全一致。
    - @@ 行号必须与给定内容一致；行号错误会导致改动无法应用，请务必核对。
    - 每个文件的 --- / +++ 路径必须与上下文里该文件的真实路径一致，不要把 A 文件的内容标成 B 文件。
    - 上下文行必须从给定内容里逐字复制（含缩进），不要凭记忆改写或重新排版。
    - 用最小 hunk：前后各保留 3 行上下文即可，不要输出整份文件；改动大就拆成多个小 hunk。
    - 输出前逐行核对：每个删除行都必须能在给定内容里原样找到。
    - 如果要求不明确，先提出一个澄清问题，不要输出 diff。
    """

    static func systemMessage(config: AIProviderConfig) -> AIChatMessage {
        var text = systemPrompt
        if let extra = config.extraInstructions, !extra.isEmpty {
            text += "\n\n补充约定：\n" + extra
        }
        return AIChatMessage(role: "system", content: text)
    }

    /// 把文件树与相关文件内容打包成一条上下文消息。
    static func contextMessage(fileTree: [String], files: [FileContext]) -> AIChatMessage {
        var text = "仓库文件树：\n"
        text += fileTree.prefix(400).joined(separator: "\n")

        if !files.isEmpty {
            text += "\n\n相关文件内容：\n"
            for file in files {
                text += "\n===== \(file.path) =====\n"
                text += file.content
                text += "\n===== end \(file.path) =====\n"
            }
        }
        return AIChatMessage(role: "user", content: text)
    }

    /// 组装上下文文件：总长度在预算内时包含全部文件，超出时优先相关文件并做截断，
    /// 避免一次请求塞入整个大仓库导致耗时过长或超时。
    static func contextFiles(
        for instruction: String,
        snapshot: [String: String],
        budget: Int = 120_000,
        perFileLimit: Int = 24_000
    ) -> [FileContext] {
        let total = snapshot.values.reduce(0) { $0 + $1.count }
        var ordered: [String] = []
        var seen = Set<String>()

        if total <= budget {
            ordered = snapshot.keys.sorted()
        } else {
            for file in relevantFiles(for: instruction, in: snapshot, limit: 20) {
                if seen.insert(file.path).inserted { ordered.append(file.path) }
            }
            for path in snapshot.keys.sorted() {
                if seen.insert(path).inserted { ordered.append(path) }
            }
        }

        var remaining = budget
        var result: [FileContext] = []
        for path in ordered {
            guard remaining > 0, let content = snapshot[path] else { break }
            if content.count > perFileLimit {
                result.append(
                    FileContext(path: path, content: String(content.prefix(perFileLimit)) + "\n…（内容过长已截断）")
                )
                remaining -= perFileLimit
            } else {
                result.append(FileContext(path: path, content: content))
                remaining -= content.count
            }
        }
        return result
    }

    /// 根据用户指令挑选相关文件（按路径或内容包含关键词打分）。
    static func relevantFiles(
        for instruction: String,
        in snapshot: [String: String],
        limit: Int = 5
    ) -> [FileContext] {
        let keywords = instruction
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "." && $0 != "_" })
            .map(String.init)
            .filter { $0.count >= 2 }

        guard !keywords.isEmpty else {
            return snapshot.keys.sorted().prefix(limit).compactMap { path in
                snapshot[path].map { FileContext(path: path, content: $0) }
            }
        }

        var scored: [(score: Int, path: String)] = []
        for (path, content) in snapshot {
            let haystack = (path + "\n" + content).lowercased()
            var score = 0
            for keyword in keywords where haystack.contains(keyword) {
                score += path.lowercased().contains(keyword) ? 3 : 1
            }
            if score > 0 { scored.append((score, path)) }
        }

        return scored
            .sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
            .prefix(limit)
            .compactMap { item -> FileContext? in
                guard let content = snapshot[item.path] else { return nil }
                return FileContext(path: item.path, content: content)
            }
    }
}
