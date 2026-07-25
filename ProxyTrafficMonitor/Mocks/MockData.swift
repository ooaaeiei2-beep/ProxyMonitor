import Foundation

/// 调试预设订阅数据。
///
/// 仅在 `DEBUG` 且环境变量 `PTM_USE_MOCK=1` 时由 `SubscriptionStore` 加载，
/// 用于**跳过 Keychain 读取与网络拉取**，免去每次重编译输入钥匙串密码，
/// 快速验证状态栏 / 菜单 UI。Release 不受影响。
///
/// 三条示例覆盖主要状态：
/// - `HK BGP-A`：50% 正常
/// - `JP SoftEther`：92% 危险（进度条染红）
/// - `SG Trojan`：拉取出错态（演示警告图标与错误信息）
enum MockData {
    static var subscriptions: [Subscription] {
        let now = Date()

        var a = Subscription(name: "HK BGP-A", resetDay: 1)
        a.lastTraffic = TrafficInfo(
            upload: 8_000_000_000,
            download: 42_000_000_000,
            total: 100_000_000_000,
            expire: Int64(now.addingTimeInterval(86400 * 20).timeIntervalSince1970),
            fetchedAt: now
        )
        a.history = Self.mockHistory(endingAt: a.lastTraffic!)

        var b = Subscription(name: "JP SoftEther", resetDay: 15)
        b.lastTraffic = TrafficInfo(
            upload: 120_000_000_000,
            download: 800_000_000_000,
            total: 1_000_000_000_000,
            expire: Int64(now.addingTimeInterval(86400 * 5).timeIntervalSince1970),
            fetchedAt: now
        )
        b.history = Self.mockHistory(endingAt: b.lastTraffic!)

        var c = Subscription(name: "SG Trojan", resetDay: 28)
        c.lastTraffic = TrafficInfo(
            upload: 0,
            download: 0,
            total: 50_000_000_000,
            expire: Int64(now.addingTimeInterval(-86400 * 2).timeIntervalSince1970),
            fetchedAt: now
        )
        c.lastError = "403 Forbidden (mock)"

        return [a, b, c]
    }

    /// 生成截止「昨天」的 days 天每日快照，用于 Mock 模式直接演示趋势，免去等待多日真实拉取。
    /// used 从低位线性爬升到 finalUsed 附近（严格小于 finalUsed），且严格单调递增，
    /// 避免触发 Trend 的「重置截断」（used 单日骤降超一半会被判为重置点）。
    /// 今天刷新会再追加一帧（≈finalUsed），使跨度继续延伸且仍单调递增。
    private static func mockHistory(endingAt traffic: TrafficInfo, days: Int = 12) -> [TrafficRecord] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let finalUsed = traffic.used
        let uploadRatio = finalUsed > 0 ? Double(traffic.upload) / Double(finalUsed) : 0
        var records: [TrafficRecord] = []
        for i in 1...days {
            let daysAgo = days - i + 1            // i=1 → 最旧(12天前)；i=days → 昨天
            guard let d = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let progress = Double(i) / Double(days + 1)   // 昨天 ≈ finalUsed * days/(days+1) < finalUsed
            let used = Int64(Double(finalUsed) * progress)
            let upload = Int64(Double(used) * uploadRatio)
            let download = max(used - upload, 0)
            records.append(TrafficRecord(date: d, upload: upload, download: download))
        }
        return records
    }
}
