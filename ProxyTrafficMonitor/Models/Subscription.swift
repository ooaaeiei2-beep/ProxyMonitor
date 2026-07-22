import Foundation

/// 单个订阅配置。每个订阅有独立的重置日（按月重置模式）。
struct Subscription: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String                 // 实际值存 Keychain，JSON 中排除（见 CodingKeys）
    var userAgent: String
    var resetDay: Int?              // 人工配置的重置日（1-31）
    var inferredResetDay: Int?      // 程序推断的重置日（辅助校验）
    var lastTraffic: TrafficInfo?   // 最近一次拉取结果
    var lastError: String?          // 最近一次拉取错误（瞬态，不持久化）
    var history: [TrafficRecord]    // 每日快照，用于推断重置日

    enum CodingKeys: String, CodingKey {
        // 注意：url（走 Keychain）与 lastError（瞬态）不进入 UserDefaults
        case id, name, userAgent, resetDay, inferredResetDay, lastTraffic, history
    }

    init(name: String,
         url: String = "",
         userAgent: String = "clash-verge/v1.5.11",
         resetDay: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.userAgent = userAgent
        self.resetDay = resetDay
        self.inferredResetDay = nil
        self.lastTraffic = nil
        self.lastError = nil
        self.history = []
    }

    /// 自定义解码：url 实际存 Keychain（JSON 排除），lastError 为瞬态字段，均给默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = ""                       // 从 Keychain 回填，见 SubscriptionStore
        self.userAgent = try c.decode(String.self, forKey: .userAgent)
        self.resetDay = try c.decodeIfPresent(Int.self, forKey: .resetDay)
        self.inferredResetDay = try c.decodeIfPresent(Int.self, forKey: .inferredResetDay)
        self.lastTraffic = try c.decodeIfPresent(TrafficInfo.self, forKey: .lastTraffic)
        self.history = try c.decodeIfPresent([TrafficRecord].self, forKey: .history) ?? []
        self.lastError = nil                // 瞬态，不持久化
    }

    /// 有效重置日：优先人工配置，其次程序推断
    var effectiveResetDay: Int? {
        resetDay ?? inferredResetDay
    }

    /// 距下次重置的天数。基于有效重置日计算，已过本月重置日则算到下月。
    func daysUntilReset(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let resetDay = effectiveResetDay, (1...31).contains(resetDay) else { return nil }
        let today = calendar.startOfDay(for: now)

        // 本月重置日
        var comps = calendar.dateComponents([.year, .month], from: today)
        comps.day = resetDay
        if let thisReset = calendar.date(from: comps), thisReset >= today {
            return calendar.dateComponents([.day], from: today, to: thisReset).day ?? 0
        }

        // 下月重置日（处理月末天数不足，如 31 号在 2 月）
        guard let nextMonthAnchor = calendar.date(byAdding: .month, value: 1, to: today) else { return nil }
        var nextComps = calendar.dateComponents([.year, .month], from: nextMonthAnchor)
        let nextMonthLength = calendar.range(of: .day, in: .month, for: nextMonthAnchor)?.count ?? 28
        nextComps.day = min(resetDay, nextMonthLength)
        if let nextReset = calendar.date(from: nextComps) {
            return calendar.dateComponents([.day], from: today, to: nextReset).day ?? 0
        }
        return nil
    }
}
