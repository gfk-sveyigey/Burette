import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var commitMessage = ""
    @State private var preview: FileChange?
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
    }

    @ViewBuilder
    private func content(for repository: Repository) -> some View {
        let changes = env.pendingChanges(for: repository)

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
                Button("提交并推送") {
                    let message = commitMessage
                    commitMessage = ""
                    isEditingMessage = false
                    Task { await env.commitStaged(in: repository, message: message) }
                }
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded { isEditingMessage = false }
        )
        .sheet(item: $preview) { change in
            NavigationStack {
                ScrollView {
                    Text(change.unifiedDiff())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(change.path)
                .navigationBarTitleDisplayMode(.inline)
            }
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
