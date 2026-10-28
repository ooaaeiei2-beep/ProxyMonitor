import AppKit
import Combine

/// 订阅管理设置窗口（纯 AppKit 实现）
///
/// 历史沿革：本文件此前是 SwiftUI 视图（`SettingsView` + `NSHostingView` 桥接）。
/// 2026-10-27 改为纯 AppKit，原因是构建链而非审美：
/// macOS 27 SDK 已把 `@State` / `@Binding` / `@ObservedObject` 改为宏
/// （`#externalMacro(module: "SwiftUIMacros", ...)`），而宏实现插件 `libSwiftUIMacros.dylib`
/// 仅随 Xcode 分发；本机只有 Command Line Tools，无法编译任何 SwiftUI 视图。
/// 项目其余部分本就是 AppKit，改完后整个 App 可用 `swiftc` 直接构建（见 scripts/build-clt.sh），
/// 同时不再链接 SwiftUI.framework。
///
/// 行为对齐原 SwiftUI 版本：同样的字段、同样的显示模式选择、同样的
/// 「编辑/取消」两态、同样的 Keychain 失败弹窗；删除订阅仍是即时生效（无二次确认）。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - 单例

    private static var instance: SettingsWindowController?

    static func show(store: SubscriptionStore) {
        PTMLogger.info("打开设置窗口")
        // 切到 regular：accessory app 的窗口里 NSTextField 才能正常获得键盘焦点与粘贴
        NSApp.setActivationPolicy(.regular)

        if instance == nil {
            PTMLogger.info("首次创建设置窗口")
            instance = SettingsWindowController(store: store)
        }
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        instance?.focusInputField()
        PTMLogger.info("设置窗口已显示")
    }

    // MARK: - 依赖

    private let store: SubscriptionStore
    private let launchManager = LaunchAtLoginManager.shared
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - 控件

    private let titleLabel = NSTextField(labelWithString: "添加订阅")
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let resetDayField = NSTextField()
    private let cancelButton = NSButton()
    private let commitButton = NSButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let displayModeLabel = NSTextField(labelWithString: "状态栏显示")
    private let displayModeControl = NSSegmentedControl(
        labels: ["占比最高", "轮播各订阅", "总百分比"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let listTitleLabel = NSTextField(labelWithString: "已添加订阅（0）")
    private let emptyLabel = NSTextField(labelWithString: "尚未添加订阅")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    #if DEBUG
    private let mockCheckbox = NSButton(checkboxWithTitle: "Mock 模式（调试）", target: nil, action: nil)
    #endif

    // MARK: - 编辑态

    private var editingId: UUID?
    private var newName = ""
    private var newURL = ""
    private var newResetDay = ""

    // MARK: - 生命周期

    private init(store: SubscriptionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "ProxyMonitor 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 480)
        window.delegate = self

        buildUI()
        bindStore()
        reloadAll()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController 只支持代码创建")
    }

    // MARK: - 界面搭建

    private func buildUI() {
        guard let window else { return }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 560))
        window.contentView = root

        // 标题
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        // 输入区
        for field in [nameField, urlField, resetDayField] {
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        nameField.placeholderString = "名称（如 机场A）"
        urlField.placeholderString = "订阅链接"
        resetDayField.placeholderString = "重置日（1-31，可选）"
        resetDayField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditAction)

        commitButton.title = "添加"
        commitButton.bezelStyle = .rounded
        commitButton.target = self
        commitButton.action = #selector(commitAction)
        commitButton.keyEquivalent = "\r"
        commitButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [resetDayField, spacer, cancelButton, commitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let formStack = NSStackView(views: [nameField, urlField, buttonRow])
        formStack.orientation = .vertical
        formStack.spacing = 8
        formStack.alignment = .leading

        // 开机启动
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunchAtLogin)

        // 状态栏显示模式
        displayModeLabel.textColor = .labelColor
        displayModeControl.target = self
        displayModeControl.action = #selector(changeDisplayMode)
        displayModeControl.segmentStyle = .rounded
        let displayModeRow = NSStackView(views: [displayModeLabel, displayModeControl])
        displayModeRow.orientation = .horizontal
        displayModeRow.spacing = 12
        displayModeRow.alignment = .centerY

        // 订阅列表
        listTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        configureTable()

        // 主纵向栈
        var rows: [NSView] = [
            titleLabel, formStack, separator(), launchCheckbox,
            separator(), displayModeRow,
        ]
        #if DEBUG
        mockCheckbox.target = self
        mockCheckbox.action = #selector(toggleMockMode)
        mockCheckbox.toolTip = "开启后使用内置假数据并模拟刷新拉取，便于观察状态栏响应；关闭即恢复真实数据"
        rows.append(separator())
        rows.append(mockCheckbox)
        #endif
        rows.append(contentsOf: [separator(), listTitleLabel, emptyLabel, scrollView])

        let mainStack = NSStackView(views: rows)
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        // 纵向栈是 leading 对齐，需要显式把每行拉满宽度
        for view in rows {
            view.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }
        for view in [nameField, urlField, buttonRow] {
            view.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }
        // 列表吃掉剩余高度
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subscription"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 62
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - 数据绑定

    private func bindStore() {
        // objectWillChange 在变更「之前」触发，投递到主 runloop 后再刷新，才能读到新值
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadAll() }
            .store(in: &cancellables)

        launchManager.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.launchCheckbox.state = enabled ? .on : .off
            }
            .store(in: &cancellables)

        store.$keychainSaveError
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] message in self?.presentKeychainAlert(message) }
            .store(in: &cancellables)
    }

    /// 全量刷新界面（文本输入框的内容不在此刷新，避免打断正在输入的用户）
    private func reloadAll() {
        titleLabel.stringValue = editingId == nil ? "添加订阅" : "编辑订阅"
        commitButton.title = editingId == nil ? "添加" : "保存"
        cancelButton.isHidden = editingId == nil
        updateCommitButton()

        listTitleLabel.stringValue = "已添加订阅（\(store.subscriptions.count)）"
        let isEmpty = store.subscriptions.isEmpty
        emptyLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        tableView.reloadData()

        if let index = DisplayMode.allCases.firstIndex(of: store.displayMode) {
            displayModeControl.selectedSegment = index
        }
        launchCheckbox.state = launchManager.isEnabled ? .on : .off
        #if DEBUG
        mockCheckbox.state = store.mockModeEnabled ? .on : .off
        #endif
    }

    private func updateCommitButton() {
        let nameOK = !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlOK = !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commitButton.isEnabled = nameOK && urlOK
    }

    private func focusInputField() {
        guard let window else { return }
        window.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    // MARK: - 动作

    @objc private func commitAction() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return }
        let day = parseResetDay(newResetDay)

        if let editingId, var existing = store.subscriptions.first(where: { $0.id == editingId }) {
            existing.name = name
            existing.url = url
            existing.resetDay = day
            Task { await store.update(existing) }
            cancelEdit()
        } else {
            let subscription = Subscription(name: name, url: url, resetDay: day)
            Task { await store.add(subscription) }
            clearInputs()
        }
    }

    @objc private func cancelEditAction() {
        cancelEdit()
    }

    @objc private func toggleLaunchAtLogin() {
        if !launchManager.toggle() {
            PTMLogger.error("开机启动切换失败")
        }
        // 无论成败都以真实状态回写勾选态（失败时自动回弹）
        launchCheckbox.state = launchManager.isEnabled ? .on : .off
    }

    @objc private func changeDisplayMode() {
        let index = displayModeControl.selectedSegment
        guard index >= 0, index < DisplayMode.allCases.count else { return }
        store.displayMode = DisplayMode.allCases[index]
    }

    #if DEBUG
    @objc private func toggleMockMode() {
        let on = mockCheckbox.state == .on
        Task { await store.setMockMode(on) }
    }
    #endif

    private func startEdit(_ subscription: Subscription) {
        editingId = subscription.id
        newName = subscription.name
        newURL = subscription.url
        newResetDay = subscription.resetDay.map(String.init) ?? ""
        nameField.stringValue = newName
        urlField.stringValue = newURL
        resetDayField.stringValue = newResetDay
        reloadAll()
        focusInputField()
    }

    private func cancelEdit() {
        editingId = nil
        clearInputs()
        reloadAll()
    }

    private func clearInputs() {
        newName = ""
        newURL = ""
        newResetDay = ""
        nameField.stringValue = ""
        urlField.stringValue = ""
        resetDayField.stringValue = ""
        updateCommitButton()
    }

    /// 重置日只接受 1-31，其余视为未设置（原实现直接 `Int(...)`，会存进 0 或 99 这类无效值）
    private func parseResetDay(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...31).contains(value) else {
            return nil
        }
        return value
    }

    // MARK: - 弹窗

    private func presentKeychainAlert(_ message: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "订阅链接未保存成功"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "我知道了")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.store.keychainSaveError = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 关闭设置后切回 accessory（状态栏 app 模式，不占 Dock）
        NSApp.setActivationPolicy(.accessory)
        PTMLogger.info("设置窗口关闭，切回 accessory")
    }
}

// MARK: - 文本输入

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:    newName = field.stringValue
        case urlField:     newURL = field.stringValue
        case resetDayField: newResetDay = field.stringValue
        default: return
        }
        updateCommitButton()
    }
}

// MARK: - 列表

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.subscriptions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < store.subscriptions.count else { return nil }
        let subscription = store.subscriptions[row]
        let identifier = NSUserInterfaceItemIdentifier("SubscriptionCell")

        let cell: SubscriptionCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SubscriptionCellView {
            cell = reused
        } else {
            cell = SubscriptionCellView()
            cell.identifier = identifier
        }

        cell.configure(with: subscription)
        cell.onEdit = { [weak self] in self?.startEdit(subscription) }
        cell.onDelete = { [weak self] in
            Task { await self?.store.remove(id: subscription.id) }
        }
        cell.onAdoptResetDay = { [weak self] in
            self?.store.adoptInferredResetDay(id: subscription.id)
        }
        return cell
    }
}

// MARK: - 列表行

/// 单个订阅行：名称 / 百分比 / 用量 / 重置日 + 编辑、删除按钮。
private final class SubscriptionCellView: NSTableCellView {

    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAdoptResetDay: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let daysLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    private let adoptButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SubscriptionCellView 只支持代码创建")
    }

    private func buildUI() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        percentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        resetLabel.font = .systemFont(ofSize: 11)
        daysLabel.font = .systemFont(ofSize: 11)
        daysLabel.textColor = .secondaryLabelColor

        configureSymbolButton(editButton, symbol: "pencil", tooltip: "编辑此订阅",
                              action: #selector(editTapped))
        configureSymbolButton(deleteButton, symbol: "trash", tooltip: "删除此订阅",
                              action: #selector(deleteTapped))
        adoptButton.title = "采用"
        adoptButton.bezelStyle = .inline
        adoptButton.controlSize = .small
        adoptButton.font = .systemFont(ofSize: 11)
        adoptButton.target = self
        adoptButton.action = #selector(adoptTapped)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [nameLabel, spacer, percentLabel, editButton, deleteButton])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .centerY

        let resetRow = NSStackView(views: [resetLabel, adoptButton, daysLabel])
        resetRow.orientation = .horizontal
        resetRow.spacing = 6
        resetRow.alignment = .centerY

        let stack = NSStackView(views: [topRow, detailLabel, resetRow])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String,
                                       tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setButtonType(.momentaryChange)
    }

    func configure(with subscription: Subscription) {
        nameLabel.stringValue = subscription.name

        if let traffic = subscription.lastTraffic {
            percentLabel.stringValue = String(format: "%.1f%%", traffic.usagePercentage)
            percentLabel.textColor = Self.color(for: traffic.usagePercentage)
            detailLabel.stringValue = "\(ByteFormatter.usageRatio(used: traffic.used, total: traffic.total))"
                + " · 剩余 \(ByteFormatter.readable(traffic.remaining))"
            detailLabel.isHidden = false
        } else {
            percentLabel.stringValue = ""
            detailLabel.isHidden = true
        }

        if let day = subscription.resetDay {
            resetLabel.stringValue = "重置日 \(day) 号"
            resetLabel.textColor = .secondaryLabelColor
            adoptButton.isHidden = true
        } else if let inferred = subscription.inferredResetDay {
            resetLabel.stringValue = "推断重置日 \(inferred) 号"
            resetLabel.textColor = .systemOrange
            adoptButton.isHidden = false
        } else {
            resetLabel.stringValue = "未设置重置日"
            resetLabel.textColor = .secondaryLabelColor
            adoptButton.isHidden = true
        }

        if let days = subscription.daysUntilReset() {
            daysLabel.stringValue = "· \(days)天后重置"
        } else {
            daysLabel.stringValue = ""
        }
    }

    private static func color(for percentage: Double) -> NSColor {
        if percentage >= 90 { return .systemRed }
        if percentage >= 70 { return .systemOrange }
        return .systemGreen
    }

    @objc private func editTapped() { onEdit?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func adoptTapped() { onAdoptResetDay?() }
}
