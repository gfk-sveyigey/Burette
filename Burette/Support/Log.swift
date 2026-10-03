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
/// - 内存里保留最近 maxEntries 条（可在「运行日志」页调整），供展示。
/// - 同时追加写入 Documents/Logs/burette.log，超过上限后轮转为 burette.1.log。
/// - 启动时会把上一会话的崩溃输出合并进来，并加载最近历史，方便定位闪退。
final class LogCenter: ObservableObject, @unchecked Sendable {
    static let shared = LogCenter()

    @Published private(set) var entries: [LogEntry] = []

    /// 界面可调的日志保留设置选项。
    enum Cleanup {
        /// 内存里最多保留的日志条数选项。
        static let entriesOptions = [200, 500, 800, 2_000, 5_000]
        /// 保留天数选项；0 表示永久保留。
        static let daysOptions = [0, 1, 3, 7, 30]

        static func entriesLabel(_ value: Int) -> String { "\(value) 条" }
        static func daysLabel(_ value: Int) -> String { value == 0 ? "永久" : "\(value) 天" }
    }

    private enum Keys {
        static let maxEntries = "log.maxEntries"
        static let retentionDays = "log.retentionDays"
    }

    /// 内存里保留的最大条数（可调）。
    @Published private(set) var maxEntries: Int
    /// 日志保留天数；0 表示永久（可调）。
    @Published private(set) var retentionDays: Int

    private let lock = NSLock()
    private var storage: [LogEntry] = []

    private let fileQueue = DispatchQueue(label: "com.burette.log.file")
    let fileURL: URL
    let stderrURL: URL
    private let maxFileSize = 1_024_000
    /// 轮转保留的历史文件数量（burette.1.log … burette.N.log）。
    private let maxRotatedGenerations = 3

    /// 第 generation 代历史日志的路径；generation 为 0 时即当前文件。
    func rotatedURL(_ generation: Int) -> URL {
        guard generation > 0 else { return fileURL }
        return fileURL
            .deletingPathExtension()
            .appendingPathExtension("\(generation).log")
    }


    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("burette.log")
        stderrURL = directory.appendingPathComponent("stderr.log")

        let defaults = UserDefaults.standard
        maxEntries = defaults.object(forKey: Keys.maxEntries) as? Int ?? 800
        retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 0

        mergePreviousCrash()
        loadHistory()
    }

    func record(level: LogLevel, category: LogCategory, message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)

        lock.lock()
        storage.append(entry)
        if storage.count > maxEntries {
            storage.removeFirst(storage.count - maxEntries)
        }
        let snapshot = storage
        lock.unlock()

        publish(snapshot)

        let url = fileURL
        let maxSize = maxFileSize
        let generations = maxRotatedGenerations
        fileQueue.async {
            LogCenter.append(entry, to: url, maxSize: maxSize, generations: generations)
        }
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        publish([])
        let logURL = fileURL
        let errorURL = stderrURL
        let generations = maxRotatedGenerations
        fileQueue.async {
            try? FileManager.default.removeItem(at: logURL)
            for generation in 1...generations {
                try? FileManager.default.removeItem(at: logURL.deletingPathExtension().appendingPathExtension("\(generation).log"))
            }
            try? FileManager.default.removeItem(at: errorURL)
        }
    }

    /// 修改日志清理设置并立即生效。
    func updateCleanup(maxEntries newMaxEntries: Int, retentionDays newRetentionDays: Int) {
        maxEntries = newMaxEntries
        retentionDays = newRetentionDays
        UserDefaults.standard.set(newMaxEntries, forKey: Keys.maxEntries)
        UserDefaults.standard.set(newRetentionDays, forKey: Keys.retentionDays)
        Log.info("更新日志清理设置：最多 \(newMaxEntries) 条，保留 \(newRetentionDays == 0 ? "永久" : "\(newRetentionDays) 天")", .app)
        applyCleanup()
    }

    /// 立即按当前设置清理内存与磁盘日志。
    func applyCleanup() {
        lock.lock()
        if storage.count > maxEntries {
            storage.removeFirst(storage.count - maxEntries)
        }
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            storage.removeAll { $0.date < cutoff }
        }
        let snapshot = storage
        lock.unlock()
        publish(snapshot)

        // 让磁盘内容与设置后的内存保持一致：重写当前文件，删除更旧的历史轮转文件。
        let url = fileURL
        let generations = maxRotatedGenerations
        let text = snapshot.map { Self.line($0) }.joined()
        fileQueue.async {
            let data = text.data(using: .utf8)
            try? data?.write(to: url, options: .atomic)
            for generation in 1...generations {
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("\(generation).log"))
            }
        }
    }

    /// 把内存快照同步到 @Published 的 entries（自动切主线程）。
    private func publish(_ snapshot: [LogEntry]) {
        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries = snapshot }
        }
    }

    // MARK: - 历史 / 崩溃

    /// 把上一会话写到 stderr 的崩溃内容并入主日志。
    private func mergePreviousCrash() {
        guard let text = try? String(contentsOf: stderrURL, encoding: .utf8), !text.isEmpty else { return }
        let block = "\n===== 上一次会话的崩溃 / 错误输出 =====\n" + text + "\n===== 结束 =====\n"
        if let data = block.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        try? Data().write(to: stderrURL)
    }

    /// 启动时加载最近的历史日志，这样重启后也能看到上次会话（含崩溃）。
    ///
    /// 会按「旧 → 新」依次读取所有轮转文件与当前文件，取最后 maxEntries 条并还原
    /// 原来的时间/级别/分类，避免重启后丢掉大部分日志。
    private func loadHistory() {
        var lines: [String] = []
        for generation in stride(from: maxRotatedGenerations, through: 1, by: -1) {
            let url = rotatedURL(generation)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }

        var seeded = lines.suffix(maxEntries).map { line -> LogEntry in
            if let parsed = Self.parseLine(line) { return parsed }
            let isCrash = line.contains("崩溃") || line.contains("致命错误") || line.contains("未捕获异常")
                || line.contains("Fatal error") || line.contains("Exception")
            return LogEntry(
                date: Date(),
                level: isCrash ? .error : .info,
                category: .app,
                message: "[上次会话] " + line
            )
        }
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            seeded.removeAll { $0.date < cutoff }
        }
        storage = seeded
        entries = seeded
    }

    /// 把一行 "日期 [级别] [分类] 消息" 还原成 LogEntry；无法解析时返回 nil。
    private static func parseLine(_ raw: String) -> LogEntry? {
        let characters = Array(raw)
        guard characters.count > 26 else { return nil }
        guard let date = formatter.date(from: String(characters[0..<23])) else { return nil }

        var index = 23
        func readBracket() -> String? {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count, characters[index] == "[" else { return nil }
            index += 1
            var value = ""
            while index < characters.count, characters[index] != "]" {
                value.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return nil }
            index += 1
            return value
        }

        guard let levelText = readBracket(), let categoryText = readBracket() else { return nil }
        while index < characters.count, characters[index] == " " { index += 1 }
        let message = String(characters[index...])

        let level = LogLevel.allCases.first { $0.rawValue == levelText } ?? .info
        let category = LogCategory.allCases.first { $0.rawValue == categoryText } ?? .app
        return LogEntry(date: date, level: level, category: category, message: message)
    }

    /// 等待已排队的日志写入磁盘（在进入后台 / 退出时调用，避免丢日志）。
    func flush() {
        fileQueue.sync {}
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

    private static func append(_ entry: LogEntry, to url: URL, maxSize: Int, generations: Int) {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int,
           size > maxSize {
            func path(_ generation: Int) -> URL {
                generation <= 0 ? url : url.deletingPathExtension().appendingPathExtension("\(generation).log")
            }
            try? manager.removeItem(at: path(generations))
            if generations > 1 {
                for generation in stride(from: generations - 1, through: 1, by: -1) {
                    let source = path(generation)
                    guard manager.fileExists(atPath: source.path) else { continue }
                    try? manager.moveItem(at: source, to: path(generation + 1))
                }
            }
            try? manager.moveItem(at: url, to: path(1))
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
