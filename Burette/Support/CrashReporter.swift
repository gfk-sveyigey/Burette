import Foundation

/// 崩溃捕获工具。
///
/// - 把 stderr 重定向到 Documents/Logs/stderr.log：Swift 运行时崩溃（fatalError、
///   断言失败等）的信息和堆栈都会写进这个文件。
/// - 安装未捕获异常与致命信号处理器，追加一行标记后再交还给系统。
///
/// 下一次启动时，LogCenter 会把 stderr.log 合并进 burette.log，并在「运行日志」
/// 里以「上一次会话的崩溃 / 错误输出」展示，方便定位闪退原因。
enum CrashReporter {
    private static var installed = false

    /// 无捕获的 C 函数指针：进程收到致命信号时触发。
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        _ = fputs("\n[崩溃] 应用收到致命信号，即将退出。\n", stderr)
        _ = fflush(stderr)
        _ = signal(sig, SIG_DFL)
        _ = raise(sig)
    }

    static func install() {
        guard !installed else { return }
        installed = true

        let url = LogCenter.shared.stderrURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // stderr 追加写入文件，并关闭缓冲，保证崩溃时内容立即落盘。
        _ = freopen(url.path, "a+", stderr)
        _ = setvbuf(stderr, nil, _IONBF, 0)

        NSSetUncaughtExceptionHandler { exception in
            _ = fputs("\n[未捕获异常] \(exception.name.rawValue)\n", stderr)
            _ = fputs("原因：\(exception.reason ?? "未知")\n", stderr)
            _ = fputs("调用栈：\n", stderr)
            for frame in exception.callStackSymbols {
                _ = fputs(frame + "\n", stderr)
            }
            _ = fflush(stderr)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            _ = signal(sig, signalHandler)
        }
    }
}
