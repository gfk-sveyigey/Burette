import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// 把对话进度同步到灵动岛 / 锁屏实时活动。
@MainActor
final class AgentLiveActivity {
    static let shared = AgentLiveActivity()

    #if canImport(ActivityKit)
    private var activity: Activity<AgentActivityAttributes>?
    #endif

    private init() {}

    /// 开始一次实时活动（已在运行时先结束旧的）。
    func start(repository: String, status: String, startedAt: Date) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.debug("系统未允许实时活动，跳过上岛", .ui)
            return
        }
        if activity != nil { end() }
        let attributes = AgentActivityAttributes(repositoryFullName: repository)
        let state = AgentActivityAttributes.ContentState(
            status: status,
            repository: repository,
            startedAt: startedAt
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            Log.info("已开启实时活动：\(repository)", .ui)
        } catch {
            Log.warning("开启实时活动失败：\(error.localizedDescription)", .ui)
        }
        #endif
    }

    /// 更新灵动岛上显示的状态。
    func update(repository: String, status: String, startedAt: Date) {
        #if canImport(ActivityKit)
        guard let activity else { return }
        let state = AgentActivityAttributes.ContentState(
            status: status,
            repository: repository,
            startedAt: startedAt
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    /// 结束实时活动。
    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}
