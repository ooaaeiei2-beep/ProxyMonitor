import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SubscriptionStore!
    private var fetcher: TrafficFetcher!
    private var statusBar: StatusBarController!
    private var wakeRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PTMLogger.info("app 启动")

        let provider = SubscriptionProvider()
        let store = SubscriptionStore()
        let inferrer = ResetDayInferrer()
        let notifier = NotificationService()
        let fetcher = TrafficFetcher(provider: provider, store: store,
                                     inferrer: inferrer, notifier: notifier)

        self.store = store
        self.fetcher = fetcher
        statusBar = StatusBarController(store: store, fetcher: fetcher)
        // 先 await 异步加载（含 Keychain 读取，修复 #5 不再卡主线程），完成后再启动首次拉取，
        // 保持「启动即拉取一次」的行为不变（store 必须加载完才能拿到订阅列表）。
        Task {
            await store.load()
            fetcher.start()
        }

        // 系统唤醒后延迟 5 分钟再刷新（休眠期间定时器不触发，避免数据陈旧；
        // 用 Task 延迟 + 去重，避免多次唤醒叠加多个刷新）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.wakeRefreshTask == nil else {
                PTMLogger.info("系统唤醒，已有待执行的延迟刷新，跳过")
                return
            }
            PTMLogger.info("系统唤醒，5 分钟后刷新数据")
            self?.wakeRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self?.wakeRefreshTask = nil
                await self?.fetcher?.refresh()
            }
        }

        PTMLogger.info("状态栏已创建，开始定时拉取")
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeRefreshTask?.cancel()
        fetcher.stop()
    }
}
