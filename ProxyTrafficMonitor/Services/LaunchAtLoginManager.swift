import Foundation
import ServiceManagement

/// 开机启动管理（macOS 13+，SMAppService.mainApp）。
/// mainApp 模式无需额外 entitlement，系统会把 app 加入登录项。
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false

    init() { refresh() }

    /// 同步当前状态
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 切换开机启动
    func toggle() -> Bool {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                isEnabled = false
                PTMLogger.info("已关闭开机启动")
            } else {
                try SMAppService.mainApp.register()
                isEnabled = true
                PTMLogger.info("已开启开机启动")
            }
            return true
        } catch {
            PTMLogger.error("切换开机启动失败: \(error.localizedDescription)")
            refresh()
            return false
        }
    }
}
