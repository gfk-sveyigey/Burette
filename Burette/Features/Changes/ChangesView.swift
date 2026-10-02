import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var commitMessage = ""
    @State private var preview: FileChange?
    @State private var toast: String?
    @State private var errorText: String?
    @FocusState private var isEditingMessage: Bool

    var body: some View {
        Group {
            if let repository = env.selectedRepository {
                content(for: repository)
            } else {
                ContentUnavailableView(
                    "请先选择仓库",
                    systemImage: "arrow.triangle.branch"
                )
            }
        }
        .navigationTitle("改动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let repository = env.selectedRepository else { return }
                    commit(in: repository)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
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
    }

    /// 当前仓库是否有可提交的改动。
    private var canCommit: Bool {
        guard let repository = env.selectedRepository else { return false }
        return !env.pendingChanges(for: repository).isEmpty
    }

    @ViewBuilder
    private func content(for repository: Repository) -> some View {
        let changes = env.pendingChanges(for: repository)
        let stagedCount = changes.filter { $0.isStaged }.count

        List {
            if changes.isEmpty {
                Text("工作区没有未提交的改动。")
                    .foregroundStyle(.secondary)
            }

            ForEach(changes) { change in
                row(change, in: repository)
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

    private func commit(in repository: Repository) {
        isEditingMessage = false
        let message = commitMessage
        Task {
            let ok = await env.commitStaged(in: repository, message: message)
            if ok {
                commitMessage = ""
                showToast("已提交并推送")
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

    private func row(_ change: FileChange, in repository: Repository) -> some View {
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
