import Foundation

/// 一段提供给 AI 的文件内容。
struct FileContext: Sendable, Hashable {
    let path: String
    let content: String
}

/// 负责把仓库文件树、按需读取到的文件内容与用户指令组装成对话消息。
///
/// 主路径与 Codex 一致：模型通过**函数工具**探索仓库、读取文件、
/// 用 apply_patch 提交改动；仅当接口不支持工具调用时，才回退到
/// 「<<READ: 路径>> + unified diff」的文本协议。
enum PromptBuilder {

    /// 文本回退协议里模型请求读取文件的标记前缀。
    static let readMarker = "<<READ"

    // MARK: - 系统提示

    /// 工具模式系统提示。
    static let systemPrompt = """
    你是与 Burette（iOS 代码助手）配合的资深编程 agent，工作方式与 Codex 一致：
    先用工具探索仓库、读取真实文件，再用 apply_patch 提交改动，而不是凭记忆猜测。

    可用工具：
    - list_files：列出仓库文件，可用 path 参数只看某个目录。
    - read_file：读取某个文件的内容（可用 start_line / end_line 只看片段）。
    - grep：按正则搜索仓库内容，返回「路径:行号: 内容」。
    - apply_patch：用 *** Begin Patch ... *** End Patch 格式提交代码改动，可一次改多个文件。

    工作规则：
    1. 需要文件内容时必须调用 read_file 实际读取，绝不要凭记忆猜测文件内容。
    2. 修改某个文件之前，必须先 read_file 读取它的最新内容；没有读过的文件不要改。
    3. 需要定位代码时优先用 grep，而不是逐个猜文件。
    4. 可以一次修改多个文件，每个文件单独一个 *** Update File / *** Add File / *** Delete File 段落。
    5. apply_patch 会由 App 执行并把结果返回给你；如果返回失败，请 read_file 读取最新内容后重新提交，不要重复提交同一个补丁。
    6. 完成后用一两句中文说明你做了什么、改了哪些文件；不要输出 diff 原文，也不要输出工具调用文本。

    apply_patch 格式（严格照此书写）：
    *** Begin Patch
    *** Update File: 相对路径
    @@
     上下文行（行首一个空格）
    -要删除的行
    +要新增的行
     上下文行
    *** Add File: 相对路径
    +新文件的一行
    *** Delete File: 相对路径
    *** End Patch

    格式要求：
    - 每个改动块用 @@ 开头；@@ 后面可以带一小段定位用的上下文，也可以不带。
    - 上下文行、删除行、新增行都必须以空格 / - / + 开头，且与文件里的内容逐字一致（含缩进）。
    - 每个改动前后各保留 2~3 行上下文，便于定位；不要输出整份文件。
    - 路径必须与文件树里的相对路径完全一致，不要带 a/ b/ 前缀。
    """

    /// 文本回退模式系统提示（接口不支持工具调用时使用）。
    static let textPrompt = """
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
        systemMessage(config: config, base: systemPrompt)
    }

    static func textSystemMessage(config: AIProviderConfig) -> AIChatMessage {
        systemMessage(config: config, base: textPrompt)
    }

    private static func systemMessage(config: AIProviderConfig, base: String) -> AIChatMessage {
        var text = base
        if let extra = config.extraInstructions, !extra.isEmpty {
            text += "\n\n补充约定：\n" + extra
        }
        return AIChatMessage(role: "system", content: text)
    }

    // MARK: - 上下文消息

    /// 初始上下文：文件树 + 当前 git 状态等基本信息。
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
            text += "\n…（文件树过长，仅列出前 \(lines.count) 个路径；可用 list_files 或 grep 查找其余文件）"
        }

        text += "\n\n需要某个文件的内容时请调用 read_file；需要定位符号时调用 grep；修改代码用 apply_patch。"
        return AIChatMessage(role: "user", content: text)
    }

    /// 把之前几轮读过的文件内容带回来，减少重复读取、保持跨轮一致。
    static func memoryMessage(files: [(path: String, content: String)]) -> AIChatMessage? {
        guard !files.isEmpty else { return nil }
        var text = "以下是之前几轮读取过的文件内容，可能已过期；改动前请用 read_file 重新确认最新内容：\n"
        for file in files {
            text += "\n===== \(file.path) =====\n"
            text += file.content
            text += "\n===== end \(file.path) =====\n"
        }
        return AIChatMessage(role: "user", content: text)
    }

    /// 工具执行结果。
    static func toolResultMessage(callID: String, name: String, content: String) -> AIChatMessage {
        AIChatMessage(role: "tool", content: content, toolCallID: callID)
    }

    /// 把按需读取到的文件内容发回给模型（文本回退模式）。
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

    // MARK: - 文本回退协议解析

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
