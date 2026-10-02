import Foundation

/// 轻量持久化抽象。
///
/// MVP 用 JSON 文件实现，后续替换为 SQLite 时调用方无需改动。
protocol PersistenceStore: Sendable {
    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T?
    func save<T: Encodable>(_ value: T, to name: String) throws
}

/// 把对象以 JSON 形式保存在指定目录。
struct JSONStore: PersistenceStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let url = url(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url(for: name), options: .atomic)
    }
}
