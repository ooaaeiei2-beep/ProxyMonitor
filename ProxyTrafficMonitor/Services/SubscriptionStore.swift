import Foundation
import Combine

/// 状态栏显示模式
enum DisplayMode: String, CaseIterable {
    case max        // 占比最高的订阅（默认/推荐）
    case carousel   // 轮播各订阅百分比
    case total      // 显示所有订阅的总百分比
}

/// 订阅配置与历史的持久化（UserDefaults + JSON 编码；订阅链接 url 存 Keychain）
final class SubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [Subscription] = []
    /// 状态栏显示模式（默认占比最高 .max），改动即持久化
    @Published var displayMode: DisplayMode = .max {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode.v1") }
    }
    /// 最近一次「成功」拉取完成的时间。状态栏据此判断数据是否陈旧（>10 分钟无成功刷新 → clock 图标）。
    /// 在 `updateTraffic`（所有成功路径的唯一入口）中赋值，覆盖真实与 Mock 拉取。
    @Published private(set) var lastSuccessfulFetchAt: Date?

    /// Keychain 写入失败提示（订阅链接未保存成功）。UI 层观察此属性弹 Alert（修复 #4）。
    /// 即使 Keychain 失败，其余配置字段仍会 `save()` 到 UserDefaults，仅 url 会缺失——文案已说明。
    @Published var keychainSaveError: String?

    private let defaults: UserDefaults
    private let key = "subscriptions.v1"

    /// 调试 Mock 模式标记。DEBUG + 环境变量 `PTM_USE_MOCK=1` 时由 `load()` 置 true，
    /// `TrafficFetcher` 据此跳过网络拉取，避免 mock 数据被「拉取出错」覆盖。
    static var isMockMode: Bool = false

    /// 运行时 Mock 开关（仅 DEBUG）。设置界面 Toggle 绑定；持久化到 UserDefaults。
    @Published var mockModeEnabled: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "mockMode.v1")
        #else
        return false
        #endif
    }()

    /// DEBUG 下是否启用 mock：环境变量 PTM_USE_MOCK=1 或 持久化开关任一为真。
    #if DEBUG
    private var shouldUseMock: Bool {
        ProcessInfo.processInfo.environment["PTM_USE_MOCK"] == "1"
        || UserDefaults.standard.bool(forKey: "mockMode.v1")
    }
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 注意：`load()` 已改为 async（修复 #5，避免主线程同步读 Keychain 卡 UI），
        // 由调用方（AppDelegate）在启动阶段 `await load()` 完成后再开始拉取，保证启动行为不变。
    }

    /// 异步加载（修复 #5）：Keychain 读取在后台串行队列执行，不阻塞主线程；
    /// 完成后在主线程更新 @Published 状态。Mock 模式直接返回，不触碰真实 Keychain。
    func load() async {
        #if DEBUG
        if shouldUseMock {
            Self.isMockMode = true
            await loadMock()
            return
        }
        #endif
        Self.isMockMode = false
        await loadReal()
    }

#if DEBUG
    /// 运行时切换 Mock 模式：写入持久化开关、设置静态标志并重载对应数据。
    func setMockMode(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: "mockMode.v1")
        Self.isMockMode = on
        if on { await loadMock() } else { await loadReal() }
    }

    private func loadMock() async {
        var mock = MockData.subscriptions
        for i in mock.indices { mock[i].url = "mock://\(mock[i].name)" }
        let snapshot = mock
        await MainActor.run {
            self.subscriptions = snapshot
            self.displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode.v1") ?? "") ?? .max
        }
        PTMLogger.info("Mock 模式已启用，跳过 Keychain 读取")
    }
#endif

    private func loadReal() async {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Subscription].self, from: data) else { return }
        var result = decoded
        // 从 Keychain 还原 url（后台队列，不阻塞主线程）
        for i in result.indices {
            result[i].url = await KeychainHelper.load("url.\(result[i].id.uuidString)") ?? ""
        }
        let snapshot = result   // 拷贝为不可变，避免被并发闭包捕获 var
        await MainActor.run {
            self.subscriptions = snapshot
            self.displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode.v1") ?? "") ?? .max
        }
    }

    func add(_ subscription: Subscription) async {
        let key = "url.\(subscription.id.uuidString)"
        // 先写 Keychain（后台），失败也继续保存其余字段到 UserDefaults（修复 #4）。
        let urlSaved = await KeychainHelper.save(subscription.url, forKey: key)
        await MainActor.run {
            self.subscriptions.append(subscription)
            self.save()
            if !urlSaved {
                self.keychainSaveError = "订阅链接保存失败：钥匙串不可用（可能被系统拦截或权限不足）。订阅配置已保存，但链接需要在设置中重新填写后保存。"
            }
        }
    }

    func update(_ subscription: Subscription) async {
        // 不存在则跳过（主线程判断，避免无谓的 Keychain 写入）
        let exists = await MainActor.run { subscriptions.contains { $0.id == subscription.id } }
        guard exists else { return }

        let key = "url.\(subscription.id.uuidString)"
        let urlSaved = await KeychainHelper.save(subscription.url, forKey: key)
        await MainActor.run {
            guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
            subscriptions[index] = subscription
            save()
            if !urlSaved {
                keychainSaveError = "订阅链接保存失败：钥匙串不可用（可能被系统拦截或权限不足）。订阅配置已保存，但链接需要在设置中重新填写后保存。"
            }
        }
    }

    func remove(id: UUID) async {
        let key = "url.\(id.uuidString)"
        _ = await KeychainHelper.delete(key)   // 清理 Keychain（失败仅日志）
        await MainActor.run {
            subscriptions.removeAll { $0.id == id }
            save()
        }
    }

    func remove(atOffsets offsets: IndexSet) async {
        // 先取出要删除的 id（主线程读取模型），再后台清 Keychain，最后主线程移除。
        let ids = await MainActor.run { offsets.map { subscriptions[$0].id } }
        for id in ids {
            _ = await KeychainHelper.delete("url.\(id.uuidString)")
        }
        await MainActor.run {
            for index in offsets.sorted(by: >) {
                subscriptions.remove(at: index)
            }
            save()
        }
    }

    func removeAll() async {
        let ids = await MainActor.run { subscriptions.map { $0.id } }
        for id in ids {
            _ = await KeychainHelper.delete("url.\(id.uuidString)")
        }
        await MainActor.run {
            subscriptions.removeAll()
            save()
        }
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
        lastSuccessfulFetchAt = Date()         // 记录成功刷新时间（数据陈旧判定用）

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
        // url 存于 Keychain，只在 add/update/remove 时同步（见上方 async 方法），避免每次流量更新都重写 Keychain。
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: key)
        }
    }
}
