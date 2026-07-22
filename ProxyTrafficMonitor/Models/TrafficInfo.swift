import Foundation

/// 订阅流量信息，来自 Subscription-Userinfo 响应头
/// upload/download/total 单位为字节，expire 为 Unix 秒级时间戳（UTC）
struct TrafficInfo: Codable, Equatable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64?
    let fetchedAt: Date

    var used: Int64 { upload + download }
    var remaining: Int64 { max(0, total - used) }

    var usagePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    var expireDate: Date? {
        guard let expire, expire > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expire))
    }
}
