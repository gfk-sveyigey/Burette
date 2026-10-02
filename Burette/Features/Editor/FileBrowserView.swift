import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    @State private var files: [String] = []

    var body: some View {
        List(files, id: \.self) { path in
            NavigationLink(path) {
                EditorView(repository: repository, path: path)
            }
        }
        .navigationTitle(repository.name)
        .overlay {
            if files.isEmpty {
                ContentUnavailableView(
                    "工作区为空",
                    systemImage: "doc",
                    description: Text("先在「仓库」里对 \(repository.name) 执行一次拉取。")
                )
            }
        }
        .task {
            files = (try? env.workspace.listFiles(repository: repository)) ?? []
        }
    }
}
