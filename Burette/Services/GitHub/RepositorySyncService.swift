import Foundation

/// 把远端仓库拉到本地工作区。
///
/// 只保存工作区文件，不维护 .git 目录；因此没有本地历史，
/// 分支切换与冲突处理都依赖远端 API。
struct RepositorySyncService: Sendable {
    let client: GitHubClient
    let workspace: WorkspaceManager

    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "pdf",
        "zip", "gz", "tar", "rar", "7z", "jar", "class", "so", "dylib",
        "a", "o", "bin", "exe", "dmg", "woff", "woff2", "ttf", "otf",
        "mp3", "wav", "mp4", "mov", "avi", "psd", "sketch"
    ]

    private func isBinary(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.binaryExtensions.contains(ext)
    }

    /// 逐目录遍历树，用于 GitHub 截断递归结果（超大仓库）时补全文件列表。
    private static func allEntries(
        client: GitHubClient,
        owner: String,
        repo: String,
        treeSHA: String
    ) async throws -> [GitHubTreeDetail.Entry] {
        var result: [GitHubTreeDetail.Entry] = []
        var queue: [String] = [treeSHA]
        var visited = Set<String>()

        while let sha = queue.popLast() {
            guard visited.insert(sha).inserted else { continue }
            let node = try await client.tree(owner: owner, repo: repo, sha: sha, recursive: false)
            for entry in node.tree {
                if entry.type == "tree" {
                    queue.append(entry.sha)
                } else {
                    result.append(entry)
                }
            }
        }
        return result
    }

    /// 拉取指定分支到工作区，返回 base commit SHA 与写入的文件数。
    @discardableResult
    func pull(
        repository: Repository,
        branch: String? = nil
    ) async throws -> (sha: String, fileCount: Int) {
        let owner = repository.owner
        let repo = repository.name
        let targetBranch = branch ?? repository.currentBranch
        let startedAt = Date()

        let ref = try await client.ref(owner: owner, repo: repo, branch: targetBranch)
        let commitSHA = ref.object.sha
        let detail = try await client.commitDetail(owner: owner, repo: repo, sha: commitSHA)
        var tree = try await client.tree(owner: owner, repo: repo, sha: detail.tree.sha, recursive: true)
        if tree.truncated == true {
            // GitHub 对超大仓库的递归树会截断（超过约 10 万条 / 7MB）。递归结果不完整会把
            // 「缺文件」直接带给 AI，因此改为逐目录遍历补全。
            Log.warning("仓库树被 GitHub 截断，改为逐目录遍历：\(owner)/\(repo)＠\(targetBranch)", .workspace)
            let entries = try await Self.allEntries(
                client: client,
                owner: owner,
                repo: repo,
                treeSHA: detail.tree.sha
            )
            tree = GitHubTreeDetail(sha: tree.sha, tree: entries, truncated: false)
        }

        let blobs = tree.tree.filter { $0.type == "blob" }
        guard !blobs.isEmpty else {
            Log.warning("远端仓库为空：\(owner)/\(repo)＠\(targetBranch)", .workspace)
            throw GitDataError.emptyRepository
        }
        Log.debug("拉取树：\(owner)/\(repo)＠\(targetBranch)，\(blobs.count) 个 blob，base \(commitSHA.prefix(7))", .workspace)

        // 清空旧工作区，避免残留上一次的文件
        let folder = workspace.folder(for: repository)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }

        var written = 0
        for entry in blobs where !isBinary(entry.path) {
            let blob = try await client.blob(owner: owner, repo: repo, sha: entry.sha)
            guard let content = blob.content,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters)
            else { continue }
            let text = String(decoding: data, as: UTF8.self)
            try workspace.write(repository: repository, path: entry.path, content: text)
            written += 1
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info("工作区就绪：\(owner)/\(repo)＠\(targetBranch)，写入 \(written) 个文件（跳过 \(blobs.count - written) 个二进制），用时 \(elapsed) ms", .workspace)
        return (commitSHA, written)
    }
}
