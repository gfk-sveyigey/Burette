import ActivityKit
import Foundation

/// 对话进行时展示在灵动岛 / 锁屏上的实时活动数据。
///
/// 这个文件同时被 App 与 Widget 扩展编译（同一个类型名），
/// 这样两端才能匹配到同一个实时活动。
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 当前步骤，例如「正在请求 AI 模型…」。
        var status: String
        /// 仓库全名，例如 "owner/repo"。
        var repository: String
        /// 本次请求开始时间，用于显示已用时长。
        var startedAt: Date
    }

    var repositoryFullName: String
}
