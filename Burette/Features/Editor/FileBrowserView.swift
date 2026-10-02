import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    @State private var nodes: [FileNode] = []
    @State private var isLoaded = false

    var body: some View {
        List {
            if isLoaded && nodes.isEmpty {
                ContentUnavailableView(
                    "工作区为空",
                    systemImage: "doc",
                    description: Text("先在「仓库」里对 \(repository.name) 执行一次拉取。")
                )
            } else {
                ForEach(nodes) { node in
                    FileNodeRow(node: node, repository: repository)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        let files = (try? env.workspace.listFiles(repository: repository)) ?? []
        nodes = FileNode.tree(from: files)
        isLoaded = true
        Log.debug("打开文件树：\(repository.fullName)，\(files.count) 个文件", .ui)
    }
}

/// 递归渲染一层目录 / 文件。用 AnyView 断开递归类型，避免编译器无限展开。
struct FileNodeRow: View {
    let node: FileNode
    let repository: Repository

    var body: some View {
        if node.isDirectory {
            DisclosureGroup {
                ForEach(node.children ?? []) { child in
                    AnyView(FileNodeRow(node: child, repository: repository))
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)
                    Text(node.name)
                        .foregroundStyle(.primary)
                }
            }
        } else {
            NavigationLink {
                EditorView(repository: repository, path: node.path)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)
                    Text(node.name)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
