import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SubscriptionStore!
    private var fetcher: TrafficFetcher!
    private var statusBar: StatusBarController!
    private var wakeRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        PTMLogger.info("app 启动（v\(version) build \(build)，\(ProcessInfo.processInfo.operatingSystemVersionString)）")

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

        // 系统唤醒后补一次刷新：睡眠期间调度器不会触发，这段窗口是必然丢失的。
        // 延迟 10 秒而非 5 分钟——只给 Wi-Fi 重连留时间；过长的延迟本身也会被 App Nap 再次推迟。
        // 用 Task 延迟 + 去重，避免多次唤醒叠加多个刷新。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.wakeRefreshTask == nil else {
                PTMLogger.info("系统唤醒，已有待执行的刷新，跳过")
                return
            }
            PTMLogger.info("系统唤醒，10 秒后刷新数据")
            self.wakeRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                self?.wakeRefreshTask = nil
                await self?.fetcher?.handleWake()
            }
        }

        PTMLogger.info("状态栏已创建，开始定时拉取")
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeRefreshTask?.cancel()
        fetcher.stop()
    }
}
