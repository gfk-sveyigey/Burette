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

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        env.saveEditedFile(repository, path: path, content: text)
                    }
                }
            }
            .onAppear(perform: load)
    }

    private func load() {
        guard !isLoaded else { return }
        text = (try? env.workspace.read(repository: repository, path: path)) ?? ""
        isLoaded = true
    }
}
