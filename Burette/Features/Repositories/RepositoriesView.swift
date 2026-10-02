import SwiftUI

struct RepositoriesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingPicker = false

    var body: some View {
        List {
            if env.repositories.isEmpty {
                ContentUnavailableView(
                    "还没有仓库",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("点右上角加号，从 GitHub 添加仓库。")
                )
            }

            ForEach(env.repositories) { repository in
                HStack {
                    Button {
                        env.selectedRepositoryID = repository.id
                    } label: {
                        RepositoryRow(
                            repository: repository,
                            isSelected: repository.id == env.selectedRepositoryID
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    NavigationLink {
                        FileBrowserView(repository: repository)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) { env.removeRepository(repository) }
                    Button("拉取") { Task { await env.clone(repository) } }
                        .tint(.blue)
                }
            }
        }
        .navigationTitle("仓库")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("退出") { env.signOut() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPicker = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            RepositoryPickerView()
        }
    }
}

struct RepositoryRow: View {
    let repository: Repository
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                Text(repository.fullName).font(.headline)
                if repository.isPrivate {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("分支 \(repository.currentBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sha = repository.baseCommitSHA {
                Text("base \(sha.prefix(7))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未拉取到本地")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RepositoryPickerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var repositories: [GitHubRepository] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(repositories, id: \.id) { repo in
                    Button {
                        env.addRepositories(from: [repo])
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName)
                                Text(repo.isPrivate ? "私有" : "公开")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if env.repositories.contains(where: { $0.owner == repo.owner.login && $0.name == repo.name }) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择仓库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        do {
            repositories = try await env.github.repositories()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
