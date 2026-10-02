import Foundation

/// 时长的简短展示。
enum DurationFormat {
    /// 12 秒 / 1:23。
    static func short(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total < 60 { return "\(total) 秒" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
