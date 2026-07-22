import Foundation
import UserNotifications

/// 流量预警、到期提醒、重置提醒
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    /// 去重表：通知 key -> 最近发送时间。持久化到 UserDefaults，重启不再重复轰炸。
    /// 抑制窗口 24h：超出窗口可再次提醒（如次日重新预警）。
    private var notifiedAt: [String: Date] = [:]
    private let suppressWindow: TimeInterval = 86400  // 24h
    private let storeKey = "notifiedKeys.v1"

    init() {
        requestAuthorization()
        loadNotified()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                PTMLogger.error("未授权通知")
            }
        }
    }

    /// 每次拉取后评估是否需要发通知
    func evaluate(subscription: Subscription, traffic: TrafficInfo) {
        let pct = traffic.usagePercentage

        // 用量预警：95% / 80%
        if pct >= 95 {
            notify(key: "\(subscription.id)-pct95",
                   title: "\(subscription.name) 流量告急",
                   body: "已用 \(String(format: "%.1f%%", pct))，剩余 \(ByteFormatter.readable(traffic.remaining))")
        } else if pct >= 80 {
            notify(key: "\(subscription.id)-pct80",
                   title: "\(subscription.name) 流量预警",
                   body: "已用 \(String(format: "%.1f%%", pct))，剩余 \(ByteFormatter.readable(traffic.remaining))")
        }

        // 到期提醒：1 天 / 7 天
        if let expireDate = traffic.expireDate {
            let days = Int(expireDate.timeIntervalSinceNow / 86400)
            if days <= 1 {
                notify(key: "\(subscription.id)-expire1",
                       title: "\(subscription.name) 即将到期",
                       body: days <= 0 ? "套餐今天到期" : "套餐明天到期")
            } else if days <= 7 {
                notify(key: "\(subscription.id)-expire7",
                       title: "\(subscription.name) 即将到期",
                       body: "套餐还剩 \(days) 天到期")
            }
        }

        // 重置提醒：1 天后重置
        if let days = subscription.daysUntilReset(), days <= 1 {
            notify(key: "\(subscription.id)-reset",
                   title: "\(subscription.name) 即将重置流量",
                   body: days == 0 ? "今天重置月度流量" : "明天重置月度流量")
        }
    }

    private func notify(key: String, title: String, body: String) {
        // 去重：窗口内已发过则跳过
        if let last = notifiedAt[key], Date().timeIntervalSince(last) < suppressWindow {
            return
        }
        notifiedAt[key] = Date()
        saveNotified()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        center.add(request)
        PTMLogger.debug("发送通知: \(title)")
    }

    // MARK: - 持久化

    private func saveNotified() {
        let dict = notifiedAt.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    private func loadNotified() {
        guard let dict = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: TimeInterval] else { return }
        notifiedAt = dict.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
