import Foundation

/// 统一的取消判断，避免把用户操作或系统取消当成失败上报 / 弹错。
enum Cancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return true }
        return false
    }
}
