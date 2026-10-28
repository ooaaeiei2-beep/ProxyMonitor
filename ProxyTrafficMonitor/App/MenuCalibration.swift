#if DEBUG
import AppKit

/// 仅 debug 构建：菜单对齐校准工具（release 编译时整段不存在）。
///
/// 用法：
///   PTM_CALIBRATE_MENU=1 PTM_CALIBRATE_DELAY=1.5 ./ProxyMonitor.app/Contents/MacOS/ProxyMonitor
/// 行为：打开状态栏菜单，把控件 frame 写入 `PTM_CALIBRATE_OUT/ptm_frames.txt`，关菜单并退出。
///
/// 可选环境变量：
///   PTM_CALIBRATE_SNAPSHOT=1        整窗离屏渲染到 ptm_menu.png（可做像素比对）
///   PTM_CALIBRATE_HOVER=1           把合成 mouseMoved 投递到首个自绘行，验证 hover 高亮
///   PTM_CALIBRATE_KEY=r             投递一次 ⌘R，验证自绘行的 keyEquivalent 仍然有效
///   PTM_CALIBRATE_APPEARANCE=dark   强制 App 外观
///
/// 三个坑：
///   1. 菜单打开时主线程进入 eventTracking 模式，`asyncAfter`（默认模式）不会触发，必须用 `.common` 模式 Timer；
///   2. `performClick` 会一直阻塞到菜单关闭，所以抓图的 Timer 必须在调用它之前挂上；
///   3. `store.load()` 是异步的，首次 `rebuildMenu()` 时订阅还没到位，
///      所以不能立刻开菜单——先等一小会儿，期间菜单会被重建，到点用 `statusItem.menu`（最新那份）。
enum MenuCalibration {
    private static var started = false
    private static var flashStarted = false
    private static var keyEquivalentResult: Bool?
    private static weak var statusItemRef: NSStatusItem?

    /// 仅 debug：验证「菜单关闭时的刷新结果闪示」这条通道。
    ///
    /// 用法：`PTM_USE_MOCK=1 PTM_CALIBRATE_FLASH=1 PTM_CALIBRATE_OUT=/tmp/x ./ProxyMonitor`
    /// 行为：完全不打开菜单，直接触发一次全部刷新；轮询到 `outcomeFlashIcon` 非 nil 时落盘并退出。
    /// 之所以要单独一个入口：菜单标定（`PTM_CALIBRATE_MENU`）里菜单始终开着，
    /// 结果永远走底部汇总行，闪示分支根本跑不到。
    static func runFlashCheckIfRequested(statusItem: NSStatusItem) {
        guard ProcessInfo.processInfo.environment["PTM_CALIBRATE_FLASH"] == "1" else { return }
        guard !flashStarted else { return }
        flashStarted = true
        statusItemRef = statusItem

        let env = ProcessInfo.processInfo.environment
        let outDir = env["PTM_CALIBRATE_OUT"] ?? "/tmp"
        let delay = Double(env["PTM_CALIBRATE_DELAY"] ?? "") ?? 2.0

        let trigger = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let controller = statusItem.menu?.delegate as? StatusBarController else { return }
                // Mock 数据第 3 条故意带 lastError（用于演示错误态），不清掉就永远是失败分支，
                // 成功分支（checkmark.circle）根本测不到。用一次同值 updateTraffic 把错误清掉。
                if env["PTM_CALIBRATE_FLASH_CLEAR"] == "1" {
                    for sub in controller.debugStore.subscriptions {
                        if let traffic = sub.lastTraffic {
                            controller.debugStore.updateTraffic(id: sub.id, traffic: traffic)
                        }
                    }
                }
                // 走和菜单项完全相同的 action（refresh 是 @objc 的，选择器名即方法名）
                _ = NSApp.sendAction(Selector(("refresh")), to: controller, from: nil)
            }
        }
        RunLoop.main.add(trigger, forMode: .common)

        // 轮询：闪示只持续 2.5s / 4s，0.1s 一次足够抓到。
        // 注意应用启动时本来就会自动跑一次定时刷新（带 mock 错误态 → ⚠），
        // 所以要记录**图标序列**并等到出现 ✓ 才收工，不能「抓到第一个非 nil 就停」。
        var elapsed = 0.0
        var seen: [String] = []
        var icons: [String] = []
        let poll = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                elapsed += 0.1
                guard let controller = statusItem.menu?.delegate as? StatusBarController else { return }
                let icon = controller.debugOutcomeFlashIcon ?? "nil"
                if seen.last != icon { seen.append(icon) }
                // 状态栏实际绘制的图标：验证「刷新中 → ⟳」在删掉 fetcher.isRefreshing 后仍然成立
                let drawn = controller.debugCurrentIconName ?? "nil"
                if icons.last != drawn { icons.append(drawn) }
                if seen.contains("checkmark.circle") || elapsed > 20 {
                    timer.invalidate()
                    let lines = [
                        "menuOpen=\(controller.debugIsMenuOpen)",
                        "flashSequence=\(seen.joined(separator: " → "))",
                        "iconSequence=\(icons.joined(separator: " → "))",
                        "cache=\(controller.debugCacheCheck())",
                        "elapsed=\(String(format: "%.1f", elapsed))"
                    ]
                    write(lines, to: outDir)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
    }

    static func runIfRequested(statusItem: NSStatusItem, menu: NSMenu) {
        guard ProcessInfo.processInfo.environment["PTM_CALIBRATE_MENU"] == "1" else { return }
        guard !started else { return }   // 菜单会被重建多次，只跑一次
        started = true
        statusItemRef = statusItem

        let env = ProcessInfo.processInfo.environment
        let outDir = env["PTM_CALIBRATE_OUT"] ?? "/tmp"
        let delay = Double(env["PTM_CALIBRATE_DELAY"] ?? "") ?? 1.0

        switch env["PTM_CALIBRATE_APPEARANCE"] {
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default:      break
        }

        let open = Timer(timeInterval: max(delay, 0.8), repeats: false) { _ in
            guard let button = statusItem.button else { return }

            // 交互模拟放在菜单打开之后
            let interact = Timer(timeInterval: 0.4, repeats: false) { _ in
                guard let current = statusItem.menu else { return }
                if env["PTM_CALIBRATE_HOVER"] == "1" { postHover(onFirstRowOf: current) }
                if env["PTM_CALIBRATE_WARP"] == "1" { warpToFirstRow() }
                if env["PTM_CALIBRATE_CLICK"] == "1" { clickFirstRow() }
                if let key = env["PTM_CALIBRATE_KEY"] { postCommand(key, on: current) }
            }
            RunLoop.main.add(interact, forMode: .common)

            // 抓图 + 收尾：必须挂在 performClick 之前（它会阻塞到菜单关闭）
            let settle = Double(env["PTM_CALIBRATE_SETTLE"] ?? "") ?? 0.8
            let finish = Timer(timeInterval: settle, repeats: false) { _ in
                // Timer 回调本身不携带 actor 上下文，但它一定在主 runloop 上执行
                MainActor.assumeIsolated {
                    capture(outDir: outDir, env: env)
                    statusItem.menu?.cancelTracking()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
            RunLoop.main.add(finish, forMode: .common)

            button.performClick(nil)
        }
        RunLoop.main.add(open, forMode: .common)
    }

    // MARK: - 交互模拟

    /// 把合成的 mouseMoved 投递到首个自绘行中心（先投一个行外的点，确保触发 mouseEntered）
    private static func postHover(onFirstRowOf menu: NSMenu) {
        guard let window = menuWindow(),
              let row = menu.items.compactMap({ $0.view as? MenuRowView }).first else { return }
        let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let outside = NSPoint(x: center.x, y: center.y - row.bounds.height * 3)
        for point in [outside, center] {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved,
                                                 location: point,
                                                 modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber,
                                                 context: nil,
                                                 eventNumber: 0,
                                                 clickCount: 0,
                                                 pressure: 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// 用真实光标移动（CGWarpMouseCursorPosition）把指针挪到首个自绘行中心。
    /// 合成 NSEvent 不会让菜单的跟踪循环认为"指针动了"，测不出 hover；只能真挪光标。
    private static func warpToFirstRow() {
        guard let point = firstRowScreenPoint() else { return }
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.height - point.y))
    }

    /// 真点一下首个自绘行（验证「点完菜单不收起」这个核心承诺）。
    /// 需要辅助功能权限，拿不到权限时事件会被静默丢弃。
    private static func clickFirstRow() {
        guard let point = firstRowScreenPoint() else { return }
        guard let primary = NSScreen.screens.first else { return }
        let cg = CGPoint(x: point.x, y: primary.frame.height - point.y)
        CGWarpMouseCursorPosition(cg)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cg, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private static func firstRowScreenPoint() -> CGPoint? {
        guard let window = menuWindow(), let content = window.contentView,
              let row = firstRow(in: content) else { return nil }
        let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        return window.convertPoint(toScreen: center)   // Cocoa 左下原点
    }

    private static func postCommand(_ key: String, on menu: NSMenu) {
        guard let window = menuWindow(),
              let event = NSEvent.keyEvent(with: .keyDown,
                                           location: .zero,
                                           modifierFlags: .command,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber,
                                           context: nil,
                                           characters: key,
                                           charactersIgnoringModifiers: key,
                                           isARepeat: false,
                                           keyCode: 15) else { return }
        // 直接问菜单：这个 keyEquivalent 还认不认？（自绘行的最大风险点）
        // 注意这会真的触发 action —— 日志里应出现「全部刷新开始（触发=手动）」。
        keyEquivalentResult = menu.performKeyEquivalent(with: event)
    }

    // MARK: - 抓取

    @MainActor
    private static func capture(outDir: String, env: [String: String]) {
        var lines: [String] = []
        // 这两项不依赖菜单窗口：⌘R 会把菜单关掉，此时菜单窗口已不可见，但仍要能读到结果反馈状态
        if let controller = statusItemRef?.menu?.delegate as? StatusBarController {
            lines.append("menuOpen=\(controller.debugIsMenuOpen)")
            lines.append("outcomeFlash=\(controller.debugOutcomeFlashIcon ?? "nil")")
        }
        if let result = keyEquivalentResult {
            lines.append("keyEquivalentHandled=\(result)")
        }

        guard let window = menuWindow(), let view = window.contentView else {
            write(lines, to: outDir)
            return
        }
        if let name = env["PTM_CALIBRATE_WINDOW_APPEARANCE"] {
            window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        lines.append("windowFrame=\(window.frame)")
        lines.append("contentBounds=\(view.bounds)")
        lines.append("backingScale=\(window.backingScaleFactor)")
        if let row = firstRow(in: view) {
            lines.append("firstRowHovered=\(row.debugIsHovered)")
        }
        dump(view, depth: 1, into: &lines)
        write(lines, to: outDir)

        guard env["PTM_CALIBRATE_SNAPSHOT"] == "1",
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outDir + "/ptm_menu.png"))
        }
    }

    private static func write(_ lines: [String], to outDir: String) {
        try? lines.joined(separator: "\n")
            .write(toFile: outDir + "/ptm_frames.txt", atomically: true, encoding: .utf8)
    }

    private static func menuWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && String(describing: type(of: $0)).lowercased().contains("menu")
        }
    }

    private static func firstRow(in view: NSView) -> MenuRowView? {
        if let row = view as? MenuRowView { return row }
        for sub in view.subviews {
            if let hit = firstRow(in: sub) { return hit }
        }
        return nil
    }

    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(type(of: view)) frame=\(view.frame)"
        if let label = view as? NSTextField {
            line += " text=\"\(label.stringValue)\" align=\(label.alignment.rawValue)"
            line += " textWidth=\(label.attributedStringValue.size().width)"
        }
        lines.append(line)
        for sub in view.subviews { dump(sub, depth: depth + 1, into: &lines) }
    }
}
#endif
