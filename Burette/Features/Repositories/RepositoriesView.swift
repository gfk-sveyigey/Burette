import SwiftUI

struct RepositoriesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingPicker = false
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive

    private var selectedRepositories: [Repository] {
        env.repositories.filter { selection.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            if env.repositories.isEmpty {
                ContentUnavailableView(
                    "还没有仓库",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("点右上角加号，从 GitHub 添加仓库。")
                )
            }

            ForEach(env.repositories) { repository in
                NavigationLink {
                    FileBrowserView(repository: repository)
                } label: {
                    RepositoryRow(repository: repository)
                }
                .task { await env.loadBranches(for: repository) }
                .contextMenu {
                    Button {
                        Task { await env.clone(repository) }
                    } label: {
                        Label("拉取", systemImage: "arrow.down.circle")
                    }

                    Menu {
                        ForEach(env.branches(for: repository), id: \.self) { branch in
                            Button {
                                Task { await env.switchBranch(repository, to: branch) }
                            } label: {
                                if branch == repository.currentBranch {
                                    Label(branch, systemImage: "checkmark")
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    } label: {
                        Label("切换分支", systemImage: "arrow.triangle.branch")
                    }
                }
                .circularDeleteSwipe { env.removeRepository(repository) }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle("仓库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode == .active {
                    Menu {
                        Button {
                            pullSelected()
                        } label: {
                            Label("拉取选中", systemImage: "arrow.down.circle")
                        }
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Label("删除选中", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(selection.isEmpty)

                    Button("完成") { exitSelection() }
                } else {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button("选择") {
                        selection = []
                        editMode = .active
                    }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            RepositoryPickerView()
        }
    }

    private func exitSelection() {
        selection = []
        editMode = .inactive
    }

    private func pullSelected() {
        let repositories = selectedRepositories
        guard !repositories.isEmpty else { return }
        exitSelection()
        Task {
            for repository in repositories {
                await env.clone(repository)
            }
        }
    }

    private func deleteSelected() {
        for repository in selectedRepositories {
            env.removeRepository(repository)
        }
        exitSelection()
    }
}

struct RepositoryRow: View {
    let repository: Repository

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(repository.fullName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                Text(repository.currentBranch)
                    .font(.caption)
                    .lineLimit(1)
            }
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
    @State private var query = ""

    private var filtered: [GitHubRepository] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if filtered.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                ForEach(filtered, id: \.id) { repo in
                    Button {
                        env.addRepositories(from: [repo])
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName)
                                    .foregroundStyle(.primary)
                                Text(repo.isPrivate ? "私有" : "公开")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isAdded(repo) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdded(repo))
                }
            }
            .searchable(text: $query, prompt: "搜索仓库")
            .navigationTitle("选择仓库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func isAdded(_ repo: GitHubRepository) -> Bool {
        env.repositories.contains { $0.owner == repo.owner.login && $0.name == repo.name }
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
