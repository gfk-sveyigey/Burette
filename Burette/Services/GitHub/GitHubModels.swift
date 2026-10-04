import Foundation

struct GitHubUser: Codable, Sendable {
    let login: String
    let name: String?
    let avatarUrl: URL?
}

struct GitHubRepository: Codable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let owner: GitHubUser
    let isPrivate: Bool
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName
        case owner
        case isPrivate = "private"
        case defaultBranch
    }
}

struct GitHubBranch: Codable, Sendable {
    struct CommitPointer: Codable, Sendable {
        let sha: String
    }

    let name: String
    let commit: CommitPointer
}

struct GitHubCommitSummary: Codable, Sendable {
    struct CommitInfo: Codable, Sendable {
        struct Author: Codable, Sendable {
            let name: String?
            let date: String?
        }

        let message: String
        let author: Author?
    }

    let sha: String
    let commit: CommitInfo
}

struct GitHubRef: Codable, Sendable {
    struct Object: Codable, Sendable {
        let sha: String
        let type: String
    }

    let ref: String
    let object: Object
}

struct GitHubCommitDetail: Codable, Sendable {
    struct Tree: Codable, Sendable {
        let sha: String
    }

    let sha: String
    let tree: Tree
}

struct GitHubTreeDetail: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?
    }

    let sha: String
    let tree: [Entry]
    let truncated: Bool?
}

struct GitHubBlob: Codable, Sendable {
    let sha: String
}

struct GitHubBlobDetail: Codable, Sendable {
    let sha: String
    let size: Int?
    let content: String?
    let encoding: String?
}

struct GitHubTree: Codable, Sendable {
    let sha: String
}

struct GitHubCreatedCommit: Codable, Sendable {
    let sha: String
}

/// Git Data API 中 tree 的一个条目。
/// 删除文件时 sha 需要显式编码为 null，因此自定义 encode。
struct GitHubTreeEntry: Encodable, Sendable {
    let path: String
    let mode: String
    let type: String
    let sha: String?

    init(path: String, mode: String = "100644", type: String = "blob", sha: String?) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
    }

    enum CodingKeys: String, CodingKey {
        case path
        case mode
        case type
        case sha
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mode, forKey: .mode)
        try container.encode(type, forKey: .type)
        if let sha {
            try container.encode(sha, forKey: .sha)
        } else {
            try container.encodeNil(forKey: .sha)
        }
    }
}

// MARK: - Actions

struct GitHubWorkflowRuns: Codable, Sendable {
    let totalCount: Int
    let workflowRuns: [GitHubWorkflowRun]
}

struct GitHubWorkflowRun: Codable, Sendable, Identifiable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSha: String?
    let event: String?
    let status: String?
    let conclusion: String?
    let runNumber: Int?
    let runAttempt: Int?
    let createdAt: String?
    let updatedAt: String?
    let htmlUrl: URL?
    let workflowId: Int?
}

struct GitHubWorkflowJobs: Codable, Sendable {
    let totalCount: Int
    let jobs: [GitHubWorkflowJob]
}

struct GitHubWorkflowJob: Codable, Sendable, Identifiable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let htmlUrl: URL?
    let steps: [GitHubWorkflowStep]?
}

struct GitHubWorkflowStep: Codable, Sendable, Identifiable {
    let name: String
    let number: Int
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?

    var id: Int { number }
}
