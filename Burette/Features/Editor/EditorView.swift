import SwiftUI

/// 简单的文本编辑器。
///
/// M0 先用 SwiftUI 的 TextEditor 打通链路；M3 会替换为 Runestone
/// （行号、Tree-sitter 语法高亮、括号匹配、搜索替换）。
struct EditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository
    let path: String

    @State private var text = ""
    @State private var isLoaded = false
    @State private var loadError: String?

    private var fileName: String {
        path.split(separator: "/").last.map { String($0) } ?? path
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .overlay(alignment: .topLeading) {
                if !isLoaded {
                    ProgressView().padding()
                } else if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        env.saveEditedFile(repository, path: path, content: text)
                    }
                    .disabled(loadError != nil)
                }
            }
            .task(id: path) { load() }
    }

    private func load() {
        do {
            if let content = try env.workspace.read(repository: repository, path: path) {
                text = content
                loadError = nil
            } else {
                text = ""
                loadError = "这个文件在本地工作区里不存在，先回到「仓库」页拉取一次。"
            }
        } catch {
            text = ""
            loadError = error.localizedDescription
        }
        isLoaded = true
    }
}
