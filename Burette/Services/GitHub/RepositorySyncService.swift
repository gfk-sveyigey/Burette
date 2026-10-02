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

    /// 拉取指定分支到工作区，返回 base commit SHA 与写入的文件数。
    @discardableResult
    func pull(
        repository: Repository,
        branch: String? = nil
    ) async throws -> (sha: String, fileCount: Int) {
        let owner = repository.owner
        let repo = repository.name
        let targetBranch = branch ?? repository.currentBranch

        let ref = try await client.ref(owner: owner, repo: repo, branch: targetBranch)
        let commitSHA = ref.object.sha
        let detail = try await client.commitDetail(owner: owner, repo: repo, sha: commitSHA)
        let tree = try await client.tree(owner: owner, repo: repo, sha: detail.tree.sha, recursive: true)

        let blobs = tree.tree.filter { $0.type == "blob" }
        guard !blobs.isEmpty else { throw GitDataError.emptyRepository }

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

        return (commitSHA, written)
    }
}
