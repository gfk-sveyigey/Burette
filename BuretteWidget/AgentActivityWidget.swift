import ActivityKit
import SwiftUI
import WidgetKit

/// 对话进行中的实时活动：锁屏卡片 + 灵动岛（紧凑 / 展开 / 最小）。
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Burette", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.state.repository)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        // 时间固定在整行最右边。
                        Text(context.state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles")
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "sparkles")
            }
            .keylineTint(.accentColor)
        }
    }
}

/// 锁屏 / 通知中心的实时活动卡片。
struct AgentActivityLockScreenView: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Burette Agent")
                    .font(.caption.bold())
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(state.startedAt, style: .timer)
                .font(.callout.monospacedDigit())
        }
        .padding(14)
    }
}

@main
struct BuretteWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}
