import Foundation
import SwiftUI
import UIKit

@main
struct BuretteApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 尽早安装崩溃捕获，并把 stderr 重定向到日志目录。
        CrashReporter.install()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("应用启动：v\(version) (\(build))", .app)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    LogCenter.shared.flush()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // 回到前台：如果上次请求被锁屏 / 切网打断，自动接着跑完。
                Task { await environment.resumePendingSendIfNeeded() }
            } else {
                // 进入后台 / 非活跃时把排队的日志写盘，避免进程被回收时丢日志。
                LogCenter.shared.flush()
            }
        }
    }
}
