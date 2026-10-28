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
    var lastError: String?          // 最近一次拉取的展示文本（瞬态，不持久化，可能含敏感信息）
    /// 最近一次失败的分类代码（持久化）。只存枚举化的短代码，不存原始错误文本，
    /// 因为 URLError 的 localizedDescription 可能带完整订阅 URL（含 token）。
    var lastErrorCode: String?
    /// 最近一次失败的时间（持久化）。重启后仍能看出"上次就失败了"，而不是一片空白。
    var lastErrorAt: Date?
    /// 最近一次成功拉取的时间（持久化，按订阅独立记录）。
    /// 陈旧判定与「上次成功：x 分钟前」都基于它，不能再依赖全局且不落盘的状态。
    var lastSuccessfulFetchAt: Date?
    var history: [TrafficRecord]    // 每日快照，用于推断重置日

    enum CodingKeys: String, CodingKey {
        // 注意：url 走 Keychain，lastError 为瞬态展示文本，二者都不进入 UserDefaults
        case id, name, userAgent, resetDay, inferredResetDay, lastTraffic, history
        case lastErrorCode, lastErrorAt, lastSuccessfulFetchAt
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
        self.lastErrorCode = nil
        self.lastErrorAt = nil
        self.lastSuccessfulFetchAt = nil
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
        self.lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
        self.lastErrorAt = try c.decodeIfPresent(Date.self, forKey: .lastErrorAt)
        self.lastSuccessfulFetchAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulFetchAt)
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
