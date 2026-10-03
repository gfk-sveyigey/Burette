import Foundation

/// 一段提供给 AI 的文件内容。
struct FileContext: Sendable, Hashable {
    let path: String
    let content: String
}

/// 负责把仓库文件树、按需读取到的文件内容与用户指令组装成对话消息。
///
/// 工作方式与 Codex 类似：上下文里只放**文件树**，模型需要某个文件时用
/// <<READ: 路径>> 索取，由 App 读取后再送回模型，循环直到模型给出 diff。
enum PromptBuilder {

    /// 模型请求读取文件的标记前缀，例如 <<READ: Burette/App/AppEnvironment.swift>>。
    static let readMarker = "<<READ"

    static let systemPrompt = """
    你是一个严谨的代码修改助手，与 Burette（iOS 代码助手）配合工作。
    你和 Codex 一样按需读取文件：上下文里只会给你仓库文件树，需要看哪个文件就主动索取。

    工作方式：
    1. 你会先收到仓库的完整文件树（只有路径，没有内容）。
    2. 需要查看某个文件时，不要凭记忆猜内容，单独输出一行请求标记：
       <<READ: 路径>>
       路径必须与文件树里的完全一致；一行一个，可以一次请求多个。
    3. App 会把请求的文件内容发回给你，然后你继续工作。
    4. 信息足够时，直接输出 unified diff，不要再输出任何说明文字。
    5. 只有文件树里确实没有某个路径时，才说明它不存在；不要声称「文件缺失」，也不要要求用户粘贴代码——需要什么就用 <<READ: 路径>> 索取。
    6. 如果要求不明确，先提出一个澄清问题，不要输出 diff。

    diff 规范：
    - 每个文件以 "--- " 与 "+++ " 两行开头，路径带 a/ 与 b/ 前缀；新增文件用 /dev/null。
    - 每个修改块以 @@ -旧起始,行数 +新起始,行数 @@ 开头。
    - 上下文行以空格开头，新增行以 + 开头，删除行以 - 开头。
    - 不要臆造未读取过的文件内容，上下文行必须与给你的内容完全一致。
    - @@ 行号必须与你读到的内容一致；行号错误会导致改动无法应用，请务必核对。
    - 每个文件的 --- / +++ 路径必须与文件树里的真实路径一致，不要把 A 文件的内容标成 B 文件。
    - 上下文行必须从内容里逐字复制（含缩进），不要凭记忆改写或重新排版。
    - 用最小 hunk：前后各保留 3 行上下文即可，不要输出整份文件；改动大就拆成多个小 hunk。
    - 输出前逐行核对：每个删除行都必须能在对应文件内容里原样找到。
    """

    static func systemMessage(config: AIProviderConfig) -> AIChatMessage {
        var text = systemPrompt
        if let extra = config.extraInstructions, !extra.isEmpty {
            text += "\n\n补充约定：\n" + extra
        }
        return AIChatMessage(role: "system", content: text)
    }

    /// 初始上下文：只给文件树，让模型按需索取文件内容。
    static func treeMessage(fileTree: [String]) -> AIChatMessage {
        var text = "仓库文件树（共 \(fileTree.count) 个文件）：\n"

        // 文件树也要做体积保护：路径再多也不该把提示词撑爆。
        var lines: [String] = []
        var chars = 0
        for line in fileTree {
            if chars + line.count > 60_000 { break }
            lines.append(line)
            chars += line.count + 1
        }
        text += lines.joined(separator: "\n")
        if lines.count < fileTree.count {
            text += "\n…（文件树过长，仅列出前 \(lines.count) 个路径）"
        }

        text += "\n\n需要查看某个文件时，请输出 <<READ: 路径>>（路径需与上面完全一致，可一次请求多个）；信息足够后直接给出 unified diff。"
        return AIChatMessage(role: "user", content: text)
    }

    /// 把按需读取到的文件内容发回给模型。
    static func readResultMessage(
        requested: [String],
        files: [FileContext],
        missing: [String]
    ) -> AIChatMessage {
        var text = "已按请求读取 \(files.count)/\(requested.count) 个文件：\n"
        for file in files {
            text += "\n===== \(file.path) =====\n"
            text += file.content
            text += "\n===== end \(file.path) =====\n"
        }

        if !missing.isEmpty {
            text += "\n以下路径在文件树里不存在，请不要再请求它们：\n"
            text += missing.map { "- \($0)" }.joined(separator: "\n")
            text += "\n"
        }

        text += "\n继续工作：还需要其它文件就继续用 <<READ: 路径>>；信息足够就直接输出 unified diff。"
        return AIChatMessage(role: "user", content: text)
    }

    /// 解析模型回复里的 <<READ: 路径>> 请求（去重、保序）。
    static func requestedPaths(in reply: String) -> [String] {
        var paths: [String] = []
        var index = reply.startIndex

        while let open = reply.range(of: readMarker, range: index..<reply.endIndex) {
            var cursor = open.upperBound
            // 兼容 <<READ: path>> 与 <<READ path>> 两种写法。
            while cursor < reply.endIndex,
                  reply[cursor] == ":" || reply[cursor] == " " || reply[cursor] == "\t" {
                cursor = reply.index(after: cursor)
            }
            guard let close = reply.range(of: ">>", range: cursor..<reply.endIndex) else { break }

            var path = String(reply[cursor..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{0060}"))
            if !path.isEmpty { paths.append(path) }
            index = close.upperBound
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// 从展示给用户的文本里去掉读取标记。
    static func strippingReadMarkers(_ text: String) -> String {
        var result = text
        while let open = result.range(of: readMarker) {
            guard let close = result.range(of: ">>", range: open.upperBound..<result.endIndex) else {
                result = String(result[result.startIndex..<open.lowerBound])
                break
            }
            result = String(result[result.startIndex..<open.lowerBound]) + String(result[close.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
