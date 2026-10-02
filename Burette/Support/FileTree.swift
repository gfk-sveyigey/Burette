import Foundation

/// 文件浏览器使用的目录树节点。
struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileNode]?

    /// List(children:) 需要目录返回子节点、文件返回 nil。
    var subnodes: [FileNode]? { children }

    /// 把扁平路径列表（a/b/c.swift）整理成目录树。
    static func tree(from paths: [String]) -> [FileNode] {
        let root = Builder()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var node = root
            for (index, component) in components.enumerated() {
                let child = node.children[component] ?? Builder()
                node.children[component] = child
                if index == components.count - 1 { child.isFile = true }
                node = child
            }
        }
        return build(root, prefix: "")
    }

    private static func build(_ node: Builder, prefix: String) -> [FileNode] {
        node.children.keys.sorted().compactMap { name in
            guard let child = node.children[name] else { return nil }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if child.isFile {
                return FileNode(id: path, name: name, path: path, isDirectory: false, children: nil)
            }
            let subnodes = build(child, prefix: path)
            return FileNode(
                id: path,
                name: name,
                path: path,
                isDirectory: true,
                children: subnodes.isEmpty ? nil : subnodes
            )
        }
    }

    private final class Builder {
        var children: [String: Builder] = [:]
        var isFile = false
    }
}
