import AppKit
import Combine
import SwiftUI

/// 系统标准菜单单行高度。自定义 view 项的行高必须与之相等，否则与「设置…/退出」等系统文本项对不齐。
/// 用「3 项菜单高度 − 2 项菜单高度」的差值隔离出单行高度（消除上下边框），自动适配不同 macOS 版本 / 缩放。
/// 实测当前系统为 24pt（旧版 macOS 多为 22pt）。若测量异常（≤0）回退到 22。
private let standardMenuRowHeight: CGFloat = {
    func measure(_ n: Int) -> CGFloat {
        let m = NSMenu()
        for _ in 0..<n { m.addItem(NSMenuItem(title: " ", action: nil, keyEquivalent: "")) }
        return m.size.height
    }
    let h = measure(3) - measure(2)
    return h > 0 ? h : 22
}()

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
    private var refreshAllItem: NSMenuItem?   // 「立即刷新」项（NSMenuItem 容器，承载自定义 view）
    private var refreshAllView: RefreshMenuItemView?  // 「立即刷新」自定义 view（点击不关菜单 + 手绘系统级高亮 + ⌘R + 转圈）

    // 刷新结果反馈（选项 B：仅底部汇总行，状态栏与「立即刷新」项标题均不变）
    private var outcomeBannerItem: NSMenuItem?       // 菜单底部临时汇总行
    private var outcomeBannerTimer: Timer?           // 汇总行自动移除定时器

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

        // 刷新状态集合变化 → 驱动菜单内 spinner（「立即刷新」项 + 各订阅项）
        fetcher.$refreshingIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.applySpinnerState(ids)
            }
            .store(in: &cancellables)

        // 刷新结果汇总 → 菜单内瞬时反馈（①「立即刷新」文字 + ② 底部临时汇总行）。状态栏零改动。
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
    private func renderStatusItem(text: String, iconName: String? = nil) {
        guard let button = statusItem.button else { return }

        // ---- 确定图标 ----
        let resolvedIconName: String
        if let explicit = iconName {
            resolvedIconName = explicit
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

        // 记录供深浅色切换 / 数据陈旧检查重渲染
        lastRenderedString = text
    }

    /// 把「SF Symbol 图标 + 等宽数字文字」合成进单张 NSImage（template）。
    /// 关键点：所有像素在「一张图」内用 AppKit 原生绘制完成（不依赖子 view / layer.contents），
    /// 因此渲染时只需 `button.image = ...`，绝不会脏化按钮的 layer，避免触发 setNeedsDisplay
    /// 进入 `_windowNeedsReplicantUpdate` 死循环（触发源 2）。
    /// 用 `NSImage(size:flipped:drawingHandler:)` 渲染；`isTemplate = true` 由系统按菜单栏分辨率对 alpha 蒙版缩放，保证清晰；
    /// 颜色纯黑绘制，最终 isTemplate = true，AppKit 只取 alpha 蒙版、用 contentTintColor 自动着色、
    /// 菜单高亮时自动反色。图标左、文字右、间距 4pt。
    private func compositeStatusImage(iconName: String, text: String) -> NSImage {
        let barFont = NSFont.menuBarFont(ofSize: 0)
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: barFont.pointSize, weight: .regular)
        // 状态项按钮高度即菜单栏厚度；图标略小于栏高并垂直居中
        let barHeight = statusItem.button?.bounds.height ?? 22
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
        // 仅更新图标：renderStatusItem 传入 nil iconName 会自动判断状态
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
        refreshAllItem = nil
        refreshAllView = nil
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

        // 「立即刷新」用自定义 view（选项 A）：点击在 view 内部消费事件 → 菜单不关（与订阅行刷新按钮一致）；
        // 手绘与系统完全一致的选中高亮（controlAccentColor 圆角块 + 白字）+ 右侧 ⌘R；刷新中转圈。
        // 同时保留 keyEquivalent=⌘R（键盘 ⌘R 仍触发 refresh），并设 action/target 供键盘路径调用。
        let refreshView = RefreshMenuItemView(title: "立即刷新", shortcut: "⌘R") { [weak self] in
            self?.refresh()
        }
        let refreshItem = NSMenuItem()
        refreshItem.view = refreshView
        refreshItem.isEnabled = true
        refreshItem.keyEquivalent = "r"
        refreshItem.keyEquivalentModifierMask = .command
        refreshItem.action = #selector(refresh)
        refreshItem.target = self
        refreshAllItem = refreshItem
        refreshAllView = refreshView
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateButtonTitle()
    }

    /// 菜单打开时，把 store 中的最新数据推送到各菜单项视图（就地更新内容，不重排菜单）
    private func pushLatestToMenuItems() {
        for view in menuItemViews {
            if let sub = store.subscriptions.first(where: { $0.id == view.subscriptionId }) {
                view.update(with: sub)
            }
        }
    }

    /// 根据刷新中的 id 集合，驱动各行订阅项的 spinner 与「立即刷新」项自身（选项 A：自定义 view，菜单不关）
    private func applySpinnerState(_ ids: Set<UUID>) {
        for view in menuItemViews {
            view.setRefreshing(ids.contains(view.subscriptionId))
        }
        refreshAllView?.setRefreshing(ids.contains(fetcher.allRefreshSentinel))
    }

    // MARK: - 刷新结果反馈（状态栏不动，仅菜单内）

    /// 全部刷新结束后：①「立即刷新」项文字瞬时反馈；② 菜单底部临时汇总行。
    private func presentRefreshOutcome(_ outcome: TrafficFetcher.RefreshOutcome) {
        guard outcome.total > 0 else { return }
        let title = outcome.failures == 0
            ? "✓ 刷新完成"
            : "⚠ \(outcome.failures)/\(outcome.total) 刷新失败"

        // 结果仅通过菜单底部临时汇总行反馈（选项 B：「立即刷新」项标题不变）
        showOutcomeBanner(title: title)
    }

    private func showOutcomeBanner(title: String) {
        removeOutcomeBanner()
        guard isMenuOpen, let menu = statusItem.menu, let refreshItem = refreshAllItem else { return }

        let banner = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        stopLiveTimer()
        removeOutcomeBanner()   // 关闭菜单时清掉临时汇总行
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

/// 菜单「立即刷新」项自定义视图（选项 A）：
/// - 点击在 view 内部消费事件（mouseUp: 自行处理）→ 菜单不关（与订阅行刷新按钮一致；依据 SO#7880646：自定义 view 处理 mouseUp 后事件不再上传菜单项）。
/// - 手绘与系统完全一致的选中高亮：controlAccentColor 圆角块（左右内缩 4 / 上下 1，圆角 5）+ 白字 + 右侧 ⌘R（secondaryLabelColor）。
/// - 刷新中显示「刷新中…」+ 转圈 spinner（菜单打开期间也转，用 perform(inModes:[.common]) 启动）。
private final class RefreshMenuItemView: NSView {
    var onTap: (() -> Void)?

    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private let spinner: NSProgressIndicator
    private var trackingArea: NSTrackingArea?
    private var lastActiveState: Bool? = nil
    private var isHovered = false
    private var isPressed = false

    init(title: String, shortcut: String, onTap: @escaping () -> Void) {
        self.onTap = onTap

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.backgroundColor = .clear

        shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.isBordered = false
        shortcutLabel.drawsBackground = false
        shortcutLabel.backgroundColor = .clear

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: standardMenuRowHeight))
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(spinner)
        titleLabel.frame = NSRect(x: 12, y: 4, width: 210, height: 16)
        shortcutLabel.frame = NSRect(x: 234, y: 4, width: 36, height: 16)
        spinner.frame = NSRect(x: 254, y: 4, width: 16, height: 16)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 选中态判定（鼠标 hover / 按下 / 键盘方向键选中 都算激活）
    private var isActive: Bool {
        isHovered || isPressed || (enclosingMenuItem?.isHighlighted ?? false)
    }

    private func updateTextColors() {
        let active = isActive
        guard lastActiveState != active else { return }
        lastActiveState = active
        titleLabel.textColor = active ? .white : .labelColor
        shortcutLabel.textColor = active ? .white : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        updateTextColors()
        if isActive {
            NSColor.controlAccentColor.setFill()
            let rect = bounds.insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    // MARK: - 鼠标事件（自行消费，菜单不关）
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateTextColors()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateTextColors()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateTextColors()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        updateTextColors()
        needsDisplay = true
        onTap?()
    }

    // MARK: - 刷新中转圈
    func setRefreshing(_ refreshing: Bool) {
        if refreshing {
            titleLabel.stringValue = "刷新中…"
            shortcutLabel.isHidden = true
            spinner.isHidden = false
            spinner.perform(#selector(NSProgressIndicator.startAnimation(_:)),
                           with: nil, afterDelay: 0, inModes: [.common])
        } else {
            titleLabel.stringValue = "立即刷新"
            shortcutLabel.isHidden = false
            spinner.perform(#selector(NSProgressIndicator.stopAnimation(_:)),
                           with: nil, afterDelay: 0, inModes: [.common])
            spinner.isHidden = true
        }
        needsDisplay = true
        lastActiveState = nil
    }
}

/// 菜单顶部「共 N 个订阅 · 总剩余 X」汇总项的自定义视图：纯文字（labelColor，与订阅项同色），
/// 不实现 hover 高亮 —— 自定义 view 项系统不会自动画选中高亮，从而 hover 时与下方订阅项一致、不变蓝。
private final class SummaryMenuItemView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: standardMenuRowHeight))
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 4, width: 256, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}
