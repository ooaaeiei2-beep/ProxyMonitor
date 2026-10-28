import Foundation
import Combine

/// 定时拉取订阅流量。启动即拉一次，之后每 20~30 分钟（随机间隔，避免固定节奏）。
///
/// 调度使用 `NSBackgroundActivityScheduler` 而非 `Timer`：
/// 本应用是窗口为空的 LSUIElement，进入 App Nap 后主 runloop 上的 `Timer` 会被系统合并/推迟，
/// 曾实测出现连续 4 小时无刷新且无任何记录。该调度器由系统负责唤醒，不受 App Nap 抑制。
@MainActor
final class TrafficFetcher: ObservableObject {
    @Published private(set) var lastError: String?
    /// 一次「全部刷新」结束后的汇总结果（仅全部刷新 emit；单订阅刷新不发，以免干扰「立即刷新」文字）。
    struct RefreshOutcome {
        let total: Int      // 参与刷新的订阅总数
        let failures: Int   // 刷新失败的订阅数
    }
    @Published private(set) var lastOutcome: RefreshOutcome?
    /// 正在刷新的订阅 id 集合（含全部刷新的哨兵 ID）。状态栏用它来区分「全部刷新」与「单订阅刷新」，
    /// 并在菜单元内驱动每个菜单项的 spinner 动画；`StatusBarController` 另据此推导「是否有刷新在进行」
    /// （`!refreshingIDs.isEmpty`），不再单独维护一个 `isRefreshing` 布尔量。
    @Published private(set) var refreshingIDs: Set<UUID> = []

    private let provider: TrafficProvider
    private let store: SubscriptionStore
    private let inferrer: ResetDayInferrer
    private let notifier: NotificationService
    /// 主刷新调度器（系统级，抗 App Nap）
    private var scheduler: NSBackgroundActivityScheduler?
    /// 刷新执行期间持有的活动断言，避免拉取中途被系统降频或挂起
    private var activityToken: NSObjectProtocol?
    /// 最近一次「发起」刷新的时间，用于抑制调度器短时间内的重复触发
    private var lastRefreshAttemptAt: Date?

    /// 进行中的刷新集合：全部刷新用 allRefreshID，单订阅用各自 id。
    /// 用于支持「单订阅刷新不被全局刷新拦截」的并发场景，并避免同一订阅重复拉取。
    private var activeRefreshes: Set<UUID> = []
    private let allRefreshID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

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
        PTMLogger.info("启动定时拉取")
        refresh()
        scheduleNext()
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        endActivityShield()
        PTMLogger.info("已停止定时拉取")
    }

    /// 系统唤醒后调用：重排调度并立即刷新。
    /// 睡眠期间调度器不会触发，这段窗口是必然丢失的，必须补一次。
    func handleWake() {
        PTMLogger.info("系统唤醒：重排调度并立即刷新")
        scheduleNext()
        refresh()
    }

    /// 立即刷新所有订阅。并行拉取，每个订阅各自独立开始/结束，菜单内每行可独立显示转圈。
    func refresh(manual: Bool = false) {
        // 实测 NSBackgroundActivityScheduler 在短间隔下可能出现同一秒内的连续触发，
        // 用最小间隔兜住，避免重复拉取。手动刷新不受限制。
        if !manual, let last = lastRefreshAttemptAt,
           Date().timeIntervalSince(last) < 60 {
            PTMLogger.debug("距上次刷新不足 60s，跳过本次触发")
            return
        }
        guard beginRefresh(allRefreshID) else { return }
        lastRefreshAttemptAt = Date()
        let snapshot = store.subscriptions
        guard !snapshot.isEmpty else {
            endRefresh(allRefreshID)
            return
        }

        lastError = nil
        let startedAt = Date()
        beginActivityShield()
        PTMLogger.info("全部刷新开始（订阅数=\(snapshot.count)，触发=\(manual ? "手动" : "定时")）")

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
            let elapsed = Date().timeIntervalSince(startedAt)
            PTMLogger.info(String(format: "全部刷新完成（failures=%d/%d，耗时=%.1fs）",
                                  failureCount, snapshot.count, elapsed))
            self.endActivityShield()
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
        return true
    }

    private func endRefresh(_ id: UUID) {
        activeRefreshes.remove(id)
        refreshingIDs = activeRefreshes
    }

    private func fetchOne(_ subscription: Subscription) async -> Bool {
        #if DEBUG
        if SubscriptionStore.isMockMode {
            return await fetchOneMock(subscription)
        }
        #endif
        do {
            let traffic = try await provider.fetchTraffic(for: subscription)
            store.updateTraffic(id: subscription.id, traffic: traffic)
            if let updated = store.subscriptions.first(where: { $0.id == subscription.id }) {
                inferrer.observe(subscriptionId: subscription.id, traffic: traffic, store: store)
                notifier.evaluate(subscription: updated, traffic: traffic)
            }
            return true
        } catch {
            let code = Self.errorCode(for: error)
            let msg = "\(subscription.name): \(error.localizedDescription)"
            store.setError(id: subscription.id, message: msg, code: code)
            lastError = msg
            // 落盘的只有 name/code；detail 走 redact（URLError 的本地化描述可能含完整订阅 URL）
            PTMLogger.error("拉取失败（name=\(subscription.name) code=\(code) detail=\(error.localizedDescription)）")
            return false
        }
    }

#if DEBUG
    /// Mock 模式下的模拟拉取：制造网络延迟让状态栏 spinner 可见，并抖动已用流量使数字变化。
    /// 带 lastError 的订阅（如 mock 的 SG Trojan）刷新后仍抛错，保留"错误图标"演示路径。
    private func fetchOneMock(_ subscription: Subscription) async -> Bool {
        // 模拟网络往返延迟（0.7~1.4s），让"刷新中"状态可见
        try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 700...1400)) * 1_000_000)

        if let existingError = subscription.lastError {
            let msg = existingError
            store.setError(id: subscription.id, message: msg, code: "mock")
            lastError = msg
            PTMLogger.debug("Mock 拉取（错误态保持）：\(msg)")
            return false
        }

        let base = subscription.lastTraffic
            ?? TrafficInfo(upload: 0, download: 0, total: 100_000_000_000, expire: 0, fetchedAt: Date())
        let jitter = 1 + Double.random(in: 0.002...0.02)   // 已用流量 +0.2%~2%
        let newUsed = Double(base.used) * jitter
        let newDownload = Int64(max(newUsed - Double(base.upload), 0))
        let traffic = TrafficInfo(
            upload: base.upload,
            download: newDownload,
            total: base.total,
            expire: base.expire,
            fetchedAt: Date()
        )
        store.updateTraffic(id: subscription.id, traffic: traffic)
        PTMLogger.debug("Mock 拉取成功：\(subscription.name) → \(String(format: "%.2f%%", traffic.usagePercentage))")
        return true
    }
#endif

    /// 用 `NSBackgroundActivityScheduler` 调度下一次刷新。
    ///
    /// 参数取 `interval=1500 / tolerance=300`：实测该调度器倾向在
    /// `interval - tolerance` 处触发（用 30/15 观测到 61s→76s→128s→145s 的节奏），
    /// 因此实际间隔约 20 分钟，且每次由系统带随机偏移，不需要再自己掷骰子。
    /// 注意：`completion` 必须调用，否则调度链会中断。
    private func scheduleNext() {
        scheduler?.invalidate()

        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.xushuda.proxytrafficmonitor.refresh"
        )
        scheduler.repeats = true
        scheduler.interval = 1500       // 25 分钟
        scheduler.tolerance = 300       // ±5 分钟，交由系统合并唤醒
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                self?.refresh()
                completion(.finished)
            }
        }

        self.scheduler = scheduler
        PTMLogger.info("已调度刷新（interval=1500s，tolerance=300s，实际约 20 分钟一次）")
    }

    // MARK: - 活动断言

    /// 拉取期间持有 `.background` 断言：保证这段工作不被系统中途降频或打断。
    /// 只覆盖"正在刷新"的窗口，常驻持有会阻止 App Nap，属于滥用。
    private func beginActivityShield() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "刷新订阅流量"
        )
    }

    private func endActivityShield() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    // MARK: - 错误归一

    /// 把错误归一为稳定短代码，用于持久化与日志。
    /// 不含 URL、不含本地化文本——要落盘的东西必须能安全地长期保留。
    private static func errorCode(for error: Error) -> String {
        if let providerError = error as? TrafficProviderError {
            switch providerError {
            case .invalidURL:                   return "invalid_url"
            case .noSubscriptionUserinfoHeader: return "missing_header"
            case .parseFailed:                  return "parse_failed"
            case .networkError:                 return "network"
            }
        }
        if let urlError = error as? URLError {
            return "urlerror_\(urlError.code.rawValue)"
        }
        let nsError = error as NSError
        return "\(nsError.domain)_\(nsError.code)"
    }
}
