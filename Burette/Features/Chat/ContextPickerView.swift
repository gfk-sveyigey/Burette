import SwiftUI

/// 选择要作为上下文提供给 AI 的文件。
struct ContextPickerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    @Binding var selected: [String]

    @State private var paths: [String] = []
    @State private var query = ""

    private var filtered: [String] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return paths }
        return paths.filter { $0.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if paths.isEmpty {
                    Text("工作区还是空的。先回仓库页对 \(repository.name) 执行一次拉取。")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                ForEach(filtered, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(path) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(path) ? Color.accentColor : Color.secondary)
                        Text(path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(path) }
                }
            }
            .searchable(text: $query, prompt: "搜索文件")
            .navigationTitle("引用代码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                paths = (try? env.workspace.listFiles(repository: repository)) ?? []
            }
        }
    }

    private func toggle(_ path: String) {
        if let index = selected.firstIndex(of: path) {
            selected.remove(at: index)
        } else {
            selected.append(path)
        }
    }
}
