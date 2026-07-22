import Foundation
import Combine

/// 状态栏显示模式
enum DisplayMode: String, CaseIterable {
    case carousel   // 轮播各订阅百分比
    case total      // 显示总百分比（Σ已用 / Σ总额）
}

/// 订阅配置与历史的持久化（UserDefaults + JSON 编码；订阅链接 url 存 Keychain）
final class SubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [Subscription] = []
    /// 状态栏显示模式（默认轮播），改动即持久化
    @Published var displayMode: DisplayMode = .carousel {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode.v1") }
    }

    private let defaults: UserDefaults
    private let key = "subscriptions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
        KeychainHelper.save(subscription.url, forKey: "url.\(subscription.id.uuidString)")
        save()
    }

    func update(_ subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index] = subscription
        // 编辑可能改了订阅链接，同步更新 Keychain
        KeychainHelper.save(subscription.url, forKey: "url.\(subscription.id.uuidString)")
        save()
    }

    func remove(id: UUID) {
        subscriptions.removeAll { $0.id == id }
        KeychainHelper.delete("url.\(id.uuidString)")   // 清理 Keychain
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            let sub = subscriptions[index]
            KeychainHelper.delete("url.\(sub.id.uuidString)")
            subscriptions.remove(at: index)
        }
        save()
    }

    func removeAll() {
        for sub in subscriptions {
            KeychainHelper.delete("url.\(sub.id.uuidString)")
        }
        subscriptions.removeAll()
        save()
    }

    /// 采用推断的重置日（写入人工配置）
    func adoptInferredResetDay(id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }),
              let inferred = subscriptions[index].inferredResetDay else { return }
        subscriptions[index].resetDay = inferred
        subscriptions[index].inferredResetDay = nil
        save()
    }

    /// 记录最近一次拉取错误（瞬态，不影响持久化）
    func setError(id: UUID, message: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].lastError = message
    }

    func clearError(id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].lastError = nil
    }

    /// 拉取后更新流量与每日快照（同一天覆盖，仅保留近 60 天）
    func updateTraffic(id: UUID, traffic: TrafficInfo, calendar: Calendar = .current) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].lastTraffic = traffic
        subscriptions[index].lastError = nil   // 成功即清除错误

        let today = calendar.startOfDay(for: Date())
        subscriptions[index].history.removeAll { calendar.isDate($0.date, inSameDayAs: today) }
        subscriptions[index].history.append(TrafficRecord(date: today, upload: traffic.upload, download: traffic.download))

        let cutoff = calendar.date(byAdding: .day, value: -60, to: today)!
        subscriptions[index].history.removeAll { $0.date < cutoff }
        save()
    }

    func updateInferredResetDay(id: UUID, day: Int?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].inferredResetDay = day
        save()
    }

    private func save() {
        // 仅持久化除 url 外的字段到 UserDefaults（CodingKeys 已排除 url）。
        // url 存于 Keychain，只在 add/update/remove 时同步，避免每次流量更新都重写 Keychain。
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Subscription].self, from: data) else { return }
        var result = decoded
        // 从 Keychain 还原 url
        for i in result.indices {
            result[i].url = KeychainHelper.load("url.\(result[i].id.uuidString)") ?? ""
        }
        subscriptions = result
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode.v1") ?? "") ?? .carousel
    }
}
