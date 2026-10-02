import Foundation

enum GitDataError: Error, LocalizedError {
    case noStagedChanges
    case emptyRepository

    var errorDescription: String? {
        switch self {
        case .noStagedChanges:
            return "没有已暂存的改动。"
        case .emptyRepository:
            return "仓库为空，没有可拉取的文件。"
        }
    }
}

/// 一次提交多个文件：GitHub Git Data API 六步流程。
///
/// ref -> commit -> blob x N -> tree -> commit -> 更新 ref。
/// 任何一步失败都会抛出错误，不会产生半成品提交。
struct GitDataService: Sendable {
    let client: GitHubClient

    func commit(
        repository: Repository,
        changes: [FileChange],
        message: String
    ) async throws -> String {
        let owner = repository.owner
        let repo = repository.name
        let branch = repository.currentBranch

        // 1. 分支当前指向的 commit
        let ref = try await client.ref(owner: owner, repo: repo, branch: branch)

        // 2. 该 commit 的 tree
        let detail = try await client.commitDetail(owner: owner, repo: repo, sha: ref.object.sha)

        // 3. 为每个改动文件创建 blob
        var entries: [GitHubTreeEntry] = []
        for change in changes where change.isStaged {
            if change.status == .deleted {
                entries.append(GitHubTreeEntry(path: change.path, sha: nil))
            } else {
                let blob = try await client.createBlob(
                    owner: owner,
                    repo: repo,
                    content: change.current
                )
                entries.append(GitHubTreeEntry(path: change.path, sha: blob.sha))
            }
        }
        guard !entries.isEmpty else { throw GitDataError.noStagedChanges }

        // 4. 生成新 tree
        let tree = try await client.createTree(
            owner: owner,
            repo: repo,
            baseTree: detail.tree.sha,
            entries: entries
        )

        // 5. 生成新 commit
        let commit = try await client.createCommit(
            owner: owner,
            repo: repo,
            message: message,
            tree: tree.sha,
            parents: [ref.object.sha]
        )

        // 6. 移动分支引用
        try await client.updateRef(
            owner: owner,
            repo: repo,
            branch: branch,
            sha: commit.sha
        )

        return commit.sha
    }
}
