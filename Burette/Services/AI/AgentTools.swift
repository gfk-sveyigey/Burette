import Foundation

/// 提供给模型的函数工具：定义 + 只读工具的执行。
///
/// apply_patch 需要落盘并记录改动，由 AppEnvironment 执行，这里只负责解析参数返回 nil。
enum AgentTools {

    static let applyPatchName = "apply_patch"

    /// 单次 read_file 返回的最大字符数。
    static let readLimit = 120_000
    /// grep 默认 / 最大返回条数。
    static let grepDefaultLimit = 100
    static let grepMaxLimit = 500

    // MARK: - 工具定义

    static let specs: [AITool] = [
        AITool(
            name: "list_files",
            description: "列出仓库里的文件路径，可按目录前缀过滤。用于确认某个目录下有哪些文件。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("目录前缀，例如 Burette/App；留空表示整个仓库。")
                    ])
                ]),
                "required": .array([])
            ])
        ),
        AITool(
            name: "read_file",
            description: "读取仓库中某个文件的内容。改动文件前必须先读取它。可选 start_line / end_line 只读片段。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("相对仓库根目录的文件路径，必须与文件树一致。")
                    ]),
                    "start_line": .object([
                        "type": .string("integer"),
                        "description": .string("起始行号（从 1 开始，可选）。")
                    ]),
                    "end_line": .object([
                        "type": .string("integer"),
                        "description": .string("结束行号（含，可选）。")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        ),
        AITool(
            name: "grep",
            description: "用正则表达式在仓库里搜索，返回「路径:行号: 内容」。用于定位符号、函数或字符串。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("正则表达式；失败时会按普通文本匹配。")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("只搜索该目录前缀（可选）。")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("最多返回条数，默认 100。")
                    ])
                ]),
                "required": .array([.string("pattern")])
            ])
        ),
        AITool(
            name: applyPatchName,
            description: "以 *** Begin Patch ... *** End Patch 格式提交代码改动，可同时修改多个文件。App 会执行并返回结果。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "patch": .object([
                        "type": .string("string"),
                        "description": .string("完整的 apply_patch 文本，包含 *** Begin Patch 与 *** End Patch。")
                    ])
                ]),
                "required": .array([.string("patch")])
            ])
        )
    ]

    // MARK: - 参数

    struct Arguments: Decodable, Sendable {
        var path: String?
        var start_line: Int?
        var end_line: Int?
        var pattern: String?
        var max_results: Int?
        var patch: String?
    }

    static func arguments(from json: String) -> Arguments {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return Arguments()
        }
        return value
    }

    /// 给界面 / 灵动岛用的简短描述。
    static func stepDescription(name: String, arguments: Arguments) -> String {
        switch name {
        case "list_files":
            let path = (arguments.path ?? "").trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? "列出仓库文件" : "列出 \(path)"
        case "read_file":
            return "读取 \(arguments.path ?? "文件")"
        case "grep":
            return "搜索 \(arguments.pattern ?? "")"
        case applyPatchName:
            return "应用代码改动"
        default:
            return name
        }
    }

    // MARK: - 只读工具执行

    /// 执行只读工具；apply_patch 由调用方处理，这里返回 nil。
    static func run(
        name: String,
        arguments: Arguments,
        fileTree: [String],
        repository: Repository,
        workspace: WorkspaceManager
    ) -> String? {
        switch name {
        case "list_files":
            return listFiles(arguments, fileTree: fileTree)
        case "read_file":
            return readFile(arguments, repository: repository, workspace: workspace)
        case "grep":
            return grep(arguments, fileTree: fileTree, repository: repository, workspace: workspace)
        default:
            return nil
        }
    }

    private static func listFiles(_ arguments: Arguments, fileTree: [String]) -> String {
        let prefix = (arguments.path ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t/"))
        let matched = prefix.isEmpty
            ? fileTree
            : fileTree.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
        guard !matched.isEmpty else { return "（没有匹配的文件）" }

        let limited = Array(matched.prefix(500))
        var text = limited.joined(separator: "\n")
        if matched.count > limited.count {
            text += "\n…（共 \(matched.count) 个，已截断）"
        }
        return text
    }

    private static func readFile(
        _ arguments: Arguments,
        repository: Repository,
        workspace: WorkspaceManager
    ) -> String {
        let path = (arguments.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "错误：缺少 path 参数。" }

        let content = (try? workspace.read(repository: repository, path: path)) ?? nil
        guard let content else { return "错误：找不到文件 \(path)。请用 list_files 或 grep 确认路径。" }

        if arguments.start_line == nil && arguments.end_line == nil {
            if content.count > readLimit {
                return String(content.prefix(readLimit)) + "\n…（内容过长，已截断；可用 start_line / end_line 读取其余部分）"
            }
            return content.isEmpty ? "（文件为空）" : content
        }

        let lines = content.components(separatedBy: "\n")
        let start = max(1, arguments.start_line ?? 1)
        let end = min(lines.count, arguments.end_line ?? lines.count)
        guard start <= end else { return "错误：行号范围无效（start_line > end_line）。" }
        return lines[(start - 1)...(end - 1)].joined(separator: "\n")
    }

    private static func grep(
        _ arguments: Arguments,
        fileTree: [String],
        repository: Repository,
        workspace: WorkspaceManager
    ) -> String {
        let pattern = arguments.pattern ?? ""
        guard !pattern.isEmpty else { return "错误：缺少 pattern 参数。" }

        let limit = max(1, min(arguments.max_results ?? grepDefaultLimit, grepMaxLimit))
        let scope = (arguments.path ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t/"))
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

        var results: [String] = []
        outer: for path in fileTree {
            if !scope.isEmpty && path != scope && !path.hasPrefix(scope + "/") { continue }
            let content = (try? workspace.read(repository: repository, path: path)) ?? nil
            guard let content else { continue }

            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
                } else {
                    matched = line.range(of: pattern, options: .caseInsensitive) != nil
                }
                if matched {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    results.append("\(path):\(index + 1): \(trimmed)")
                    if results.count >= limit { break outer }
                }
            }
        }

        return results.isEmpty ? "（没有匹配「\(pattern)」的内容）" : results.joined(separator: "\n")
    }
}
