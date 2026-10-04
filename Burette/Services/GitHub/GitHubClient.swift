import Foundation

enum GitHubError: Error, LocalizedError {
    case invalidURL(String)
    case missingToken
    case unauthorized
    case notFound
    case rateLimited
    case insufficientScope(String)
    case http(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "无法构造 GitHub 请求地址：\(path)"
        case .missingToken:
            return "尚未登录 GitHub，请先填写 Personal Access Token。"
        case .unauthorized:
            return "GitHub 认证失败，请检查 PAT 是否有效、是否具备所需权限。"
        case .notFound:
            return "GitHub 资源不存在（404）。"
        case .rateLimited:
            return "GitHub 请求达到频率限制，请稍后再试。"
        case .insufficientScope(let detail):
            return """
            GitHub 拒绝了这次操作，通常是令牌权限不足。
            请确认 PAT 权限：
            · 经典令牌：勾选 repo（完整仓库读写；私有仓库必需）
            · 细粒度令牌：Contents 设为 Read and write，并勾选 Metadata: Read
            \(detail.isEmpty ? "" : "详情：" + detail)
            """
        case .http(let status, let message):
            return "GitHub 返回错误（HTTP \(status)）：\(message)"
        case .decoding(let message):
            return "解析 GitHub 响应失败：\(message)"
        }
    }
}

/// 对 GitHub REST API 的薄封装，负责鉴权、请求与解码。
actor GitHubClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private var token: String?
    private var scopes: Set<String> = []

    init(
        baseURL: URL = URL(string: "https://api.github.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func updateToken(_ token: String?) {
        self.token = token
    }

    /// 最近一次响应头里带回的令牌权限（X-OAuth-Scopes）。
    func currentScopes() -> [String] {
        scopes.sorted()
    }

    // MARK: - 账户与仓库

    func currentUser() async throws -> GitHubUser {
        try await get("/user")
    }

    func repositories(perPage: Int = 100) async throws -> [GitHubRepository] {
        try await get("/user/repos", query: [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")
        ])
    }

    func branches(owner: String, repo: String) async throws -> [GitHubBranch] {
        try await get("/repos/\(owner)/\(repo)/branches")
    }

    func commits(owner: String, repo: String, branch: String) async throws -> [GitHubCommitSummary] {
        try await get("/repos/\(owner)/\(repo)/commits", query: [
            URLQueryItem(name: "sha", value: branch)
        ])
    }

    // MARK: - Git Data API

    func ref(owner: String, repo: String, branch: String) async throws -> GitHubRef {
        try await get("/repos/\(owner)/\(repo)/git/ref/heads/\(branch)")
    }

    func commitDetail(owner: String, repo: String, sha: String) async throws -> GitHubCommitDetail {
        try await get("/repos/\(owner)/\(repo)/git/commits/\(sha)")
    }

    func tree(owner: String, repo: String, sha: String, recursive: Bool = true) async throws -> GitHubTreeDetail {
        try await get(
            "/repos/\(owner)/\(repo)/git/trees/\(sha)",
            query: recursive ? [URLQueryItem(name: "recursive", value: "1")] : []
        )
    }

    func blob(owner: String, repo: String, sha: String) async throws -> GitHubBlobDetail {
        try await get("/repos/\(owner)/\(repo)/git/blobs/\(sha)")
    }

    func createBlob(owner: String, repo: String, content: String) async throws -> GitHubBlob {
        struct Body: Encodable {
            let content: String
            let encoding: String
        }
        return try await post(
            "/repos/\(owner)/\(repo)/git/blobs",
            body: Body(content: content, encoding: "utf-8")
        )
    }

    func createTree(
        owner: String,
        repo: String,
        baseTree: String?,
        entries: [GitHubTreeEntry]
    ) async throws -> GitHubTree {
        struct Body: Encodable {
            let base_tree: String?
            let tree: [GitHubTreeEntry]
        }
        return try await post(
            "/repos/\(owner)/\(repo)/git/trees",
            body: Body(base_tree: baseTree, tree: entries)
        )
    }

    func createCommit(
        owner: String,
        repo: String,
        message: String,
        tree: String,
        parents: [String]
    ) async throws -> GitHubCreatedCommit {
        struct Body: Encodable {
            let message: String
            let tree: String
            let parents: [String]
        }
        return try await post(
            "/repos/\(owner)/\(repo)/git/commits",
            body: Body(message: message, tree: tree, parents: parents)
        )
    }

    func updateRef(
        owner: String,
        repo: String,
        branch: String,
        sha: String,
        force: Bool = false
    ) async throws {
        struct Body: Encodable {
            let sha: String
            let force: Bool
        }
        let _: GitHubRef = try await patch(
            "/repos/\(owner)/\(repo)/git/refs/heads/\(branch)",
            body: Body(sha: sha, force: force)
        )
    }

    // MARK: - Actions

    /// 列出仓库的 workflow 运行记录，可按分支过滤。
    func workflowRuns(
        owner: String,
        repo: String,
        branch: String? = nil,
        perPage: Int = 30
    ) async throws -> GitHubWorkflowRuns {
        var query = [URLQueryItem(name: "per_page", value: String(perPage))]
        if let branch, !branch.isEmpty {
            query.append(URLQueryItem(name: "branch", value: branch))
        }
        return try await get("/repos/\(owner)/\(repo)/actions/runs", query: query)
    }

    func workflowRun(owner: String, repo: String, runID: Int) async throws -> GitHubWorkflowRun {
        try await get("/repos/\(owner)/\(repo)/actions/runs/\(runID)")
    }

    func workflowJobs(owner: String, repo: String, runID: Int) async throws -> GitHubWorkflowJobs {
        try await get("/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs")
    }

    /// 重新运行整个 workflow（需要 actions: write 权限）。
    func rerunWorkflow(owner: String, repo: String, runID: Int) async throws {
        _ = try await send(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)/rerun",
            query: [],
            body: nil
        )
    }

    /// 拉取某个 job 的日志（GitHub 返回 zip，本地解出文本）。
    func jobLogs(owner: String, repo: String, jobID: Int) async throws -> String {
        let data = try await send(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/actions/jobs/\(jobID)/logs",
            query: [],
            body: nil
        )
        let entries = try ZipReader.entries(from: data)
        // 日志包里通常是一个文本文件；按包内顺序拼接，兼容多文件的情况。
        let parts = entries
            .filter { !$0.data.isEmpty }
            .map { String(decoding: $0.data, as: UTF8.self) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { throw GitHubError.decoding("日志压缩包里没有可用内容。") }
        return parts.joined(separator: "\n")
    }

    /// 取消进行中的 workflow。
    func cancelWorkflow(owner: String, repo: String, runID: Int) async throws {
        _ = try await send(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)/cancel",
            query: [],
            body: nil
        )
    }

    // MARK: - 传输层

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(method: "GET", path: path, query: query, body: nil)
        return try decode(data)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try await send(method: "POST", path: path, query: [], body: try JSONEncoder().encode(body))
        return try decode(data)
    }

    private func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try await send(method: "PATCH", path: path, query: [], body: try JSONEncoder().encode(body))
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty else {
            throw GitHubError.decoding("服务端返回了空响应体。")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    private func send(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubError.invalidURL(path)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw GitHubError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Burette", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw GitHubError.missingToken
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        Log.debug("GitHub → \(method) \(path)（请求体 \(body?.count ?? 0) 字节）", .github)
        let startedAt = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Cancellation.isCancellation(error) {
                Log.debug("GitHub \(method) \(path) 请求已取消", .github)
            } else {
                Log.error("GitHub \(method) \(path) 网络失败：\(error.localizedDescription)", .github)
            }
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            Log.error("GitHub \(method) \(path) 返回了无效响应", .github)
            throw GitHubError.http(status: -1, message: "无效的服务器响应。")
        }

        if let scopeHeader = http.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            scopes = Set(
                scopeHeader
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        let bodyPreview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""

        switch http.statusCode {
        case 200..<300:
            Log.debug("GitHub ← \(http.statusCode) \(method) \(path)（\(data.count) 字节，\(elapsed) ms）", .github)
            return data
        case 401:
            Log.error("GitHub ← 401 \(method) \(path)（\(elapsed) ms）", .github)
            throw GitHubError.unauthorized
        case 403:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                Log.error("GitHub ← 403 频率限制 \(method) \(path)（\(elapsed) ms）", .github)
                throw GitHubError.rateLimited
            }
            Log.error("GitHub ← 403 权限不足 \(method) \(path)（\(elapsed) ms）：\(bodyPreview)", .github)
            throw GitHubError.insufficientScope(bodyPreview)
        case 404:
            Log.error("GitHub ← 404 \(method) \(path)（\(elapsed) ms）：\(bodyPreview)", .github)
            throw GitHubError.notFound
        default:
            Log.error("GitHub ← \(http.statusCode) \(method) \(path)（\(elapsed) ms）：\(bodyPreview)", .github)
            throw GitHubError.http(status: http.statusCode, message: bodyPreview)
        }
    }
}
