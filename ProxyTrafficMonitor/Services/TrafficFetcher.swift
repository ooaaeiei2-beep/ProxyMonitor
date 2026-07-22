import Foundation
import Combine

/// 定时拉取订阅流量。启动即拉一次，之后每 10 分钟。
@MainActor
final class TrafficFetcher: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// 一次「全部刷新」结束后的汇总结果（仅全部刷新 emit；单订阅刷新不发，以免干扰「立即刷新」文字）。
    struct RefreshOutcome {
        let total: Int      // 参与刷新的订阅总数
        let failures: Int   // 刷新失败的订阅数
    }
    @Published private(set) var lastOutcome: RefreshOutcome?
    /// 正在刷新的订阅 id 集合（含全部刷新的哨兵 ID）。状态栏用它来区分「全部刷新」与「单订阅刷新」，
    /// 并在菜单元内驱动每个菜单项的 spinner 动画。
    @Published private(set) var refreshingIDs: Set<UUID> = []

    private let provider: TrafficProvider
    private let store: SubscriptionStore
    private let inferrer: ResetDayInferrer
    private let notifier: NotificationService
    private var timer: Timer?

    /// 进行中的刷新集合：全部刷新用 allRefreshID，单订阅用各自 id。
    /// 用于支持「单订阅刷新不被全局刷新拦截」的并发场景，并避免同一订阅重复拉取。
    private var activeRefreshes: Set<UUID> = []
    private let allRefreshID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

    /// 全部刷新使用的哨兵 ID（供状态栏区分「全部刷新」与单订阅刷新）
    var allRefreshSentinel: UUID { allRefreshID }

    init(provider: TrafficProvider,
         store: SubscriptionStore,
         inferrer: ResetDayInferrer,
         notifier: NotificationService) {
        self.provider = provider
        self.store = store
        self.inferrer = inferrer
        self.notifier = notifier
    }

    func start() {
        refresh()
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即刷新所有订阅。并行拉取，每个订阅各自独立开始/结束，菜单内每行可独立显示转圈。
    func refresh(manual: Bool = false) {
        guard beginRefresh(allRefreshID) else { return }
        let snapshot = store.subscriptions
        guard !snapshot.isEmpty else {
            endRefresh(allRefreshID)
            return
        }

        lastError = nil

        Task {
            var failureCount = 0
            // 并行拉取所有订阅；跳过正在进行中的单订阅，避免重复拉取。
            // 每个订阅在 group 内 begin/end 自己的 id，使菜单每行能独立转圈并在完成时就地刷新。
            await withTaskGroup(of: (UUID, Bool).self) { group in
            for subscription in snapshot where !activeRefreshes.contains(subscription.id) {
                group.addTask {
                    _ = await self.beginRefresh(subscription.id)
                    let ok = await self.fetchOne(subscription)
                    await self.endRefresh(subscription.id)
                    return (subscription.id, ok)
                }
            }
                while let (_, ok) = await group.next() {
                    if !ok { failureCount += 1 }
                }
            }
            endRefresh(allRefreshID)
            self.lastOutcome = RefreshOutcome(total: snapshot.count, failures: failureCount)
            PTMLogger.debug("全部刷新完成（failures=\(failureCount)/\(snapshot.count)）")
        }
    }

    /// 刷新单个订阅（菜单项上的刷新按钮调用）。
    /// 不被全局刷新拦截：仅当该订阅自身正在拉取时才跳过，可与全部刷新并发进行。
    func refresh(subscription: Subscription, manual: Bool = false) {
        guard beginRefresh(subscription.id) else { return }
        Task {
            _ = await fetchOne(subscription)
            endRefresh(subscription.id)
        }
    }

    // MARK: - 内部

    /// 标记某次刷新开始；若该 id 已在刷新中则返回 false（防重入）
    private func beginRefresh(_ id: UUID) -> Bool {
        if activeRefreshes.contains(id) { return false }
        activeRefreshes.insert(id)
        refreshingIDs = activeRefreshes
        isRefreshing = true
        return true
    }

    private func endRefresh(_ id: UUID) {
        activeRefreshes.remove(id)
        refreshingIDs = activeRefreshes
        if activeRefreshes.isEmpty {
            isRefreshing = false
        }
    }

    private func fetchOne(_ subscription: Subscription) async -> Bool {
        do {
            let traffic = try await provider.fetchTraffic(for: subscription)
            store.updateTraffic(id: subscription.id, traffic: traffic)
            if let updated = store.subscriptions.first(where: { $0.id == subscription.id }) {
                inferrer.observe(subscriptionId: subscription.id, traffic: traffic, store: store)
                notifier.evaluate(subscription: updated, traffic: traffic)
            }
            return true
        } catch {
            let msg = "\(subscription.name): \(error.localizedDescription)"
            store.setError(id: subscription.id, message: msg)
            lastError = msg
            PTMLogger.error("拉取失败 \(msg)")
            return false
        }
    }

    /// 自递归非重复定时器：每次触发后用新的随机间隔（20~30 分钟）重新调度，避免长时间固定节奏。
    private func scheduleNext() {
        timer?.invalidate()
        let next = TimeInterval.random(in: 1200...1800)
        timer = Timer.scheduledTimer(withTimeInterval: next, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleNext()   // 用新的随机间隔重新调度下一次
            }
        }
    }
}
