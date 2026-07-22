import AppKit
import SwiftUI

/// SwiftUI 订阅管理界面
struct SettingsView: View {
    @ObservedObject var store: SubscriptionStore
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newResetDay = ""
    @State private var editingId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingId == nil ? "添加订阅" : "编辑订阅").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                AppKitTextField(text: $newName, placeholder: "名称（如 机场A）")
                AppKitTextField(text: $newURL, placeholder: "订阅链接")
                HStack {
                    AppKitTextField(text: $newResetDay, placeholder: "重置日（1-31，可选）")
                        .frame(width: 200)
                    Spacer()
                    if editingId != nil {
                        Button("取消") { cancelEdit() }
                    }
                    Button(editingId == nil ? "添加" : "保存") { commit() }
                        .disabled(newName.isEmpty || newURL.isEmpty)
                }
            }

            Divider()

            // 开机启动（观察 launchManager，toggle 后 @Published 触发重渲染，勾选态与真实状态一致）
            Toggle("登录时启动", isOn: Binding(
                get: { launchManager.isEnabled },
                set: { _ in
                    if !launchManager.toggle() {
                        PTMLogger.error("开机启动切换失败")
                    }
                }
            ))

            Divider()

            // 状态栏显示模式：轮播各订阅百分比 / 总百分比
            Picker("状态栏显示", selection: $store.displayMode) {
                Text("轮播各订阅").tag(DisplayMode.carousel)
                Text("总百分比").tag(DisplayMode.total)
            }
            .pickerStyle(.segmented)

            Divider()

            Text("已添加订阅（\(store.subscriptions.count)）").font(.headline)
            if store.subscriptions.isEmpty {
                Text("尚未添加订阅").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(store.subscriptions) { sub in
                        HStack {
                            SubscriptionRow(subscription: sub, store: store)
                            Button(action: { startEdit(sub) }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("编辑此订阅")
                            Button(action: { store.remove(id: sub.id) }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除此订阅")
                        }
                    }
                    .onDelete { store.remove(atOffsets: $0) }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 560)
    }

    private func commit() {
        let day = Int(newResetDay.trimmingCharacters(in: .whitespaces))
        if let editingId {
            if var sub = store.subscriptions.first(where: { $0.id == editingId }) {
                sub.name = newName
                sub.url = newURL
                sub.resetDay = day
                store.update(sub)
            }
            cancelEdit()
        } else {
            store.add(Subscription(name: newName, url: newURL, resetDay: day))
            newName = ""
            newURL = ""
            newResetDay = ""
        }
    }

    private func startEdit(_ sub: Subscription) {
        editingId = sub.id
        newName = sub.name
        newURL = sub.url
        newResetDay = sub.resetDay.map { String($0) } ?? ""
    }

    private func cancelEdit() {
        editingId = nil
        newName = ""
        newURL = ""
        newResetDay = ""
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription
    let store: SubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(subscription.name).font(.system(size: 13, weight: .medium))
                Spacer()
                if let t = subscription.lastTraffic {
                    Text(String(format: "%.1f%%", t.usagePercentage))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color(pct: t.usagePercentage))
                }
            }
            if let t = subscription.lastTraffic {
                Text("\(ByteFormatter.usageRatio(used: t.used, total: t.total)) · 剩余 \(ByteFormatter.readable(t.remaining))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let day = subscription.resetDay {
                    Text("重置日 \(day) 号")
                } else if let day = subscription.inferredResetDay {
                    Text("推断重置日 \(day) 号").foregroundStyle(.orange)
                    Button("采用") { store.adoptInferredResetDay(id: subscription.id) }
                        .font(.system(size: 11))
                } else {
                    Text("未设置重置日").foregroundStyle(.secondary)
                }
                if let days = subscription.daysUntilReset() {
                    Text("· \(days)天后重置").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func color(pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?

    static func show(store: SubscriptionStore) {
        PTMLogger.info("打开设置窗口")
        // 切到 regular：accessory app 的窗口 TextField 无法接收键盘输入/粘贴
        NSApp.setActivationPolicy(.regular)

        if instance == nil {
            PTMLogger.info("首次创建设置窗口")
            let view = SettingsView(store: store)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ProxyTrafficMonitor 设置"
            window.contentView = hosting
            window.center()
            window.isReleasedWhenClosed = false
            let controller = SettingsWindowController(window: window)
            window.delegate = controller
            instance = controller
        }
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PTMLogger.info("设置窗口已显示")
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭设置后切回 accessory（状态栏 app 模式，不占 Dock）
        NSApp.setActivationPolicy(.accessory)
        PTMLogger.info("设置窗口关闭，切回 accessory")
    }
}

/// 用 NSTextField (AppKit) 包装：解决状态栏 app 下 SwiftUI TextField 不能粘贴的问题
struct AppKitTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.bezelStyle = .roundedBezel
        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if nsView.placeholderString != placeholder { nsView.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: AppKitTextField
        init(_ parent: AppKitTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
    }
}

#if DEBUG
/// 构造预览用的 store（#Preview body 不能含多个语句 + return，抽到 helper）
private func previewStore() -> SubscriptionStore {
    let store = SubscriptionStore(defaults: UserDefaults(suiteName: "ProxyTrafficMonitorPreview") ?? .standard)
    store.removeAll()

    var sub1 = Subscription(name: "订阅1 · fcapp.run", resetDay: 25)
    sub1.lastTraffic = TrafficInfo(upload: 1_549_406_489, download: 27_259_548_951,
                                   total: 115_964_116_992, expire: 1_792_858_862, fetchedAt: Date())
    store.add(sub1)

    var sub2 = Subscription(name: "订阅2 · cocoduck.cc", resetDay: 3)
    sub2.lastTraffic = TrafficInfo(upload: 2_768_312_077, download: 46_639_030_977,
                                   total: 53_687_091_200, expire: 1_806_759_842, fetchedAt: Date())
    store.add(sub2)

    return store
}

#Preview("设置界面") {
    SettingsView(store: previewStore())
}
#endif
