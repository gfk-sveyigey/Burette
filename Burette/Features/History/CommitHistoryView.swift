import SwiftUI

/// 提交历史：展示当前分支最近的提交（来自 GitHub REST commits 接口）。
struct CommitHistoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    private var commits: [GitHubCommitSummary] {
        env.commitsByRepository[repository.id] ?? []
    }

    var body: some View {
        Group {
            if commits.isEmpty {
                ContentUnavailableView(
                    "没有提交记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("下拉刷新，或确认当前分支已有提交。")
                )
            } else {
                List(commits, id: \.sha) { commit in
                    row(commit)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("提交历史")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await env.loadCommits(for: repository) }
        .task { await env.loadCommits(for: repository) }
    }

    private func row(_ commit: GitHubCommitSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commitTitle(commit.commit.message))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(String(commit.sha.prefix(7)))
                    .font(.caption2.monospaced())
                if let author = commit.commit.author?.name, !author.isEmpty {
                    Text("·")
                    Text(author)
                }
                Spacer()
                if let date = date(commit.commit.author?.date) {
                    Text(date)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func commitTitle(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? message
    }

    private func date(_ raw: String?) -> String? {
        guard let raw, let parsed = ISO8601DateFormatter().date(from: raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: parsed)
    }
}
