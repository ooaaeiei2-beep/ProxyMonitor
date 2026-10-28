import Foundation
import os

/// 统一日志入口：os_log 与本地滚动日志双写。
///
/// 为什么要有本地文件：
/// 状态栏程序是无人值守的，出问题时用户能提供的只有"它不动了"。
/// os_log 的 `.debug` 默认不落盘、`.private` 在 Console 里也不可见，
/// 因此必须自带一份可导出的滚动日志，否则任何失效都无法事后定因。
///
/// 目录：~/Library/Logs/ProxyMonitor/proxymonitor.log
/// 轮转：单文件 1 MB，保留 .1 / .2 两份归档
/// 脱敏：所有 URL 只保留 scheme + host，路径与查询串统一替换为 <redacted>
enum PTMLogger {
    static let log = Logger(subsystem: "com.xushuda.proxytrafficmonitor",
                            category: "ProxyTrafficMonitor")

    // MARK: - 对外接口

    static func debug(_ message: String) { emit(.debug, message) }
    static func info(_ message: String)  { emit(.info, message) }
    static func error(_ message: String) { emit(.error, message) }

    /// 日志目录（诊断导出用）
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ProxyMonitor", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("proxymonitor.log")
    }

    // MARK: - 脱敏

    /// 把文本中出现的 URL 收敛为 scheme+host。
    /// 订阅链接本身即凭据（多数机场把 token 放在 path 或 query 里），
    /// 任何日志、错误描述、崩溃信息都不允许携带它。
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return urlRegex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "$1/<redacted>"
        )
    }

    // MARK: - 内部

    private enum Level: String {
        case debug = "D"
        case info  = "I"
        case error = "E"
    }

    private static let queue = DispatchQueue(label: "com.xushuda.proxytrafficmonitor.filelog",
                                             qos: .utility)

    private static let maxBytes: UInt64 = 1_000_000
    private static let maxArchives = 2
    private static var handle: FileHandle?

    private static let urlRegex = try! NSRegularExpression(
        pattern: "([A-Za-z][A-Za-z0-9+.\\-]*://[^\\s/\"']+)([^\\s\"']*)",
        options: []
    )

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: Level, _ message: String) {
        let safe = redact(message)
        switch level {
        case .debug: log.debug("\(safe, privacy: .private)")
        case .info:  log.info("\(safe, privacy: .private)")
        case .error: log.error("\(safe, privacy: .private)")
        }
        // 文件写入失败绝不能影响主流程，故整段包在 queue.async 里且不抛错。
        queue.async { write(level, safe) }
    }

    private static func write(_ level: Level, _ message: String) {
        do {
            try prepareHandle()
            guard let handle else { return }
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 静默：磁盘满、权限异常等情况下不制造新的失败
        }
    }

    private static func prepareHandle() throws {
        let fm = FileManager.default
        if let handle {
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            if size <= maxBytes { return }
            try? handle.close()
            self.handle = nil
            rotate()
        }
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    /// proxymonitor.log → .1 → .2，最旧的丢弃
    private static func rotate() {
        let fm = FileManager.default
        let oldest = directoryURL.appendingPathComponent("proxymonitor.\(maxArchives).log")
        try? fm.removeItem(at: oldest)
        if maxArchives > 1 {
            for index in stride(from: maxArchives - 1, through: 1, by: -1) {
                let from = directoryURL.appendingPathComponent("proxymonitor.\(index).log")
                let to = directoryURL.appendingPathComponent("proxymonitor.\(index + 1).log")
                if fm.fileExists(atPath: from.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }
        let first = directoryURL.appendingPathComponent("proxymonitor.1.log")
        try? fm.moveItem(at: fileURL, to: first)
    }
}
