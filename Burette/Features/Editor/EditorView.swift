import SwiftUI

/// 带语法高亮的文本编辑器。
///
/// 目前用轻量的正则高亮（见 Support/CodeHighlighting.swift）；
/// M3 会替换为 Runestone（行号、Tree-sitter 高亮、搜索替换）。
struct EditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository
    let path: String

    @State private var text = ""
    @State private var isLoaded = false
    @State private var loadError: String?
    @State private var savedToast = false

    private var fileName: String {
        path.split(separator: "/").last.map { String($0) } ?? path
    }

    private var language: CodeLanguage {
        CodeLanguage.from(path: path)
    }

    var body: some View {
        CodeEditor(text: $text, language: language)
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
            .overlay(alignment: .top) {
                if savedToast {
                    Text("已保存到工作区")
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.green.opacity(0.92), in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        env.saveEditedFile(repository, path: path, content: text)
                        showSaved()
                    }
                    .disabled(loadError != nil)
                }
            }
            .task(id: path) { load() }
    }

    private func showSaved() {
        withAnimation { savedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedToast = false }
        }
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
