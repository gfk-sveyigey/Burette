import Foundation

enum WorkspaceError: Error, LocalizedError {
    case outsideWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path):
            return "路径越出工作区范围：\(path)"
        }
    }
}

/// 管理本地工作区文件。
///
/// 所有路径都相对于仓库文件夹，并做越界校验，防止模型返回的
/// 相对路径（例如 ../../etc/passwd）写到工作区之外。
struct WorkspaceManager: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func folder(for repository: Repository) -> URL {
        root.appendingPathComponent(repository.workspaceFolder, isDirectory: true)
    }

    func fileURL(repository: Repository, path: String) throws -> URL {
        let base = folder(for: repository).standardizedFileURL
        let target = base.appendingPathComponent(path).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard target.path.hasPrefix(basePath) else {
            throw WorkspaceError.outsideWorkspace(path)
        }
        return target
    }

    func read(repository: Repository, path: String) throws -> String? {
        let url = try fileURL(repository: repository, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(repository: Repository, path: String, content: String) throws {
        let url = try fileURL(repository: repository, path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func delete(repository: Repository, path: String) throws {
        let url = try fileURL(repository: repository, path: path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func listFiles(repository: Repository) throws -> [String] {
        let base = folder(for: repository)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"

        var result: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                result.append(url.path.replacingOccurrences(of: basePath, with: ""))
            }
        }
        return result.sorted()
    }

    /// 读取工作区所有文本文件，供 AI 上下文与改动对比使用。
    func snapshot(repository: Repository) throws -> [String: String] {
        var contents: [String: String] = [:]
        for path in try listFiles(repository: repository) {
            if let text = try read(repository: repository, path: path) {
                contents[path] = text
            }
        }
        return contents
    }
}
