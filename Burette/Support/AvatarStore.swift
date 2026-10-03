import SwiftUI
import UIKit

/// 头像缓存：先读本地缓存直接显示，再在后台刷新，避免每次进设置页都转圈。
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()

    /// 缓存更新后自增，触发界面刷新（图片本身只在内存缓存里）。
    @Published private(set) var revision = 0

    private var cache: [String: UIImage] = [:]
    private let directory: URL
    private var inFlight: Set<String> = []

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 取缓存头像（内存 → 磁盘）。不触发界面刷新，可在 body 里安全调用。
    func cachedImage(for url: URL) -> UIImage? {
        let key = Self.key(for: url)
        if let hit = cache[key] { return hit }
        let file = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        cache[key] = image
        return image
    }

    /// 后台刷新头像，成功后写回内存与磁盘。
    func refresh(url: URL) async {
        let key = Self.key(for: url)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            guard let image = UIImage(data: data) else { return }
            try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
            cache[key] = image
            revision += 1
        } catch {
            Log.debug("头像刷新失败：\(error.localizedDescription)", .ui)
        }
    }

    private static func key(for url: URL) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in url.absoluteString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16) + ".img"
    }
}
