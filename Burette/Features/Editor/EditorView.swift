import SwiftUI

/// 带语法高亮与行号栏的文本编辑器。
///
/// 高亮由 Support/CodeHighlighting.swift 的正则词法器提供：
/// 覆盖注释、字符串、数字、关键字、类型、函数调用等 token，并带行号栏。
/// 编辑器本身还支持回车自动缩进、括号匹配高亮与查找 / 替换。
struct EditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository
    let path: String

    @State private var text = ""
    @State private var isLoaded = false
    @State private var loadError: String?
    @State private var savedToast = false

    @StateObject private var editorController = CodeEditorController()
    @State private var showingFind = false
    @State private var findQuery = ""
    @State private var replaceQuery = ""
    @State private var findStatus: String?
    @FocusState private var findFocused: Bool

    private var fileName: String {
        path.split(separator: "/").last.map { String($0) } ?? path
    }

    private var language: CodeLanguage {
        CodeLanguage.from(path: path)
    }

    var body: some View {
        CodeEditor(text: $text, language: language, controller: editorController)
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showingFind {
                    findBar
                }
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(language.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        toggleFind()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("查找替换")

                    Button("保存") {
                        env.saveEditedFile(repository, path: path, content: text)
                        showSaved()
                    }
                    .disabled(loadError != nil)
                }
            }
            .task(id: path) { load() }
    }

    private var findBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("查找", text: $findQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($findFocused)
                    .onSubmit { performFind(forward: true) }
                if let findStatus {
                    Text(findStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    performFind(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel("上一个")

                Button {
                    performFind(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("下一个")

                Button("完成") {
                    showingFind = false
                    findFocused = false
                    findStatus = nil
                    editorController.clearSelection()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                TextField("替换为", text: $replaceQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("替换") {
                    if editorController.replaceCurrent(findQuery, with: replaceQuery) {
                        findStatus = "已替换"
                    } else {
                        findStatus = "无匹配"
                    }
                }
                Button("全部") {
                    let count = editorController.replaceAll(findQuery, with: replaceQuery)
                    findStatus = count > 0 ? "已替换 \(count) 处" : "无匹配"
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleFind() {
        showingFind.toggle()
        if showingFind {
            findFocused = true
        } else {
            findFocused = false
            findStatus = nil
            editorController.clearSelection()
        }
    }

    private func performFind(forward: Bool) {
        guard !findQuery.isEmpty else {
            findStatus = nil
            return
        }
        if editorController.find(findQuery, forward: forward) {
            findStatus = "已定位"
        } else {
            findStatus = "无匹配"
        }
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
