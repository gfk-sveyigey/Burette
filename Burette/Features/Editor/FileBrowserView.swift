import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    @State private var nodes: [FileNode] = []
    @State private var isLoaded = false

    var body: some View {
        List(nodes, children: \.subnodes) { node in
            if node.isDirectory {
                Label(node.name, systemImage: "folder")
                    .foregroundStyle(.primary)
            } else {
                NavigationLink {
                    EditorView(repository: repository, path: node.path)
                } label: {
                    Label(node.name, systemImage: "doc.text")
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoaded && nodes.isEmpty {
                ContentUnavailableView(
                    "工作区为空",
                    systemImage: "doc",
                    description: Text("先在「仓库」里对 \(repository.name) 执行一次拉取。")
                )
            }
        }
        .task { load() }
    }

    private func load() {
        let files = (try? env.workspace.listFiles(repository: repository)) ?? []
        nodes = FileNode.tree(from: files)
        isLoaded = true
    }
}
