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
    1. 用户会给出仓库文件树，以及相关文件的完整内容，全部在紧随其后的上下文消息里（用 "===== 路径 =====" 包裹）。
    2. 直接基于这些内容工作，不要要求用户粘贴文件，也不要回复「我没有收到文件」；上下文消息里会明确说明是否已包含全部文件、以及哪些文件因体积原因未附带——需要时请直接列出要查看的路径。只有上下文里确实一个文件都没有时，才提醒用户先在「仓库」页拉取项目。
    3. 根据用户的修改要求，直接给出 unified diff。
    4. 只输出 diff，不要输出解释性文字。

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

    /// 把文件树与文件内容打包成一条上下文消息。
    static func contextMessage(fileTree: [String], files: [FileContext], omitted: [String] = []) -> AIChatMessage {
        var text = "仓库文件树（共 \(fileTree.count) 个文件）：\n"
        text += fileTree.prefix(2_000).joined(separator: "\n")
        if fileTree.count > 2_000 {
            text += "\n…（文件树过长已截断）"
        }

        if files.isEmpty {
            text += "\n\n（本次没有附带任何文件内容，工作区可能是空的。）"
        } else {
            text += "\n\n以下是这些文件的完整内容（共 \(files.count) 个）：\n"
            for file in files {
                text += "\n===== \(file.path) =====\n"
                text += file.content
                text += "\n===== end \(file.path) =====\n"
            }
            if omitted.isEmpty {
                text += "\n以上已包含工作区里的全部文本文件，不需要再向用户索要文件。\n"
            } else {
                text += "\n因体积限制，以下 \(omitted.count) 个文件这次没有附带内容，需要时请在回复里明确列出要看的路径（不要泛泛地说「文件缺失」）：\n"
                text += omitted.map { "- " + $0 }.joined(separator: "\n")
                text += "\n"
            }
        }
        return AIChatMessage(role: "user", content: text)
    }

    /// 一次上下文组装的产物。
    struct ContextBundle {
        let files: [FileContext]
        /// 因预算不足而未附带内容的文件路径（会明确告诉模型，避免它说「文件缺失」）。
        let omitted: [String]

        var totalCharacters: Int { files.reduce(0) { $0 + $1.content.count } }
    }

    /// 组装上下文文件。
    ///
    /// 默认预算足够放下一个中等规模的项目（覆盖不了所有文件时会明确列出未附带的路径，
    /// 而不是静默丢弃导致模型误以为没有文件）。
    static func contextBundle(
        for instruction: String,
        snapshot: [String: String],
        budget: Int = 800_000,
        perFileLimit: Int = 200_000
    ) -> ContextBundle {
        let total = snapshot.values.reduce(0) { $0 + $1.count }

        // 小仓库直接全量；大仓库先放相关文件，再按剩余预算补齐其余文件。
        var ordered: [String] = []
        var seen = Set<String>()
        if total <= budget {
            ordered = snapshot.keys.sorted()
        } else {
            for file in relevantFiles(for: instruction, in: snapshot, limit: 30) {
                if seen.insert(file.path).inserted { ordered.append(file.path) }
            }
            for path in snapshot.keys.sorted() {
                if seen.insert(path).inserted { ordered.append(path) }
            }
        }

        var remaining = budget
        var result: [FileContext] = []
        var omitted: [String] = []
        var truncated = false

        for path in ordered {
            guard let content = snapshot[path] else { continue }
            if remaining <= 0 {
                omitted.append(path)
                continue
            }
            if content.count > perFileLimit {
                result.append(
                    FileContext(path: path, content: String(content.prefix(perFileLimit)) + "\n…（内容过长已截断）")
                )
                remaining -= perFileLimit
                truncated = true
            } else if content.count <= remaining {
                result.append(FileContext(path: path, content: content))
                remaining -= content.count
            } else {
                // 剩余预算放不下整个文件：宁可完整放入（大文件仍然有价值），否则记为未附带。
                if content.count <= perFileLimit {
                    result.append(FileContext(path: path, content: content))
                    remaining -= content.count
                } else {
                    omitted.append(path)
                }
            }
        }

        if truncated {
            Log.warning("上下文中有文件因过长被截断", .ai)
        }
        return ContextBundle(files: result, omitted: omitted)
    }

    /// 兼容旧调用：只取文件列表。
    static func contextFiles(
        for instruction: String,
        snapshot: [String: String],
        budget: Int = 800_000,
        perFileLimit: Int = 200_000
    ) -> [FileContext] {
        contextBundle(for: instruction, snapshot: snapshot, budget: budget, perFileLimit: perFileLimit).files
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
