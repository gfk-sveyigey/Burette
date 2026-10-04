import ActivityKit
import SwiftUI
import WidgetKit

/// App 图标（Shared/Assets.xcassets 里的 AgentIcon），实时活动与灵动岛共用。
private struct AgentGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        Image("AgentIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

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
                    HStack(spacing: 6) {
                        AgentGlyph(size: 18)
                        Text("Burette")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
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

                        // 计时固定在整行最右侧。
                        Text(context.state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                AgentGlyph(size: 16)
            } compactTrailing: {
                // 靠右对齐，避免计时缩在紧凑区的中间。
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 46, alignment: .trailing)
            } minimal: {
                AgentGlyph(size: 16)
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
            AgentGlyph(size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Burette Agent")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            // 占据除时长外的全部宽度，保证标题与状态文字一定可见。
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // 时长用 fixedSize 固定为自身宽度，既不抢文字空间，又贴在最右侧。
            Text(state.startedAt, style: .timer)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
        }
        // 左右留出内边距，避免图标紧贴卡片左边缘。
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct BuretteWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}
