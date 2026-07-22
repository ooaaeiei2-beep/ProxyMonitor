import os

/// 统一日志入口。替换散落的 NSLog/print，使用 os_log 分级。
/// - .debug：详细调试（菜单重建、轮播切换等高频日志）
/// - .info ：关键生命周期（启动、状态栏创建、刷新完成）
/// - .error：错误（网络失败、解析失败）
enum PTMLogger {
    static let log = Logger(subsystem: "com.xushuda.proxytrafficmonitor",
                            category: "ProxyTrafficMonitor")

    static func debug(_ message: String) { log.debug("\(message, privacy: .public)") }
    static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
    static func error(_ message: String) { log.error("\(message, privacy: .public)") }
}
