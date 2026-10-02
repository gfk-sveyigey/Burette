import Foundation

/// 时长的简短展示。
enum DurationFormat {
    /// 统一用中文单位：45秒 / 1分23秒 / 1小时02分03秒。
    static func short(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d小时%02d分%02d秒", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%d分%02d秒", minutes, seconds)
        }
        return "\(seconds)秒"
    }
}
