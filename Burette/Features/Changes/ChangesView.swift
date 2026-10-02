import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var commitMessage = ""
    @State private var preview: FileChange?

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
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { change.isStaged },
                        set: { env.setStaged($0, for: change, in: repository) }
                    ))
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path).font(.callout.monospaced())
                        Text(statusText(change.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("查看") { preview = change }
                        .buttonStyle(.borderless)
                }
                .circularDeleteSwipe { env.discard(change: change, in: repository) }
            }

            Section {
                TextField("提交说明", text: $commitMessage, axis: .vertical)
                    .lineLimit(1...4)
                Button("提交并推送") {
                    let message = commitMessage
                    commitMessage = ""
                    Task { await env.commitStaged(in: repository, message: message) }
                }
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $preview) { change in
            NavigationStack {
                ScrollView {
                    Text(change.unifiedDiff())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(change.path)
            }
        }
    }

    private func statusText(_ status: FileChange.Status) -> String {
        switch status {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }
}
