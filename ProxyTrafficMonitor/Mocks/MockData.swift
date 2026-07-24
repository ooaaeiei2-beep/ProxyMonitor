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

        var b = Subscription(name: "JP SoftEther", resetDay: 15)
        b.lastTraffic = TrafficInfo(
            upload: 120_000_000_000,
            download: 800_000_000_000,
            total: 1_000_000_000_000,
            expire: Int64(now.addingTimeInterval(86400 * 5).timeIntervalSince1970),
            fetchedAt: now
        )

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
}
