# ProxyMonitor

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/ooaaeiei2-beep/ProxyMonitor/releases/latest)
[![Release](https://img.shields.io/github/v/release/ooaaeiei2-beep/ProxyMonitor)](https://github.com/ooaaeiei2-beep/ProxyMonitor/releases/latest)
[![License](https://img.shields.io/github/license/ooaaeiei2-beep/ProxyMonitor)](LICENSE)

macOS 菜单栏的代理订阅流量监视器。常驻状态栏显示已用百分比，鼠标一点即可看各订阅明细、手动刷新、调整设置。

不代理流量、不改系统网络配置，只做一件事：定期读取订阅链接返回的 `Subscription-Userinfo` 响应头，把「已用 / 总量」算成百分比放到菜单栏上。

## 为什么做这个

订阅多了以后，查用量是件麻烦事：每家后台都要单独登录，有的还要过验证码；想知道「这个月还剩多少」得逐个点进去看；等发现快用完时，通常已经超了。

`Subscription-Userinfo` 本来就把用量写在响应头里——拉订阅时顺手读一下，就能一直知道。这个应用做的就是这件事，并把结果压缩成状态栏上的一两个字符。

## 功能

- **多订阅**：可添加多个订阅，各自独立记录成功/失败时间与每日快照
- **三种显示模式**
  - `占比最高`（默认）：显示当前用量百分比最高的那条
  - `轮播`：在多个订阅之间轮换显示
  - `总量`：所有订阅合计的已用占比
- **状态栏图标反映状态**：正常 / 刷新中 / 数据陈旧 / 订阅异常 / 刷新结果闪示
- **菜单全自绘**：点「立即刷新」后菜单留在原地，刷新进度与结果可直接看到，不会像系统原生菜单那样点完就收
- **重置日推断**：从每日快照的用量回落点推断月度重置日，也可手动指定
- **用量与到期提醒**：用量到 80% / 95%、套餐剩 7 天 / 1 天、月度重置前 1 天各提醒一次。通知按事件去重并持久化，重启不会重复打扰
- **登录时启动**（可选）

## 数据与隐私

订阅链接里带着 token，所以这块是设计时优先考虑的：

- **订阅链接（含 token）只存钥匙串**，service 为 `com.xushuda.proxytrafficmonitor`，account 为 `url.<订阅 UUID>`；不写入 UserDefaults，也不写日志
- **其余配置与历史**存于 UserDefaults 域 `com.xushuda.proxymonitor`
- **日志**在 `~/Library/Logs/ProxyMonitor/proxymonitor.log`，按大小轮转。失败只记录分类代码与时间戳，不记录原始错误文本（`URLError` 的描述可能含完整订阅 URL）
- **不做任何数据上报**，无第三方 SDK，无分析埋点。见 `ProxyTrafficMonitor/PrivacyInfo.xcprivacy`

## 系统要求

- macOS 13.0 或更高
- 订阅地址必须使用 **HTTPS**。应用未开启 ATS 明文例外，`http://` 订阅会被系统拦截。

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/ooaaeiei2-beep/ProxyMonitor/releases/latest) 下载 `ProxyMonitor-<版本>.dmg`，挂载后把 `ProxyMonitor.app` 拖进 `/Applications`。

> 应用使用 adhoc 签名、未经 Apple 公证。若通过浏览器下载，首次打开会被 Gatekeeper 拦截，提示「无法验证开发者」或「已损坏」——**这不是文件坏了**，本项目没有 Apple 开发者账号（$99/年）。
>
> 任选其一即可正常打开：
>
> 1. 在「应用程序」里**右键点 ProxyMonitor → 打开**，弹窗里再点一次「打开」
> 2. 或执行 `xattr -dr com.apple.quarantine /Applications/ProxyMonitor.app`
>
> 用下面的安装脚本装不会带 quarantine 属性，因此没有这个提示。

### 用安装脚本

脚本会确定版本 → 下载 DMG → 用 `SHA256SUMS.txt` 校验完整性（不一致直接拒绝）→ 退出旧版本 → 备份到 `~/Library/Application Support/ProxyMonitor/backups/` → 安装到 `/Applications` → 打开。

```bash
curl -fsSL https://github.com/ooaaeiei2-beep/ProxyMonitor/releases/latest/download/install.sh -o install.sh
less install.sh          # 建议先看一眼再执行
bash install.sh
```

常用选项：

```bash
bash install.sh -v 1.1.0                        # 指定版本
bash install.sh --proxy http://127.0.0.1:7897   # 指定下载代理
bash install.sh --no-open                       # 装完不自动打开
bash install.sh --help                          # 全部选项
```

国内直连 GitHub 的 Release 资源（`objects.githubusercontent.com`）常出现 TLS 握手超时。脚本在直连失败时会自动探测本地常见代理端口（7897 / 7890 / 6152 / 1087 / 8080 / 8888）并重试一次；也可用 `--proxy` 显式指定，或用 `PTM_BASE_URL` 指向镜像。

## 使用

点击状态栏图标打开菜单：

| 菜单项 | 快捷键 | 说明 |
|---|---|---|
| 立即刷新 | ⌘R | 拉取全部订阅；菜单保持打开，底部出现结果汇总行 |
| 设置… | ⌘, | 打开设置窗口（订阅表格、名称/URL/UA/重置日、显示模式、登录时启动） |
| 退出 | ⌘Q | 退出应用 |

### 状态栏图标

按优先级从高到低：

| 图标 | 含义 | 触发条件 |
|---|---|---|
| `checkmark.circle` | 刷新成功 | 全部刷新结束、0 失败，且菜单已关闭（2.5 秒） |
| `exclamationmark.triangle` | 刷新失败 | 全部刷新结束、有失败，且菜单已关闭（4 秒） |
| `arrow.triangle.2.circlepath` | 刷新中 | 手动或定时刷新进行中 |
| `exclamationmark.triangle` | 订阅异常 | 任一订阅上次拉取失败 |
| `clock.arrow.2.circlepath` | 数据陈旧 | 距上次成功拉取超过 2 小时 |
| `network` | 正常 | 以上都不成立 |

图标右侧的文字只有三种取值：`N%`（百分比）、`PTM`（尚未取到数据）、`—`（首次拉取即失败，无缓存可显示）。

## 常见问题

**为什么不直接看服务商后台？**
可以，但每家都要单独登录，而且你通常不会天天去。这个应用的意义是把「还剩多少」变成不需要主动查询的信息。

**会不会拖慢系统？**
只在定时刷新时发起一次 HTTPS 请求，读一个响应头就结束。不代理流量，不常驻网络连接。

**订阅源不返回 `Subscription-Userinfo` 头怎么办？**
用不了。这是唯一的数据来源，没有降级方案。

## 从源码构建

只需要 Xcode Command Line Tools，不需要完整 Xcode：

```bash
xcode-select --install          # 若尚未安装
./scripts/build-clt.sh          # release，arm64 + x86_64 universal
./scripts/build-clt.sh --debug  # debug，单架构，含调试开关
```

产物在 `build/clt/ProxyMonitor.app`。

构建脚本自己完成 `swiftc` 编译、`iconutil` 生成 icns、Info.plist 占位符替换、隐私清单落位、产物自检、adhoc 签名。发布打包见 `scripts/`：

```bash
# 打 DMG 并生成校验文件
hdiutil create -volname ProxyMonitor -srcfolder <暂存目录> -ov -format UDZO ProxyMonitor-<版本>.dmg
shasum -a 256 ProxyMonitor-<版本>.dmg > SHA256SUMS.txt
```

### 调试开关

仅 debug 构建有效，用环境变量驱动，用于核对菜单几何与交互：

```bash
PTM_USE_MOCK=1 ./build/clt/ProxyMonitor.app/Contents/MacOS/ProxyMonitor
```

`MenuCalibration` 支持 `PTM_CALIBRATE_MENU` / `_WARP` / `_KEY` / `_FLASH` / `_SNAPSHOT` 等，可 dump 菜单视图树、断言 hover 与快捷键、验证刷新结果闪示序列。

> ⚠️ Mock 数据与真实订阅共用同一个 UserDefaults 域。代码里已对 Mock 模式禁用落盘，但不要自行去掉这层保护，否则真实订阅列表会被覆盖。

## 目录结构

```
ProxyTrafficMonitor/
├── App/          入口、AppDelegate、菜单标定工具（DEBUG）
├── Models/       Subscription / TrafficInfo / TrafficRecord / Trend
├── Providers/    订阅拉取与响应头解析
├── Services/     订阅存储、拉取调度、通知、开机启动、重置日推断
├── UI/           状态栏控制器、自绘菜单行、设置窗口
├── Utils/        字节格式化、钥匙串、日志
└── PrivacyInfo.xcprivacy
scripts/
├── build-clt.sh  不依赖 Xcode 的构建
└── install.sh    从 GitHub Release 安装
```

## 已知限制

- **没有 Developer ID 签名，未公证**。无法做到「下载双击即装」，接收方需用安装脚本或手动放行。要消除这个限制，需 Apple Developer Program 的 Developer ID Application 证书，再补 `notarytool submit` + `stapler staple` 两步。
- 只读取 `Subscription-Userinfo` 响应头。不返回该头的订阅源无法使用。

## 许可

[MIT](LICENSE) © 2026 xushuda
