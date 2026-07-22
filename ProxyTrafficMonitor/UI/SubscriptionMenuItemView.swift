import AppKit
import Combine
import SwiftUI

/// 菜单内单个订阅的自定义视图：名称 + 百分比 + 进度条 + 用量详情 + 单订阅刷新按钮 + 刷新中转圈
final class SubscriptionMenuItemView: NSView {
    /// 点击刷新按钮时回调（由 StatusBarController 注入）
    var onRefresh: (() -> Void)?
    /// 当前订阅 id（供状态栏控制器在菜单打开期间就地推送最新数据 / 驱动 spinner）
    var subscriptionId: UUID { subscription.id }

    private var subscription: Subscription
    private var traffic: TrafficInfo?
    private var line1 = ""                 // 「已用 x · 剩 y」
    private var extraParts: [String] = []  // 重置日 / 到期 / 上次失败（不含「更新于」）

    private let padding: CGFloat = 12
    private let width: CGFloat = 280
    private let height: CGFloat = 92
    private var contentWidth: CGFloat { width - padding * 2 }

    private var nameLabel: NSTextField!
    private var pctLabel: NSTextField!
    private var track: NSView!
    private var fill: NSView!
    private var detailLabel: NSTextField!
    private var refreshBtn: NSButton!
    private var spinner: NSProgressIndicator!

    init(subscription: Subscription, onRefresh: (() -> Void)? = nil) {
        self.subscription = subscription
        self.traffic = subscription.lastTraffic
        self.onRefresh = onRefresh
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        setupSubviews()
        render()
    }

    private func setupSubviews() {
        nameLabel = NSTextField(labelWithString: subscription.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: padding, y: height - 24, width: contentWidth - 76, height: 16)

        pctLabel = NSTextField(labelWithString: "—")
        pctLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pctLabel.alignment = .right
        pctLabel.textColor = .labelColor
        pctLabel.frame = NSRect(x: width - padding - 56, y: height - 24, width: 40, height: 16)

        track = NSView(frame: NSRect(x: padding, y: height - 42, width: contentWidth, height: 6))
        track.wantsLayer = true
        track.layer?.cornerRadius = 3

        fill = NSView(frame: .zero)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: padding, y: 2, width: contentWidth, height: 44)

        refreshBtn = NSButton(frame: NSRect(x: width - padding - 16, y: height - 22, width: 16, height: 16))
        refreshBtn.bezelStyle = .regularSquare
        refreshBtn.isBordered = false
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新此订阅")
        refreshBtn.image?.isTemplate = true
        refreshBtn.contentTintColor = .secondaryLabelColor
        refreshBtn.target = self
        refreshBtn.action = #selector(didTapRefresh)
        refreshBtn.toolTip = "刷新此订阅"

        spinner = NSProgressIndicator(frame: NSRect(x: width - padding - 16, y: height - 22, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        addSubview(nameLabel)
        addSubview(pctLabel)
        addSubview(track)
        addSubview(detailLabel)
        addSubview(refreshBtn)
        addSubview(spinner)
    }

    /// 根据当前 subscription / traffic 重算所有文案与进度条
    private func render() {
        nameLabel.stringValue = subscription.name
        let pct = traffic?.usagePercentage ?? 0

        guard let traffic = traffic else {
            pctLabel.stringValue = subscription.lastError != nil ? "⚠" : "—"
            track.layer?.backgroundColor = NSColor.separatorColor.cgColor
            fill.frame = .zero
            detailLabel.stringValue = subscription.lastError != nil
                ? "拉取失败：\(subscription.lastError!)"
                : "暂无数据，点击「立即刷新」"
            return
        }

        pctLabel.stringValue = String(format: "%.1f%%", pct)
        fill.frame = NSRect(x: 0, y: 0, width: max(2, contentWidth * CGFloat(pct / 100)), height: 6)
        // 仅 ≥90% 进度条染红；其余中性灰（文字始终无色）
        let barColor: NSColor = (pct >= 90) ? .systemRed : .tertiaryLabelColor
        fill.layer?.backgroundColor = barColor.cgColor
        track.layer?.backgroundColor = barColor.withAlphaComponent(0.3).cgColor

        line1 = "已用 \(ByteFormatter.usageRatio(used: traffic.used, total: traffic.total)) · 剩 \(ByteFormatter.readable(traffic.remaining))"
        extraParts = []
        if let days = subscription.daysUntilReset() {
            extraParts.append("\(days)天后重置")
        }
        if let expireDate = traffic.expireDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd"
            extraParts.append("到期 \(fmt.string(from: expireDate))")
        }
        if subscription.lastError != nil {
            extraParts.append("⚠ 上次刷新失败")
        }
        rebuildDetail()
    }

    @objc private func didTapRefresh() {
        onRefresh?()
    }

    /// 菜单打开期间由状态栏控制器推送最新订阅数据：重算并重绘（display() 确保 tracking 模式下也立即上屏）
    func update(with sub: Subscription) {
        self.subscription = sub
        self.traffic = sub.lastTraffic
        render()
        self.display()
    }

    /// 刷新状态变化：显示/隐藏 spinner。用 perform(inModes:[common]) 启动动画，
    /// 这样在菜单打开（NSEventTrackingRunLoopMode，属于 common modes）期间 spinner 也能真正转动。
    func setRefreshing(_ on: Bool) {
        if on {
            refreshBtn.isHidden = true
            spinner.isHidden = false
            spinner.perform(#selector(NSProgressIndicator.startAnimation(_:)),
                           with: nil, afterDelay: 0,
                           inModes: [.common])
        } else {
            spinner.perform(#selector(NSProgressIndicator.stopAnimation(_:)),
                           with: nil, afterDelay: 0,
                           inModes: [.common])
            spinner.isHidden = true
            refreshBtn.isHidden = false
        }
    }

    /// 仅刷新「更新于」相对时间（菜单打开时 live 计时器调用，避免重排整个菜单）
    func updateTimeLabel() {
        guard traffic != nil else { return }   // 无数据的占位文案已在 render 写定，不覆盖
        rebuildDetail()
        self.display()
    }

    /// 重组详情文案：line1 + extraParts + 实时计算的「更新于」
    private func rebuildDetail() {
        guard traffic != nil else { return }
        var parts = extraParts
        if let refreshed = formatRefreshTime(traffic!.fetchedAt) {
            parts.append("更新于\(refreshed)")
        }
        detailLabel.stringValue = parts.isEmpty ? line1 : "\(line1)\n\(parts.joined(separator: " · "))"
    }

    /// 将拉取时间格式化为相对描述（刚刚 / X分钟前 / X小时前 / MM-dd HH:mm）
    private func formatRefreshTime(_ date: Date) -> String? {
        let diff = Date().timeIntervalSince(date)
        guard diff >= 0 else { return nil }
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    required init?(coder: NSCoder) { fatalError() }
}

#if DEBUG
/// 用 SwiftUI 包装 NSView，使其可在 Xcode Canvas 预览
struct SubscriptionMenuItemPreview: NSViewRepresentable {
    let subscription: Subscription
    func makeNSView(context: Context) -> SubscriptionMenuItemView {
        SubscriptionMenuItemView(subscription: subscription)
    }
    func updateNSView(_ nsView: SubscriptionMenuItemView, context: Context) {}
}

/// 构造预览用的订阅数据（#Preview body 不能含 var 赋值 + return，抽到 helper）
private func previewSubscription(name: String, resetDay: Int,
                                 upload: Int64, download: Int64, total: Int64, expire: Int64,
                                 lastError: String? = nil) -> Subscription {
    var sub = Subscription(name: name, resetDay: resetDay)
    sub.lastTraffic = TrafficInfo(upload: upload, download: download, total: total, expire: expire, fetchedAt: Date())
    sub.lastError = lastError
    return sub
}

#Preview("菜单项 · 92% 红色预警") {
    SubscriptionMenuItemPreview(subscription: previewSubscription(
        name: "订阅2 · cocoduck.cc", resetDay: 3,
        upload: 2_768_312_077, download: 46_639_030_977, total: 53_687_091_200, expire: 1_806_759_842))
    .frame(width: 280, height: 92)
    .padding(8)
}

#Preview("菜单项 · 24.8% 正常") {
    SubscriptionMenuItemPreview(subscription: previewSubscription(
        name: "订阅1 · fcapp.run", resetDay: 25,
        upload: 1_549_406_489, download: 27_259_548_951, total: 115_964_116_992, expire: 1_792_858_862))
    .frame(width: 280, height: 92)
    .padding(8)
}

#Preview("菜单项 · 拉取失败") {
    SubscriptionMenuItemPreview(subscription: previewSubscription(
        name: "订阅X · 失效链接", resetDay: 1,
        upload: 0, download: 0, total: 1, expire: 0,
        lastError: "网络错误: 似乎已断开与互联网的连接"))
    .frame(width: 280, height: 92)
    .padding(8)
}
#endif
