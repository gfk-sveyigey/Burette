import SwiftUI

/// 改动页（一级）：列出所有仓库，点进某个仓库查看它的改动。
struct ChangesView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if env.repositories.isEmpty {
                ContentUnavailableView(
                    "还没有仓库",
                    systemImage: "arrow.triangle.branch",
                    description: Text("先去「仓库」页添加项目，改动会显示在这里。")
                )
            } else {
                List {
                    ForEach(env.repositories) { repository in
                        NavigationLink {
                            RepositoryChangesView(repository: repository)
                        } label: {
                            ChangesRepositoryRow(repository: repository)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("改动")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一级列表里的一行：仓库 + 分支 + 改动数量。
private struct ChangesRepositoryRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    var body: some View {
        let changes = env.pendingChanges(for: repository)
        let staged = changes.filter { $0.isStaged }.count

        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(repository.fullName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("分支 \(repository.currentBranch)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(changes.isEmpty ? "无改动" : "\(changes.count) 个改动 · 已勾选 \(staged)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 改动页（二级）：某个仓库的改动列表 + 提交说明 + 提交并推送。
struct RepositoryChangesView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    @State private var commitMessage = ""
    @State private var preview: FileChange?
    @State private var toast: String?
    @State private var errorText: String?
    @State private var showingPushConfirm = false
    @FocusState private var isEditingMessage: Bool

    var body: some View {
        content
            .navigationTitle(repository.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isEditingMessage = false
                        showingPushConfirm = true
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                    .accessibilityLabel("提交并推送")
                }
            }
            .alert(
                "无法提交",
                isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .confirmationDialog(
                "提交并推送",
                isPresented: $showingPushConfirm,
                titleVisibility: .visible
            ) {
                Button("推送到 \(repository.name)") {
                    commit()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pushSummary)
            }
    }

    /// 推送确认框里的目标信息，避免推错仓库 / 分支。
    private var pushSummary: String {
        let staged = env.pendingChanges(for: repository).filter { $0.isStaged }.count
        return """
        仓库：\(repository.fullName)
        分支：\(repository.currentBranch)
        文件：\(staged) 个已勾选
        """
    }

    /// 当前仓库是否有可提交的改动。
    private var canCommit: Bool {
        !env.pendingChanges(for: repository).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        let changes = env.pendingChanges(for: repository)
        let stagedCount = changes.filter { $0.isStaged }.count

        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.fullName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("分支 \(repository.currentBranch)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(changes.count) 个改动 · 已勾选 \(stagedCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if changes.isEmpty {
                Text("工作区没有未提交的改动。")
                    .foregroundStyle(.secondary)
            }

            ForEach(changes) { change in
                row(change)
                    .circularDeleteSwipe { env.discard(change: change, in: repository) }
            }

            Section {
                TextField("提交说明", text: $commitMessage, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isEditingMessage)
            } footer: {
                Text(changes.isEmpty ? "没有可提交的改动。" : "已勾选 \(stagedCount) 个文件，未勾选的文件不会被提交。")
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.92), in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $preview) { change in
            NavigationStack {
                DiffView(original: change.original, current: change.current)
                    .navigationTitle(change.path)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func commit() {
        isEditingMessage = false
        let message = commitMessage
        Task {
            let ok = await env.commitStaged(in: repository, message: message)
            if ok {
                commitMessage = ""
                showToast("已推送到 \(repository.fullName)@\(repository.currentBranch)")
            } else {
                errorText = env.lastError ?? "提交失败，请稍后再试。"
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }

    private func row(_ change: FileChange) -> some View {
        HStack(spacing: 10) {
            Button {
                env.setStaged(!change.isStaged, for: change, in: repository)
            } label: {
                Image(systemName: change.isStaged ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(change.isStaged ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(change.isStaged ? "取消暂存" : "暂存")

            VStack(alignment: .leading, spacing: 2) {
                Text(change.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(statusText(change.status) + (change.isStaged ? " · 已暂存" : " · 未暂存"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { preview = change }
    }

    private func statusText(_ status: FileChange.Status) -> String {
        switch status {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }
}
