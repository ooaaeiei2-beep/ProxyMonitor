import AppKit

/// 菜单行的统一度量。全部取自系统原生菜单项的实测值
/// （`PTM_CALIBRATE_MENU=1` 的视图树 dump，菜单宽 254 时：
///  标题 `_NSMenuItemTextField(14,4,191,16)`、字符字段 `(222,4,19,16)`、⌘ 字段 `(209,4,21,16)`、
///  「设置…」的齿轮 `_NSMenuItemImageView(15,5,14,14)`、行高 24）。
/// 这里换算成「距右边缘」的常量，与菜单宽度解耦。
enum MenuMetrics {
    /// 菜单内容宽度。所有自定义行同宽，菜单宽度由最宽的那一行决定。
    static let width: CGFloat = 280
    /// 单行高度。用「3 项菜单高度 − 2 项菜单高度」的差值隔离出单行高度（消除上下边框），
    /// 自动适配不同 macOS 版本 / 缩放；实测当前系统为 24pt（旧版 macOS 多为 22pt）。
    /// 异常（≤0）时回退 22。
    static let rowHeight: CGFloat = {
        func measure(_ n: Int) -> CGFloat {
            let m = NSMenu()
            for _ in 0..<n { m.addItem(NSMenuItem(title: " ", action: nil, keyEquivalent: "")) }
            return m.size.height
        }
        let h = measure(3) - measure(2)
        return h > 0 ? h : 22
    }()

    /// hover 高亮条的左右内缩（系统实测 5）与圆角
    static let highlightInset: CGFloat = 5
    static let highlightRadius: CGFloat = 6

    /// 标题：x=14（有前置图标时 34），垂直 y=4、高 16
    static let titleX: CGFloat = 14
    static let titleXWithIcon: CGFloat = 34
    static let textTop: CGFloat = 4
    static let textHeight: CGFloat = 16
    /// 标题右侧给快捷键预留的宽度（254 宽菜单里标题宽 191 = 254 − 14 − 49）
    static let shortcutReserve: CGFloat = 49

    /// ⌘ 字段：宽 21、右边缘距菜单右边 24
    static let commandWidth: CGFloat = 21
    static let commandRight: CGFloat = 24
    /// 字符字段：宽 19、右边缘距菜单右边 13
    static let charWidth: CGFloat = 19
    static let charRight: CGFloat = 13

    /// 前置图标（「设置…」的齿轮）：x=15、14×14、距顶 5
    static let iconX: CGFloat = 15
    static let iconTop: CGFloat = 5
    static let iconSize: CGFloat = 14
}

/// 菜单里的一行，全自绘：标题 + 可选快捷键 + hover 高亮 + 点击回调。
///
/// 为什么不用原生 `NSMenuItem`：
///   - 只要 `item.view != nil`，AppKit 就**整行不画**（标题、⌘、hover 高亮全部消失，由 view 承担）；
///   - 而原生项又无法阻止「点完菜单立刻收起」。
/// 二者在 AppKit 里互斥。所以整个菜单统一用自绘行：一致性由「同一套绘制代码」结构性保证，
/// 而不是逐像素调参去凑系统渲染——那条路已证明走不通（自绘 label 拿不到菜单材质的 vibrancy 增益）。
final class MenuRowView: NSView {
    enum Style {
        /// 可点击行：hover 高亮，文字 labelColor
        case action
        /// 纯信息行（如「✓ 刷新完成」）：不可点击、无高亮、文字更淡
        case info
    }

    /// 点击回调（`.action` 行必填）
    var onActivate: (() -> Void)?

    private let style: Style
    private let titleField = NSTextField(labelWithString: "")
    private let commandField = NSTextField(labelWithString: "")
    private let charField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }

    /// 快捷键的「等效灰」。
    ///
    /// 系统在菜单里把「⌘ + 字符」画成约 45% 黑（离屏快照实测：墨迹 138 / 底色 251），
    /// 但 `NSTextField` 的 label 绘制路径会把**带 alpha 的颜色合成两次**（实测精确符合 1−(1−a)²：
    /// a=0.30→0.514、0.45→0.697、0.55→0.797）。所以要得到 45% 的最终呈现，
    /// alpha 必须取 1−√(1−0.45) ≈ 0.26，而不是直接用 0.45。
    private static let shortcutColor: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.26)
    }

    /// - Parameters:
    ///   - title: 标题文字
    ///   - shortcut: 快捷键字符（"R" / "," / "Q"），自动前置 ⌘；传 nil 表示无快捷键
    ///   - hasIcon: 是否在标题左侧画前置图标（「设置…」的齿轮，与系统一致）
    ///   - style: `.action` 可点击 / `.info` 纯信息
    ///   - onActivate: 点击回调
    init(title: String,
         shortcut: String? = nil,
         hasIcon: Bool = false,
         style: Style = .action,
         onActivate: (() -> Void)? = nil) {
        self.style = style
        self.onActivate = onActivate
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: MenuMetrics.rowHeight))
        build(title: title, shortcut: shortcut, hasIcon: hasIcon)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 构建

    private func build(title: String, shortcut: String?, hasIcon: Bool) {
        let font = NSFont.menuFont(ofSize: 0)   // 13pt，与系统菜单项一致

        let titleX = hasIcon ? MenuMetrics.titleXWithIcon : MenuMetrics.titleX
        titleField.font = font
        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: titleX,
                                  y: MenuMetrics.textTop,
                                  width: MenuMetrics.width - titleX - MenuMetrics.shortcutReserve,
                                  height: MenuMetrics.textHeight)
        addSubview(titleField)

        if hasIcon {
            iconView.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            iconView.image?.isTemplate = true
            iconView.frame = NSRect(x: MenuMetrics.iconX,
                                    y: MenuMetrics.iconTop,
                                    width: MenuMetrics.iconSize,
                                    height: MenuMetrics.iconSize)
            addSubview(iconView)
        }

        if let shortcut {
            // 系统把「⌘ + 字符」拆成两个右对齐字段：⌘ 固定在距右 24、字符右端固定距右 13，
            // 于是 "⌘R" 的间隙比 "⌘Q" 宽——照搬这个布局，字形才会和系统一模一样。
            commandField.font = font
            commandField.alignment = .right
            commandField.stringValue = "⌘"
            commandField.frame = NSRect(x: MenuMetrics.width - MenuMetrics.commandRight - MenuMetrics.commandWidth,
                                        y: MenuMetrics.textTop,
                                        width: MenuMetrics.commandWidth,
                                        height: MenuMetrics.textHeight)
            addSubview(commandField)

            charField.font = font
            charField.alignment = .right
            charField.stringValue = shortcut
            charField.frame = NSRect(x: MenuMetrics.width - MenuMetrics.charRight - MenuMetrics.charWidth,
                                     y: MenuMetrics.textTop,
                                     width: MenuMetrics.charWidth,
                                     height: MenuMetrics.textHeight)
            addSubview(charField)
        }

        applyColors()

        // 行本身就是 accessibility element（role = menuItem），内部子视图不再单独暴露，
        // 否则 VoiceOver 会把同一行读两遍（行标题 + 标题字段）。
        for child in subviews { child.setAccessibilityElement(false) }
    }

    private func applyColors() {
        let highlighted = isHovered && style == .action
        switch style {
        case .action:
            let title: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            let shortcut: NSColor = highlighted ? .selectedMenuItemTextColor : Self.shortcutColor
            titleField.textColor = title
            iconView.contentTintColor = title
            commandField.textColor = shortcut
            charField.textColor = shortcut
        case .info:
            // 与系统「禁用项」同档：实测离屏墨迹 138 / 底 251，和快捷键那档一致。
            // 不要用 .tertiaryLabelColor —— 它在菜单材质下实际解析成 0.5 alpha，画出来比系统深一档（63）。
            titleField.textColor = Self.shortcutColor
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, style == .action else { return }
        let rect = NSRect(x: MenuMetrics.highlightInset,
                          y: 0,
                          width: bounds.width - MenuMetrics.highlightInset * 2,
                          height: bounds.height)
        // 系统的高亮不是纯色，而是「强调色 + 一点面板材质透出」。
        // 实测同一离屏管线：系统高亮 (61,102,106)、面板底 (251,251,251)、强调色 (28,82,86)，
        // 反解出 alpha ≈ 0.87 —— 直接不透明填色会比系统深一档。
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.87).setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: MenuMetrics.highlightRadius,
                     yRadius: MenuMetrics.highlightRadius).fill()
    }

    // MARK: - 交互

    /// 吞掉 mouseDown：不能让父级菜单把这次按下当成"选中某项"而收起菜单。
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard style == .action else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }   // 按下后拖出行外 = 取消
        onActivate?()
    }

    /// 菜单关闭时清掉残留高亮（下一次打开不会带着上一次的 hover 状态）
    func clearHover() {
        isHovered = false
    }

    /// 由菜单代理（`menu(_:willHighlight:)`）驱动 hover —— 这是**唯一**的高亮入口。
    ///
    /// 曾经并行维护过一条 `NSTrackingArea`（mouseEntered/Exited）路径，实测两条都能独立生效
    /// （关掉任一条，光标移到行上时 `debugIsHovered` 仍为 true），属纯冗余：
    ///  - `willHighlight` 由菜单跟踪循环驱动，鼠标悬停与键盘 ↑↓ 导航共用，语义更完整；
    ///  - `NSTrackingArea` 只认鼠标，且菜单弹出时光标若已在行上、之后没有新的 mouseEntered，
    ///    就会出现「行看着被选中、实际没高亮」的不一致。
    /// 故只保留这一条。
    func setHovered(_ on: Bool) {
        guard style == .action else { return }
        isHovered = on
    }

    #if DEBUG
    /// 仅供 MenuCalibration 断言 hover 是否真的被点亮
    var debugIsHovered: Bool { isHovered }
    #endif

    // MARK: - 辅助功能

    /// 自绘行没有 NSMenuItem 的 title 语义，必须手动补，否则 VoiceOver 读不出来
    override func isAccessibilityElement() -> Bool { style == .action }

    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }

    override func accessibilityLabel() -> String? { titleField.stringValue }
}
