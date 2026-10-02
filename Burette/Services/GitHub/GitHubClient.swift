import Foundation

enum GitHubError: Error, LocalizedError {
    case invalidURL(String)
    case missingToken
    case unauthorized
    case notFound
    case rateLimited
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

        Log.debug("GitHub \(method) \(path)", .github)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Log.error("GitHub \(method) \(path) 返回了无效响应", .github)
            throw GitHubError.http(status: -1, message: "无效的服务器响应。")
        }

        switch http.statusCode {
        case 200..<300:
            Log.debug("GitHub \(method) \(path) → \(http.statusCode)", .github)
            return data
        case 401:
            Log.error("GitHub \(method) \(path) → 401 未授权", .github)
            throw GitHubError.unauthorized
        case 403:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                Log.error("GitHub \(method) \(path) → 403 频率限制", .github)
                throw GitHubError.rateLimited
            }
            Log.error("GitHub \(method) \(path) → 403 拒绝访问", .github)
            throw GitHubError.unauthorized
        case 404:
            Log.error("GitHub \(method) \(path) → 404 不存在", .github)
            throw GitHubError.notFound
        default:
            let message = String(data: data, encoding: .utf8) ?? ""
            Log.error("GitHub \(method) \(path) → \(http.statusCode)", .github)
            throw GitHubError.http(status: http.statusCode, message: message)
        }
    }
}
