import UIKit

/// 申请一段后台执行时间，尽量让退到后台 / 锁屏时仍在进行的请求跑完。
@MainActor
final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(_ name: String = "BuretteRequest") {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // 系统即将回收：主动结束，避免被强杀。
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
