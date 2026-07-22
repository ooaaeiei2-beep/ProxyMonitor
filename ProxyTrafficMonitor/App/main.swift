import AppKit

// 显式 main 入口（不依赖 @main 自动生成，beta 系统更可控）
PTMLogger.info("main 入口开始")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 状态栏 app，不显示 Dock

// 关键：状态栏 app 默认无主菜单，导致 ⌘V/⌘C/⌘X 等快捷键无法路由到 TextField（粘贴失效）
// 必须手动创建含 Edit 菜单的 mainMenu
let mainMenu = NSMenu()

let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

NSApp.mainMenu = mainMenu
PTMLogger.info("主菜单已设置（Edit 菜单含 Paste）")

let delegate = AppDelegate()
app.delegate = delegate
PTMLogger.info("delegate 已设置，即将 run")
app.run()
