import Foundation
import OSLog
import Combine

/// 日志级别。
enum LogLevel: String, CaseIterable, Hashable {
    case debug = "调试"
    case info = "信息"
    case warning = "警告"
    case error = "错误"

    var symbol: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// 日志分类。
enum LogCategory: String, CaseIterable, Hashable {
    case app
    case ui
    case github
    case ai
    case workspace
    case diff
    case persistence

    var label: String {
        switch self {
        case .app: return "应用"
        case .ui: return "界面"
        case .github: return "GitHub"
        case .ai: return "AI"
        case .workspace: return "工作区"
        case .diff: return "Diff"
        case .persistence: return "存储"
        }
    }
}

/// 一条日志。
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
}

/// 内存 + 文件的日志中心。
///
/// - 内存里保留最近 limit 条，供 App 内「运行日志」页展示。
/// - 同时追加写入应用支持目录下的 burette.log，超过上限后轮转为 burette.1.log。
final class LogCenter: ObservableObject, @unchecked Sendable {
    static let shared = LogCenter()

    @Published private(set) var entries: [LogEntry] = []

    private let lock = NSLock()
    private var storage: [LogEntry] = []
    private let limit = 800

    private let fileQueue = DispatchQueue(label: "com.burette.log.file")
    private let fileURL: URL
    private let maxFileSize = 1_024_000

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("Burette", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("burette.log")
    }

    var logFileURL: URL { fileURL }

    func record(level: LogLevel, category: LogCategory, message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)

        lock.lock()
        storage.append(entry)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        let snapshot = storage
        lock.unlock()

        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }

        let url = fileURL
        let maxSize = maxFileSize
        fileQueue.async {
            LogCenter.append(entry, to: url, maxSize: maxSize)
        }
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        if Thread.isMainThread {
            entries = []
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries = [] }
        }
        let url = fileURL
        fileQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 文件写入

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func line(_ entry: LogEntry) -> String {
        "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.message)\n"
    }

    private static func append(_ entry: LogEntry, to url: URL, maxSize: Int) {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int,
           size > maxSize {
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }

        let text = line(entry)
        guard let data = text.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 全局日志入口：同时写入 OSLog 与 LogCenter。
enum Log {
    private static let subsystem = "com.burette.app"

    private static let loggers: [LogCategory: Logger] = {
        var map: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            map[category] = Logger(subsystem: "com.burette.app", category: category.rawValue)
        }
        return map
    }()

    static func debug(_ message: String, _ category: LogCategory = .app) {
        write(.debug, category, message)
    }

    static func info(_ message: String, _ category: LogCategory = .app) {
        write(.info, category, message)
    }

    static func warning(_ message: String, _ category: LogCategory = .app) {
        write(.warning, category, message)
    }

    static func error(_ message: String, _ category: LogCategory = .app) {
        write(.error, category, message)
    }

    static func error(_ error: Error, _ category: LogCategory = .app) {
        write(.error, category, error.localizedDescription)
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
        LogCenter.shared.record(level: level, category: category, message: message)
    }
}
