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
    @State private var isMissing = false

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
                } else if isMissing {
                    Text("这个文件在本地工作区里不存在，或不是 UTF-8 文本。")
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
                    .disabled(isMissing)
                }
            }
            .task(id: path) { load() }
    }

    private func load() {
        guard !isLoaded else { return }
        do {
            if let content = try env.workspace.read(repository: repository, path: path) {
                text = content
                isMissing = false
            } else {
                text = ""
                isMissing = true
            }
        } catch {
            text = ""
            isMissing = true
        }
        isLoaded = true
    }
}
