import AppKit
import Combine

/// 状态栏控制器：创建 NSStatusItem，构建下拉菜单
@MainActor

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: SubscriptionStore
    private let fetcher: TrafficFetcher
    private var cancellables: Set<AnyCancellable> = []
    private var displayIndex = 0            // 当前轮播显示的订阅索引
    private var carouselTimer: Timer?
    private let carouselInterval: TimeInterval = 5   // 轮播间隔 5 秒
    private var staleTimer: Timer?          // 数据陈旧检查：每 60s 重算状态栏图标（clock / network）

    private var isMenuOpen = false                    // 菜单是否打开（避免打开时整体重排打断交互）
    private var liveTimer: Timer?                     // 菜单打开时的「更新于」live 计时器
    private var menuItemViews: [SubscriptionMenuItemView] = []  // 当前菜单内的订阅项视图（供 live 计时器 / 实时推送）
    private var menuRowViews: [MenuRowView] = []                // 当前菜单内的自绘动作行（关闭时清 hover）
    private var refreshAllItem: NSMenuItem?   // 「立即刷新」项（供结果汇总行定位）
    private var isRefreshing = false          // 是否有刷新在进行（状态栏图标切到刷新态，菜单收起后仍可见）

    // 刷新结果反馈
    private var outcomeBannerItem: NSMenuItem?       // 菜单底部临时汇总行（菜单开着时）
    private var outcomeBannerTimer: Timer?           // 汇总行自动移除定时器
    private var outcomeFlashIcon: String?            // 非 nil 时覆盖状态栏图标（菜单已关闭时）
    private var outcomeFlashTimer: Timer?            // 闪示到期后恢复图标

    // 方向 B：图标 + 文字合成进单张 NSImage（template），只改 button.image 并固定 length，
    // 彻底消除「运行时改 length → WindowServer 几何推送」与「子 layer.contents 重绘」两个死循环触发源。
    private var lastRenderedString: String?          // 记录当前文字，供深浅色切换 / 数据陈旧检查重渲染

    init(store: SubscriptionStore, fetcher: TrafficFetcher) {
        self.store = store
        self.fetcher = fetcher
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        rebuildMenu()
        startCarousel()
        startStaleTimer()

        // 订阅或流量变化：刷新状态栏百分比；菜单打开时**就地推送最新数据到各菜单项**（不做整体重排，避免打断交互）。
        // 关键：用 DispatchQueue.main 而非 RunLoop.main —— 前者在主队列（common modes）执行，
        // 菜单打开（NSEventTrackingRunLoopMode）期间也能触发，解决「菜单内容不跟随刷新」的问题。
        store.$subscriptions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.displayIndex = 0
                self?.updateButtonTitle()
                if let self, self.isMenuOpen {
                    self.pushLatestToMenuItems()
                } else {
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)

        // 刷新状态集合变化 → 驱动各订阅项行内 spinner，并让状态栏图标进入「刷新中」
        fetcher.$refreshingIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.applySpinnerState(ids)
            }
            .store(in: &cancellables)

        // 刷新结果汇总 → 菜单底部临时汇总行（菜单已关闭时自然不显示）
        fetcher.$lastOutcome
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcome in
                if let outcome { self?.presentRefreshOutcome(outcome) }
            }
            .store(in: &cancellables)

        // 显示模式变化 → 重绘状态栏标题（轮播 / 总百分比）
        store.$displayMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)

        // 深浅色模式切换时重渲染状态栏：合成图为 template，AppKit 会用 contentTintColor 自动着色、
        // 菜单高亮时自动反色；此处重渲染仅确保布局/内容在外观变化后仍正确。
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            PTMLogger.error("statusItem.button 为 nil")
            return
        }
        // 一次性固定状态项长度：按「图标(~18pt) + 间距(4pt) + 最宽文本(100%)」的实测宽度预留，
        // 之后任何渲染都不再改 length，从源头消除 length 推送触发的重绘死循环（触发源 1）。
        statusItem.length = Self.fixedStatusLength
        // 初始合成图（network 图标 + 占位文字 PTM）
        button.image = compositeStatusImage(iconName: "network", text: "PTM")
        PTMLogger.info("状态栏按钮已配置")
    }

    /// 状态项固定长度：容纳「图标 + 间距 + 最宽文本 100%」并左右各留 6pt 内边距。
    /// 仅在 configureButton 中赋值一次，渲染阶段绝不修改，从源头消除 length 触发的重绘死循环。
    private static let fixedStatusLength: CGFloat = {
        let barFont = NSFont.menuBarFont(ofSize: 0)
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: barFont.pointSize, weight: .regular)
        let maxTextWidth = ("100%" as NSString).size(withAttributes: [.font: digitFont]).width
        let iconSize: CGFloat = 18
        let gap: CGFloat = 2
        let contentWidth = iconSize + gap + maxTextWidth
        let sidePadding: CGFloat = 2
        return ceil(contentWidth) + sidePadding * 2
    }()

    /// 渲染状态栏：把「SF Symbol 图标 + 等宽数字文字」一次性合成进单张 NSImage（template），
    /// 只赋值给 `button.image`。`statusItem.length` 已由 configureButton 固定，此处不再改动，
    /// 从而同时消除两个死循环触发源：
    ///  - 触发源 1（几何推送）：不再运行时改 statusItem.length；
    ///  - 触发源 2（子 layer 重绘）：不再用 textView 子 view 的 layer.contents 脏化按钮。
    /// 合成图设为 template（isTemplate = true），AppKit 用 contentTintColor（labelColor）自动着色，
    /// 并在菜单高亮时自动反色，与原本 button.image 的图标行为一致、最省心。
    private func renderStatusItem(text: String) {
        guard let button = statusItem.button else { return }

        // ---- 确定图标（优先级从高到低）----
        let resolvedIconName: String
        if let flash = outcomeFlashIcon {
            // 刷新结果闪示：只在菜单已关闭时出现，2.5s / 4s 后自动恢复
            resolvedIconName = flash
        } else if isRefreshing {
            // 刷新中优先：菜单被手动关掉时，状态栏图标是唯一可见的进度反馈
            resolvedIconName = "arrow.triangle.2.circlepath"
        } else {
            let anyError = store.subscriptions.contains { $0.lastError != nil }
            if anyError {
                resolvedIconName = "exclamationmark.triangle"
            } else if isDataStale() {
                resolvedIconName = "clock.arrow.2.circlepath"
            } else {
                resolvedIconName = "network"
            }
        }

        // ---- 合成单图（图标 + 文字），只改 button.image ----
        button.image = compositeStatusImage(iconName: resolvedIconName, text: text)
        #if DEBUG
        currentIconName = resolvedIconName
        #endif

        // 记录供深浅色切换 / 数据陈旧检查重渲染
        lastRenderedString = text
    }

    /// 合成图缓存：`updateButtonTitle` 会在每次数据变化 / 轮播时被调用，而状态栏文字的取值范围很小
    /// （百分比 0–100%、"PTM"、"—" 之类），图标只有 4 个。不缓存的话每次都要重新走一遍
    /// 「SF Symbol 取图 + 文字排版 + 离屏合成」，属于纯重复计算。
    ///
    /// 键包含图标名、文字与栏高（栏高决定图像高度与图标尺寸，换屏/换分辨率时会变）。
    /// 用 `NSCache` 而非字典：内存吃紧时由系统自动回收，回收后下次重新合成即可，无正确性风险。
    private static let statusImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64   // 实际最多约 100 个百分比 × 4 图标，但同屏只会用到极少几个
        return cache
    }()

    /// 把「SF Symbol 图标 + 等宽数字文字」合成进单张 NSImage（template）。
    /// 关键点：所有像素在「一张图」内用 AppKit 原生绘制完成（不依赖子 view / layer.contents），
    /// 因此渲染时只需 `button.image = ...`，绝不会脏化按钮的 layer，避免触发 setNeedsDisplay
    /// 进入 `_windowNeedsReplicantUpdate` 死循环（触发源 2）。
    /// 用 `NSImage(size:flipped:drawingHandler:)` 渲染；`isTemplate = true` 由系统按菜单栏分辨率对 alpha 蒙版缩放，保证清晰；
    /// 颜色纯黑绘制，最终 isTemplate = true，AppKit 只取 alpha 蒙版、用 contentTintColor 自动着色、
    /// 菜单高亮时自动反色。图标左、文字右、间距 4pt。
    private func compositeStatusImage(iconName: String, text: String) -> NSImage {
        // 状态项按钮高度即菜单栏厚度；图标略小于栏高并垂直居中
        let barHeight = statusItem.button?.bounds.height ?? 22
        let cacheKey = "\(iconName)|\(text)|\(Int(barHeight.rounded()))" as NSString
        if let cached = Self.statusImageCache.object(forKey: cacheKey) { return cached }

        let barFont = NSFont.menuBarFont(ofSize: 0)
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: barFont.pointSize, weight: .regular)
        let iconSize = max(14, min(barHeight - 4, 20))
        let gap: CGFloat = 4
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: digitFont,
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        let imageWidth = ceil(iconSize + gap + max(textSize.width, 1))
        let imageSize = NSSize(width: imageWidth, height: barHeight)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            // 纯黑绘制即可：最终 isTemplate = true，AppKit 只使用 alpha 作为蒙版，
            // 用 contentTintColor 自动着色并在菜单高亮时反色。
            if let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let iconRect = CGRect(x: 0,
                                      y: (barHeight - iconSize) / 2,
                                      width: iconSize,
                                      height: iconSize)
                symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            let textX = iconSize + gap
            let textY = (barHeight - textSize.height) / 2
            (text as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: textAttrs)
            return true
        }
        image.isTemplate = true
        Self.statusImageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// 状态栏仅显示百分比；文字保持系统默认（无色），仅图标按状态切换（出错→警告三角；陈旧→clock）。
    /// 显示模式：.carousel 轮播各订阅；.total 显示总百分比（已用 / 总额）。
    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }
        let sorted = sortedSubscriptions()
        let anyError = sorted.contains { $0.lastError != nil }
        var displayedPct: Int? = nil

        if store.displayMode == .total {
            let agg = aggregateUsage()
            if agg.total > 0 {
                let pct = Double(agg.used) / Double(agg.total) * 100
                displayedPct = Int(pct.rounded())
                renderStatusItem(text: "\(displayedPct!)%")
                button.toolTip = "总流量占比 \(displayedPct!)%"
            } else {
                renderStatusItem(text: "PTM")
                button.toolTip = nil
            }
        } else if let current = sorted[safe: min(displayIndex, max(0, sorted.count - 1))] {
            // 关键：状态栏唯一的告警指示是左侧三角图标（anyError 分支），标题/百分比区禁止再出现 ⚠ 字符。
            // 拉取失败时 lastTraffic 不会被清空（仅设置 lastError），「上次的数据」仍可用，故优先展示上次百分比。
            if let traffic = current.lastTraffic {
                let pct = traffic.usagePercentage
                displayedPct = Int(pct.rounded())
                renderStatusItem(text: "\(displayedPct!)%")
                if current.lastError != nil {
                    button.toolTip = "\(current.name) · \(String(format: "%.1f%%", pct)) · 上次刷新失败"
                } else {
                    button.toolTip = "\(current.name) · \(String(format: "%.1f%%", pct))"
                }
            } else if current.lastError != nil {
                // 无缓存（首拉即失败）：用 — 占位，错误详情放进 tooltip，而非用 ⚠ 文字重复告警
                renderStatusItem(text: "—")
                button.toolTip = current.lastError
            } else {
                renderStatusItem(text: "PTM")
                button.toolTip = current.name
            }
        } else {
            renderStatusItem(text: "PTM")
            button.toolTip = nil
        }

        updateAccessibilityLabel(hasError: anyError, pct: displayedPct)
    }

    /// 刷新状态栏按钮图标：错误优先于陈旧，陈旧优先于正常。
    /// - 活跃错误 → exclamationmark.triangle
    /// - 无错误但数据陈旧（>120 分钟无成功刷新）→ clock.arrow.2.circlepath
    /// - 否则 → network
    private func refreshButtonAppearance() {
        // 仅更新图标：renderStatusItem 会按「闪示 > 刷新中 > 错误 > 陈旧 > 正常」重新判断
        if let string = lastRenderedString { renderStatusItem(text: string) }
    }

    /// 数据是否陈旧：存在「最后成功刷新时间」且距现在已超过 120 分钟（7200s）。
    /// 从未成功刷新过（lastSuccessfulFetchAt 为 nil）不视为陈旧（无数据可陈旧）。
    private func isDataStale() -> Bool {
        guard let last = store.lastSuccessfulFetchAt else { return false }
        return Date().timeIntervalSince(last) > 7200
    }

    /// 设置状态栏按钮可访问性标签，便于 VoiceOver / 辅助功能朗读。
    /// 注意：AppKit 中 accessibilityLabel 是方法（NSAccessibility 协议），需用 setAccessibilityLabel(_:) 赋值。
    private func updateAccessibilityLabel(hasError: Bool, pct: Int?) {
        guard let button = statusItem.button else { return }
        if hasError {
            button.setAccessibilityLabel("代理流量, 拉取失败")
        } else if let pct {
            button.setAccessibilityLabel("代理流量 \(pct)%, 正常")
        } else {
            button.setAccessibilityLabel("代理流量, 无数据")
        }
    }

    /// 聚合所有订阅的已用 / 总额，用于「总百分比」显示模式
    private func aggregateUsage() -> (used: Int64, total: Int64) {
        var used: Int64 = 0, total: Int64 = 0
        for s in store.subscriptions {
            guard let t = s.lastTraffic else { continue }
            used += t.used
            total += t.total
        }
        return (used, total)
    }

    /// 排序：预警(>90%) → 今天有消耗 → 用量高 → 普通
    private func sortedSubscriptions() -> [Subscription] {
        store.subscriptions.sorted { a, b in
            let aPct = a.lastTraffic?.usagePercentage ?? 0
            let bPct = b.lastTraffic?.usagePercentage ?? 0
            let aAlert = aPct >= 90 || a.lastError != nil
            let bAlert = bPct >= 90 || b.lastError != nil
            if aAlert != bAlert { return aAlert }
            let aActive = isActivelyConsuming(a)
            let bActive = isActivelyConsuming(b)
            if aActive != bActive { return aActive }
            return aPct > bPct
        }
    }

    /// 判断今天是否有流量消耗（最近 used > 昨天快照 used）
    private func isActivelyConsuming(_ sub: Subscription) -> Bool {
        guard let last = sub.lastTraffic else { return false }
        let history = sub.history.sorted { $0.date < $1.date }
        guard history.count >= 2 else { return false }
        let prev = history[history.count - 2]
        return last.used > prev.used
    }

    // MARK: - 轮播

    private func startCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = Timer.scheduledTimer(withTimeInterval: carouselInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceCarousel() }
        }
    }

    private func advanceCarousel() {
        guard store.displayMode == .carousel else { return }   // 「总百分比」模式不轮播
        let sorted = sortedSubscriptions()
        guard sorted.count > 1 else { return }
        displayIndex = (displayIndex + 1) % sorted.count
        updateButtonTitle()
    }

    // MARK: - 数据陈旧检查

    /// 启动「数据陈旧」检查定时器：每 60s 触发一次，重新计算状态栏图标
    ///（>10 分钟无成功刷新则显示 clock）。用 scheduledTimer（common modes）即可在主运行循环空闲时刷新。
    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshButtonAppearance() }
        }
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        menuItemViews.removeAll()
        menuRowViews.removeAll()
        refreshAllItem = nil
        outcomeBannerItem = nil
        outcomeBannerTimer?.invalidate()
        outcomeBannerTimer = nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self   // 菜单代理（menuWillOpen 启动「更新于」live 计时）

        if store.subscriptions.isEmpty {
            let item = NSMenuItem(title: "暂无订阅，请在设置中添加", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // 顶部汇总：用自定义 view 渲染（labelColor 同色；自定义 view 项系统不画选中高亮，hover 不变蓝，与订阅项一致）
            let totalRemaining = store.subscriptions.compactMap { $0.lastTraffic?.remaining }.reduce(0, +)
            let summaryView = SummaryMenuItemView(text: "共 \(store.subscriptions.count) 个订阅 · 总剩余 \(ByteFormatter.readable(totalRemaining))")
            let summary = NSMenuItem()
            summary.view = summaryView
            summary.isEnabled = true   // 无 action 不响应点击
            summary.action = nil
            summary.target = nil
            menu.addItem(summary)
            menu.addItem(.separator())

            for subscription in store.subscriptions {
                let view = SubscriptionMenuItemView(
                    subscription: subscription,
                    onRefresh: { [weak self] in self?.fetcher.refresh(subscription: subscription, manual: true) })
                menuItemViews.append(view)
                let item = NSMenuItem()
                item.view = view
                item.isEnabled = true   // 启用以便刷新按钮可点击
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // 以下三行与订阅行一样全部自绘（MenuRowView）：
        // `item.view != nil` 时 AppKit 整行不画，所以菜单里**没有任何系统绘制的文字**，
        // 颜色/字形/基线由同一套代码产出，结构性一致，不存在"某一行差一档"。
        // 附带好处：view 项不会因点击而收起菜单，「立即刷新」点完菜单留在原地，
        // 可以看着两行同时转圈、结束后就地显示结果。
        // keyEquivalent 仍然挂在 NSMenuItem 上（菜单层匹配，与 view 无关），⌘R / ⌘, / ⌘Q 照常可用。
        refreshAllItem = addRow(to: menu, title: "立即刷新", shortcut: "R", action: #selector(refresh)) {
            [weak self] in self?.refresh()
        }

        // 「设置…」带齿轮图标（与系统菜单一致）
        addRow(to: menu, title: "设置…", shortcut: ",", hasIcon: true, action: #selector(openSettings)) {
            [weak self] in self?.closeMenuThenOpenSettings()
        }

        menu.addItem(.separator())

        addRow(to: menu, title: "退出", shortcut: "Q", action: #selector(quit)) {
            NSApp.terminate(nil)
        }

        statusItem.menu = menu
        updateButtonTitle()

        #if DEBUG
        MenuCalibration.runIfRequested(statusItem: statusItem, menu: menu)
        MenuCalibration.runFlashCheckIfRequested(statusItem: statusItem)
        #endif
    }

    /// 添加一行自绘菜单项：同时挂上 keyEquivalent（菜单层匹配，与 view 无关，⌘ 键照常生效）。
    /// 抽出来是为了让「标题 / 快捷键 / selector / 点击回调」四处不会各自漂移。
    @discardableResult
    private func addRow(to menu: NSMenu,
                        title: String,
                        shortcut: String,
                        hasIcon: Bool = false,
                        action: Selector,
                        onActivate: @escaping () -> Void) -> NSMenuItem {
        let row = MenuRowView(title: title, shortcut: shortcut, hasIcon: hasIcon, onActivate: onActivate)
        menuRowViews.append(row)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut.lowercased())
        item.target = self
        item.view = row
        menu.addItem(item)
        return item
    }

    /// 菜单打开时，把 store 中的最新数据推送到各菜单项视图（就地更新内容，不重排菜单）
    private func pushLatestToMenuItems() {
        for view in menuItemViews {
            if let sub = store.subscriptions.first(where: { $0.id == view.subscriptionId }) {
                view.update(with: sub)
            }
        }
    }

    /// 根据刷新中的 id 集合，驱动各行订阅项的 spinner；
    /// 同时让状态栏图标进入「刷新中」——菜单被手动关掉时，这是唯一可见的进度反馈。
    private func applySpinnerState(_ ids: Set<UUID>) {
        for view in menuItemViews {
            view.setRefreshing(ids.contains(view.subscriptionId))
        }
        let busy = !ids.isEmpty
        guard busy != isRefreshing else { return }
        isRefreshing = busy
        if busy { clearOutcomeFlash() }   // 新一轮刷新开始，上一次的结果闪示立刻让位给进度图标
        updateButtonTitle()
    }

    // MARK: - 刷新结果反馈

    #if DEBUG
    /// 当前实际绘制的状态栏图标（仅供标定断言；也便于排查「图标为什么不换」）
    private var currentIconName: String?

    /// 仅供 MenuCalibration 断言：菜单开合态与「结果闪示」是否真的点亮
    var debugIsMenuOpen: Bool { isMenuOpen }
    var debugOutcomeFlashIcon: String? { outcomeFlashIcon }
    var debugCurrentIconName: String? { currentIconName }
    var debugStore: SubscriptionStore { store }

    /// 仅供 MenuCalibration：验证合成图缓存既命中、又不串号
    func debugCacheCheck() -> String {
        let a = compositeStatusImage(iconName: "network", text: "5%")
        let b = compositeStatusImage(iconName: "network", text: "5%")     // 同键 → 必须复用
        let c = compositeStatusImage(iconName: "network", text: "100%")   // 换文字 → 必须换图
        let d = compositeStatusImage(iconName: "exclamationmark.triangle", text: "5%")  // 换图标 → 必须换图
        return "sameHit=\(a === b) diffText=\(a !== c) diffIcon=\(a !== d) "
             + "w5=\(Int(a.size.width)) w100=\(Int(c.size.width))"
    }
    #endif

    /// 全部刷新结束后按菜单状态选反馈通道：
    ///  - 菜单开着 → 底部临时汇总行（可见、不打断交互）
    ///  - 菜单已关闭 → 状态栏图标闪示（否则用户点完刷新就按 Esc、或定时刷新在后台完成时，结果会被完全丢弃）
    private func presentRefreshOutcome(_ outcome: TrafficFetcher.RefreshOutcome) {
        guard outcome.total > 0 else { return }
        let success = outcome.failures == 0
        let title = success
            ? "✓ 刷新完成"
            : "⚠ \(outcome.failures)/\(outcome.total) 刷新失败"

        if isMenuOpen {
            showOutcomeBanner(title: title)
        } else {
            flashOutcome(success: success)
        }
    }

    /// 状态栏图标短暂切换为刷新结果，然后自动恢复。
    /// 只换图标不换文字：状态项长度是固定的（按 "100%" 预留），往文字里塞 ✓ 会溢出。
    private func flashOutcome(success: Bool) {
        clearOutcomeFlash()
        outcomeFlashIcon = success ? "checkmark.circle" : "exclamationmark.triangle"
        if let string = lastRenderedString { renderStatusItem(text: string) }

        // 失败留更久：这是需要用户注意的信息，成功只是「做完了」的确认
        let timer = Timer(timeInterval: success ? 2.5 : 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.clearOutcomeFlash() }
        }
        outcomeFlashTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clearOutcomeFlash() {
        outcomeFlashTimer?.invalidate()
        outcomeFlashTimer = nil
        guard outcomeFlashIcon != nil else { return }
        outcomeFlashIcon = nil
        if let string = lastRenderedString { renderStatusItem(text: string) }
    }

    private func showOutcomeBanner(title: String) {
        removeOutcomeBanner()
        guard isMenuOpen, let menu = statusItem.menu, let refreshItem = refreshAllItem else { return }

        // 也用自绘行：菜单里已经没有系统绘制的行，混一个原生 item 进去会立刻显出渲染差异
        let banner = NSMenuItem()
        banner.view = MenuRowView(title: title, style: .info)
        banner.isEnabled = false   // 信息行，不可点击
        if let idx = menu.items.firstIndex(of: refreshItem) {
            menu.insertItem(banner, at: idx + 1)   // 紧贴「立即刷新」下方
        } else {
            menu.addItem(banner)
        }
        outcomeBannerItem = banner

        outcomeBannerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.removeOutcomeBanner() }
        }
    }

    private func removeOutcomeBanner() {
        outcomeBannerTimer?.invalidate()
        outcomeBannerTimer = nil
        if let item = outcomeBannerItem {
            statusItem.menu?.removeItem(item)
            outcomeBannerItem = nil
        }
    }

    /// 菜单打开：标记打开态、启动「更新于」live 计时器（.common 模式，菜单跟踪 runloop 下仍触发），并立即刷新一次时间。
    /// 注意：打开菜单不触发网络刷新，仅刷新已缓存数据的相对时间显示。
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        startLiveTimer()
        refreshMenuTimes()
    }

    /// 系统菜单的「当前高亮项」变化（鼠标悬停 / 键盘 ↑↓ 都会触发）。
    /// 自绘行不会被 AppKit 画高亮，所以借这个回调驱动我们自己的高亮，
    /// 顺便让键盘导航重新有视觉反馈。这是自绘行**唯一**的 hover 入口（详见 `MenuRowView.setHovered`）。
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let highlighted = item?.view as? MenuRowView
        for row in menuRowViews {
            row.setHovered(row === highlighted)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        stopLiveTimer()
        removeOutcomeBanner()   // 关闭菜单时清掉临时汇总行
        for row in menuRowViews { row.clearHover() }   // 清残留 hover 高亮
    }

    /// 菜单打开时启动「更新于」live 计时器（.common 模式）
    private func startLiveTimer() {
        stopLiveTimer()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuTimes() }
        }
        liveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// 刷新菜单内所有订阅项的「更新于」相对时间
    private func refreshMenuTimes() {
        for view in menuItemViews { view.updateTimeLabel() }
    }

    @objc private func refresh() {
        fetcher.refresh(manual: true)
    }

    /// 自绘行不会因点击而收起菜单，所以「点了就走」的动作必须自己关菜单再执行。
    /// 先 cancelTracking 再异步执行，避免在菜单跟踪循环内部弹窗导致焦点错乱。
    private func closeMenuThenOpenSettings() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show(store: store)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// 深浅色模式切换时重新渲染状态栏文字（layer.contents 中的 CGImage 颜色不会自动跟随 appearance）
    @objc private func handleAppearanceChange() {
        guard let string = lastRenderedString else { return }
        renderStatusItem(text: string)
    }

    // MARK: - 生命周期

    /// 释放所有定时器，避免悬挂 Timer 引用导致的内存泄漏 / 野回调。
    deinit {
        carouselTimer?.invalidate()
        staleTimer?.invalidate()
        liveTimer?.invalidate()
        outcomeBannerTimer?.invalidate()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 菜单顶部「共 N 个订阅 · 总剩余 X」汇总项的自定义视图：纯文字（labelColor，与订阅项同色），
/// 不实现 hover 高亮 —— 它是信息行、点击无行为，不该给出"可点"的暗示。
///
/// 字号与缩进必须和 `MenuRowView` 的动作行完全一致（13pt 菜单字体、x = `MenuMetrics.titleX`、
/// 同一套 `textTop` / `textHeight`）：两处若各写一套字面量，一旦只改一边，视觉上就会出现
/// 「上下没对齐 / 字号差半档」的问题，而这正是之前踩过的坑。
private final class SummaryMenuItemView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: MenuMetrics.rowHeight))
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.menuFont(ofSize: 0)   // 13pt，与动作行同一字体
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let x = MenuMetrics.titleX
        label.frame = NSRect(x: x,
                             y: MenuMetrics.textTop,
                             width: MenuMetrics.width - x - 12,
                             height: MenuMetrics.textHeight)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}
