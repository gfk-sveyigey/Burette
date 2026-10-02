import Foundation
import SwiftUI

@main
struct BuretteApp: App {
    @StateObject private var environment = AppEnvironment()

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
        }
    }
}
