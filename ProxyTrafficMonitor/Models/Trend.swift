import Foundation

/// 流量趋势推算结果
struct TrafficTrend {
    let hasEnoughData: Bool
    let burnRatePerDay: Double?      // 字节/天（仅统计上次重置后的区间）
    let daysToExhaust: Int?
    let estimatedExhaustionDate: Date?
    let willExceedBeforeReset: Bool  // 预计耗尽日早于下次重置日（周期内将超量）
}

extension Subscription {
    /// 基于每日快照 history 推算趋势。无当前流量或无足够历史时 hasEnoughData=false。
    var trend: TrafficTrend {
        guard let traffic = lastTraffic, traffic.total > 0 else {
            return TrafficTrend(hasEnoughData: false, burnRatePerDay: nil,
                                daysToExhaust: nil, estimatedExhaustionDate: nil,
                                willExceedBeforeReset: false)
        }
        let cal = Calendar.current
        let sorted = history.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else {
            return TrafficTrend(hasEnoughData: false, burnRatePerDay: nil,
                                daysToExhaust: nil, estimatedExhaustionDate: nil,
                                willExceedBeforeReset: false)
        }
        // 取「上次重置之后」的快照：used 显著下降（< 前一日一半）视为重置点，从此截断
        var tail = sorted
        for i in (1..<sorted.count).reversed() {
            if sorted[i].used < sorted[i - 1].used / 2 {
                tail = Array(sorted[i...])
                break
            }
        }
        guard let first = tail.first, let last = tail.last,
              let days = cal.dateComponents([.day],
                  from: cal.startOfDay(for: first.date),
                  to: cal.startOfDay(for: last.date)).day,
              days >= 1, tail.count >= 2 else {
            return TrafficTrend(hasEnoughData: false, burnRatePerDay: nil,
                                daysToExhaust: nil, estimatedExhaustionDate: nil,
                                willExceedBeforeReset: false)
        }
        let delta = Double(last.used) - Double(first.used)
        guard delta > 0 else {
            // 消耗为 0 或回退（刚重置），无法预测耗尽
            return TrafficTrend(hasEnoughData: false, burnRatePerDay: nil,
                                daysToExhaust: nil, estimatedExhaustionDate: nil,
                                willExceedBeforeReset: false)
        }
        let burnRate = delta / Double(days)                 // 字节/天
        let remaining = Double(traffic.remaining)
        let daysToExhaust = max(0, Int((remaining / burnRate).rounded(.up)))
        let now = Date()
        // Calendar.date(byAdding:value:to:) 对有效 Date 不会失败，此处安全解包避免 force-unwrap
        guard let est = cal.date(byAdding: .day, value: daysToExhaust, to: now) else {
            return TrafficTrend(hasEnoughData: false, burnRatePerDay: nil,
                                daysToExhaust: nil, estimatedExhaustionDate: nil,
                                willExceedBeforeReset: false)
        }
        var willExceed = false
        if let d = daysUntilReset(),
           let resetDate = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now)) {
            willExceed = est < resetDate
        }
        return TrafficTrend(hasEnoughData: true, burnRatePerDay: burnRate,
                            daysToExhaust: daysToExhaust,
                            estimatedExhaustionDate: est,
                            willExceedBeforeReset: willExceed)
    }
}
