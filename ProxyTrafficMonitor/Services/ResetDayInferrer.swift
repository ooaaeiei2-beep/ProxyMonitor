import Foundation

/// 通过监控流量归零时点推断重置日。
/// 当某天用量相对前一日骤降（接近归零），记该日为推断重置日。
/// 作为人工配置的辅助校验：仅当与人工配置不一致时才记录推断值。
final class ResetDayInferrer {
    /// 归零判定阈值：当日用量低于前一日的 5% 视为已重置
    private let resetThreshold: Double = 0.05

    func observe(subscriptionId: UUID,
                 traffic: TrafficInfo,
                 store: SubscriptionStore,
                 calendar: Calendar = .current) {
        guard let subscription = store.subscriptions.first(where: { $0.id == subscriptionId }) else { return }
        let history = subscription.history.sorted { $0.date < $1.date }
        guard history.count >= 2 else { return }

        for i in 1..<history.count {
            let prev = history[i - 1]
            let curr = history[i]
            guard prev.used > 0 else { continue }
            let ratio = Double(curr.used) / Double(prev.used)
            if ratio <= resetThreshold {
                let day = calendar.component(.day, from: curr.date)
                // 仅当与人工配置不一致时更新推断值
                if subscription.resetDay != day {
                    store.updateInferredResetDay(id: subscriptionId, day: day)
                }
                break
            }
        }
    }
}
