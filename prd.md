# ProxyPilot — macOS Per-App Proxy Manager

## 0. AI Coding Agent 执行指令

你是一名资深 macOS / Swift / NetworkExtension 工程师。

请根据本文档直接创建并实现一个可运行的 macOS 原生应用。

项目名称：

**ProxyPilot**

产品定位：

> 一个轻量级 macOS Per-App Proxy Manager，让用户无需开启 TUN/虚拟网卡，也可以针对指定应用单独配置 HTTP / SOCKS5 代理，并能够快速开启、关闭、测试和重新启动应用。

典型使用场景：

* Codex Desktop → `127.0.0.1:7890`
* Cursor → `127.0.0.1:7890`
* Chrome → DIRECT
* Terminal → SOCKS5 `127.0.0.1:1080`
* 其他应用不受影响

第一阶段不要尝试实现完整 Proxifier。

第一阶段优先解决：

**Codex Desktop / Cursor / VS Code / Chrome / Electron / Chromium 类应用的独立代理。**

必须保证：

1. 不修改 macOS 全局代理。
2. 不开启 TUN。
3. 不创建虚拟网卡。
4. 不修改目标 App 文件。
5. 不注入目标 App 二进制。
6. 不要求 SIP 关闭。
7. 不要求 root。
8. 不使用 `DYLD_INSERT_LIBRARIES`。
9. 不使用 proxychains 作为核心方案。
10. 用户关闭 ProxyPilot 后，其他应用网络不能受到影响。

NetworkExtension 属于 Phase 2，不得阻塞 MVP。

---

# 1. 产品背景

macOS 上很多应用没有独立代理设置。

例如用户运行：

* Codex Desktop
* Cursor
* VS Code
* Chrome
* Electron App

如果希望这些应用访问代理，通常需要：

* 开启系统代理；
* 开启 Clash/FlClash TUN；
* 开启虚拟网卡；
* 使用 Proxifier；
* 修改启动参数；
* 手动配置环境变量。

这些方案存在以下问题：

* 影响整个系统；
* 部分应用不遵循系统代理；
* TUN 可能影响局域网；
* DNS/路由容易出现问题；
* 每次手动启动非常麻烦。

ProxyPilot 的目标是：

> 为每个应用提供独立的 Proxy Profile，并通过最合适的启动方式启动目标应用。

---

# 2. 产品目标

用户应该可以完成：

```text
选择应用
   ↓
选择代理
   ↓
Enable
   ↓
ProxyPilot 自动判断启动策略
   ↓
重新启动目标 App
   ↓
目标 App 独立走代理
```

例如：

```text
Codex
HTTP
127.0.0.1
7890

[Enable]
```

ProxyPilot 应执行等价操作：

```bash
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=http://127.0.0.1:7890

/Applications/Codex.app/Contents/MacOS/Codex \
  --proxy-server=http://127.0.0.1:7890
```

其他 App 不受影响。

---

# 3. 技术栈

必须优先使用：

```text
Language: Swift
UI: SwiftUI
Platform: macOS
Minimum macOS: macOS 14+
Architecture: MVVM / Service Layer
Persistence: Codable + JSON
Secrets: Keychain
Networking: URLSession / Network.framework
Process Management: Foundation.Process
App Discovery: NSWorkspace
Logging: os.Logger
```

第一阶段禁止：

```text
Flutter
Electron
React Native
Tauri
```

这是一个 macOS 系统工具，应优先使用 Native API。

---

# 4. 产品架构

整体：

```text
ProxyPilot.app
│
├── UI
│
├── Application Manager
│
├── Proxy Manager
│
├── Rule Engine
│
├── Launcher Engine
│
├── Proxy Tester
│
├── Process Manager
│
└── Persistence
```

未来：

```text
ProxyPilot.app
       │
       │ IPC
       ▼
NetworkExtension
       │
       ▼
Transparent Proxy
```

但 Phase 1 不实现 NetworkExtension。

---

# 5. MVP 功能

## 5.1 应用管理

支持：

### 自动扫描

扫描：

```text
/Applications
~/Applications
```

获取：

```text
App Name
Bundle ID
Bundle URL
Executable URL
Icon
Version
```

使用：

```swift
Bundle(url:)
NSWorkspace
NSImage
```

### 手动添加

提供：

```text
+ Add Application
```

调用：

```swift
NSOpenPanel
```

仅允许：

```text
.app
```

用户也可以将 `.app` 拖入窗口。

---

# 6. App Model

创建：

```swift
struct ManagedApplication: Identifiable, Codable {
    let id: UUID

    var name: String
    var bundleIdentifier: String
    var bundlePath: String
    var executablePath: String

    var enabled: Bool

    var proxyProfileID: UUID?

    var launchStrategy: LaunchStrategy

    var bypassDomains: [String]

    var createdAt: Date
    var updatedAt: Date
}
```

LaunchStrategy：

```swift
enum LaunchStrategy: String, Codable {
    case auto
    case chromium
    case environment
    case direct
}
```

---

# 7. Proxy Profile

用户可以创建多个代理。

例如：

```text
FlClash
HTTP
127.0.0.1
7890
```

或者：

```text
Local SOCKS
SOCKS5
127.0.0.1
1080
```

数据模型：

```swift
struct ProxyProfile: Identifiable, Codable {
    let id: UUID

    var name: String

    var type: ProxyType

    var host: String
    var port: Int

    var username: String?
    var passwordKeychainID: String?

    var enabled: Bool
}
```

ProxyType：

```swift
enum ProxyType: String, Codable {
    case http
    case https
    case socks5
}
```

密码禁止直接写入 JSON。

使用：

```text
macOS Keychain
```

---

# 8. Launcher Engine

这是整个 MVP 最重要的模块。

设计：

```text
LauncherEngine
      │
      ├── ChromiumLauncher
      │
      ├── EnvironmentLauncher
      │
      └── DirectLauncher
```

协议：

```swift
protocol AppLaunching {
    func canHandle(_ app: ManagedApplication) -> Bool

    func launch(
        app: ManagedApplication,
        proxy: ProxyProfile?
    ) async throws
}
```

---

# 9. Chromium / Electron Launcher

主要支持：

```text
Codex
Cursor
VS Code
Chrome
Chromium
Brave
Edge
Electron Apps
```

代理启动：

```text
--proxy-server=http://127.0.0.1:7890
```

例如：

```bash
/Applications/Codex.app/Contents/MacOS/Codex \
--proxy-server=http://127.0.0.1:7890
```

同时设置：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY
```

HTTP：

```text
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
```

SOCKS5：

```text
ALL_PROXY=socks5://127.0.0.1:1080
```

NO_PROXY 默认：

```text
localhost
127.0.0.1
::1
```

---

# 10. App 类型自动检测

实现：

```text
AppDetector
```

目标：

```swift
enum ApplicationRuntime {
    case chromium
    case electron
    case native
    case unknown
}
```

检测依据允许包括：

```text
Bundle ID
Frameworks/Electron Framework.framework
Frameworks/Chromium Embedded Framework.framework
Info.plist
Executable metadata
Known App mapping
```

维护：

```swift
KnownApplications.swift
```

例如：

```text
Codex
Cursor
Visual Studio Code
Google Chrome
Chromium
Brave Browser
Microsoft Edge
Discord
Slack
```

不要仅通过 App Name 判断。

---

# 11. Environment Launcher

针对支持环境变量的程序：

设置：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY
http_proxy
https_proxy
all_proxy
no_proxy
```

大小写全部设置。

注意：

不能承诺所有 App 都遵循这些变量。

UI 必须显示兼容性状态。

例如：

```text
Proxy Compatibility

● Chromium Proxy       Supported
● Environment Proxy    Supported
○ Transparent Proxy    Requires Advanced Mode
```

---

# 12. Direct Mode

允许：

```text
DIRECT
```

Direct 不添加任何代理参数。

用途：

未来规则系统使用。

---

# 13. 应用启动与重启

当用户修改：

```text
OFF → ON
```

如果目标应用正在运行：

弹窗：

```text
Codex is currently running.

Proxy settings require restarting the application.

[Cancel]

[Restart Codex]
```

点击 Restart：

```text
Terminate
↓
Wait
↓
Launch With Proxy
```

优先：

```swift
NSRunningApplication.terminate()
```

等待合理时间。

失败后允许：

```text
Force Quit
```

但必须二次确认。

禁止默认 `kill -9`。

---

# 14. 主界面

设计成 macOS 原生工具风格。

窗口：

```text
┌─────────────────────────────────────────────────────────┐
│ ProxyPilot                                      ● ON    │
├───────────────┬─────────────────────────────────────────┤
│ Applications  │ Applications                            │
│               │                                         │
│ Proxies       │ Codex       ● Proxy    FlClash         │
│               │ Cursor      ● Proxy    FlClash         │
│ Settings      │ Chrome      ○ Direct                   │
│               │                                         │
│               │                  + Add Application      │
└───────────────┴─────────────────────────────────────────┘
```

Sidebar：

```text
Applications
Proxies
Settings
```

---

# 15. Application Row

每行显示：

```text
[Icon]

Codex
com.openai.codex

Proxy: FlClash

                     [ ON ]
```

状态：

```text
Green / Active
Gray / Disabled
Orange / Restart Required
Red / Proxy Unavailable
```

不要只依赖颜色表达状态。

同时显示文字/Icon。

---

# 16. Application Detail

点击 App：

```text
Codex

Icon

Bundle Identifier
com.openai.codex

Path
/Applications/Codex.app

────────────────────

Proxy

[FlClash               ▼]

Mode

● Auto
○ Chromium
○ Environment
○ Direct

────────────────────

Bypass

localhost
127.0.0.1
::1

+ Add Domain

────────────────────

Compatibility

Chromium Proxy      ✓
Environment Proxy   ✓
Transparent Proxy   —

────────────────────

[Test Proxy]

[Restart With Proxy]
```

---

# 17. Proxy 管理

Proxies 页面：

```text
FlClash
HTTP
127.0.0.1:7890
● Available

Local SOCKS
SOCKS5
127.0.0.1:1080
○ Offline

+ Add Proxy
```

编辑：

```text
Name

Type
HTTP / HTTPS / SOCKS5

Host

Port

Authentication
Optional

Username

Password

[Test Connection]
```

---

# 18. Proxy Test

必须实现代理测试。

不能只测试：

```text
127.0.0.1:7890
```

端口是否打开。

分两级：

## Level 1

TCP Connect：

```text
Host
Port
```

显示：

```text
Reachable
Latency: 3 ms
```

## Level 2

真实代理请求。

通过该 Proxy 请求 HTTPS URL。

默认测试：

```text
https://www.gstatic.com/generate_204
```

如果失败，可使用备用测试地址。

显示：

```text
Proxy Available

Connection     4 ms
HTTP           182 ms
Status         204
```

测试 URL 应允许用户在 Settings 中修改。

---

# 19. Master Switch

顶部：

```text
ProxyPilot    [ON]
```

Master OFF：

不能修改系统网络。

行为：

```text
停止由 ProxyPilot 管理的新代理启动
```

对于已经启动的 App：

显示：

```text
Restart required to remove proxy settings.
```

提供：

```text
Restart Managed Apps
```

不要偷偷结束用户应用。

---

# 20. Menu Bar

实现 Menu Bar Extra。

例如：

```text
ProxyPilot ●

Codex          ON
Cursor         ON
Chrome         DIRECT

────────────

Enable All
Disable All

────────────

Open ProxyPilot
Quit
```

点击：

```text
Codex ON/OFF
```

可以快速切换。

需要重启时显示确认。

---

# 21. Settings

至少包括：

```text
General

Launch ProxyPilot at Login

Show Menu Bar Icon

Start Minimized

Confirm Before Restarting Apps
```

Proxy：

```text
Default Proxy

Default Bypass List
```

Advanced：

```text
Enable Debug Logging

Show Launch Command

Proxy Test URL
```

---

# 22. 日志

使用：

```swift
import os

Logger
```

模块：

```text
AppScanner
Launcher
Proxy
Process
Persistence
```

Debug UI：

```text
Settings
→ Diagnostics
```

显示：

```text
2026-09-10 18:01:02
Launching Codex

Strategy:
Chromium

Proxy:
127.0.0.1:7890

Result:
Success
```

必须对：

```text
password
proxy password
token
credential
```

脱敏。

---

# 23. 数据存储

目录：

```text
~/Library/Application Support/ProxyPilot/
```

例如：

```text
applications.json
proxies.json
settings.json
```

Credentials：

```text
Keychain
```

禁止把密码写入：

```text
UserDefaults
JSON
Log
```

---

# 24. 数据模型预留 Rule Engine

虽然 MVP 不实现复杂规则，但架构必须预留。

定义：

```swift
struct ProxyRule: Identifiable, Codable {

    let id: UUID

    var appID: UUID?

    var domain: String?

    var action: RuleAction

    var proxyProfileID: UUID?

    var priority: Int
}
```

RuleAction：

```swift
enum RuleAction: String, Codable {
    case proxy
    case direct
    case block
}
```

Phase 1 可以只保存模型。

不要实现底层 Domain Flow interception。

---

# 25. Bypass

Chromium 模式支持：

```text
--proxy-bypass-list=
```

用户配置：

```text
localhost
127.0.0.1
::1
*.local
```

最终转换成 Chromium 可识别参数。

Environment：

```text
NO_PROXY
```

同步生成。

---

# 26. 错误处理

必须有统一错误模型：

```swift
enum ProxyPilotError: LocalizedError {

    case appNotFound

    case executableNotFound

    case proxyUnavailable

    case launchFailed

    case terminationFailed

    case invalidProxyConfiguration

    case unsupportedLaunchStrategy
}
```

UI 不显示：

```text
Error Code -123
```

而显示：

```text
Unable to start Codex with proxy.

The proxy 127.0.0.1:7890 is not reachable.

[Test Proxy]

[Open Proxy Settings]
```

---

# 27. 安全要求

必须遵守：

```text
No root
No sudo
No SIP modification
No binary injection
No App modification
No global system proxy modification
No TUN
No virtual interface
```

MVP 不能执行：

```text
networksetup -setwebproxy
networksetup -setsocksfirewallproxy
```

不能修改：

```text
SystemConfiguration
```

中的系统代理。

---

# 28. Phase 1 验收测试

至少验证：

## Test 1

环境：

```text
FlClash
HTTP Proxy
127.0.0.1:7890
TUN OFF
macOS System Proxy OFF
```

Codex：

```text
Enable Proxy
```

必须：

```text
Codex 可以访问网络
```

同时：

```text
Safari 不受影响
Xcode 不受影响
其他 App 不受影响
```

---

## Test 2

关闭：

```text
Codex Proxy
```

Restart Codex。

必须：

```text
Codex 恢复正常直接启动。
```

---

## Test 3

Proxy：

```text
127.0.0.1:9999
```

不存在。

必须显示：

```text
Proxy Unavailable
```

不能 crash。

---

## Test 4

Codex 已运行。

修改 Proxy。

必须：

```text
Restart Required
```

不能静默杀掉 Codex。

---

## Test 5

同时：

```text
Codex → Proxy A
Cursor → Proxy B
Chrome → Direct
```

三者配置互不影响。

---

# 29. MVP Definition of Done

满足以下条件才能认为 Phase 1 完成：

```text
✓ SwiftUI App 可运行

✓ 可扫描 Applications

✓ 可手动添加 App

✓ 可创建 HTTP Proxy

✓ 可创建 SOCKS5 Proxy

✓ 可测试 Proxy

✓ 每个 App 可选择 Proxy

✓ App 独立 Enable / Disable

✓ Chromium Launcher

✓ Environment Launcher

✓ Direct Launcher

✓ 自动检测 Electron / Chromium

✓ Restart With Proxy

✓ Bypass List

✓ Menu Bar

✓ Persistence

✓ Keychain

✓ Diagnostics

✓ Master Switch

✓ 不需要 TUN

✓ 不修改系统代理

✓ Codex Desktop 实机验证通过
```

---

# 30. Phase 2：Transparent Proxy

Phase 1 完成并稳定之后，再建立：

```text
ProxyPilotNetworkExtension
```

研究：

```text
NetworkExtension.framework

NETransparentProxyProvider

NEAppProxyFlow

NEFlowMetaData
```

目标：

```text
Native App
   │
   ▼
Network Flow
   │
   ▼
Transparent Proxy Provider
   │
   ├── App A → Proxy A
   │
   ├── App B → Proxy B
   │
   └── App C → DIRECT
```

Phase 2 目标是：

> 即使目标应用完全不支持 HTTP_PROXY / SOCKS / Chromium proxy 参数，也可以进行透明分流。

注意：

在正式实现 Phase 2 前，必须首先验证：

```text
Apple entitlement
Developer ID
System Extension
Network Extension entitlement
Distribution
macOS version
App Store / Outside App Store
```

的实际限制。

不要在未经验证的情况下假设所有第三方 App 都能通过普通消费者应用使用 Per-App VPN。

---

# 31. Phase 3：高级规则

未来：

```text
App
+
Domain
+
Protocol
+
Destination
```

例如：

```text
Codex
    api.openai.com
        → Proxy A

    github.com
        → DIRECT

    localhost
        → DIRECT
```

支持：

```text
DOMAIN
DOMAIN-SUFFIX
IP
CIDR
PROCESS
BUNDLE-ID
PORT
```

Action：

```text
PROXY
DIRECT
BLOCK
```

---

# 32. Phase 4：Traffic Monitor

未来 UI：

```text
Codex

↑ 12.4 MB
↓ 82.7 MB

Connections: 14

api.openai.com        Proxy
chatgpt.com           Proxy
github.com            Direct
localhost             Direct
```

不要在 Phase 1 实现。

---

# 33. 工程目录

建议：

```text
ProxyPilot/
│
├── ProxyPilotApp.swift
│
├── App/
│
│   └── AppState.swift
│
├── Models/
│   ├── ManagedApplication.swift
│   ├── ProxyProfile.swift
│   ├── ProxyRule.swift
│   └── Settings.swift
│
├── Views/
│   ├── MainView.swift
│   ├── SidebarView.swift
│   │
│   ├── Applications/
│   │   ├── ApplicationListView.swift
│   │   ├── ApplicationRowView.swift
│   │   └── ApplicationDetailView.swift
│   │
│   ├── Proxies/
│   │   ├── ProxyListView.swift
│   │   └── ProxyEditorView.swift
│   │
│   ├── Settings/
│   │   └── SettingsView.swift
│   │
│   └── MenuBar/
│       └── MenuBarView.swift
│
├── ViewModels/
│
├── Services/
│   ├── AppScanner.swift
│   ├── AppDetector.swift
│   ├── ProxyManager.swift
│   ├── ProxyTester.swift
│   ├── ProcessManager.swift
│   ├── PersistenceService.swift
│   └── KeychainService.swift
│
├── Launchers/
│   ├── AppLaunching.swift
│   ├── LauncherEngine.swift
│   ├── ChromiumLauncher.swift
│   ├── EnvironmentLauncher.swift
│   └── DirectLauncher.swift
│
├── Utilities/
│   ├── KnownApplications.swift
│   ├── Logger.swift
│   └── Extensions.swift
│
└── Tests/
```

---

# 34. 单元测试

至少覆盖：

```text
ProxyProfile validation

Proxy URL generation

Environment generation

NO_PROXY generation

Chromium arguments generation

AppDetector

Persistence

Rule Model

Invalid port

Invalid host
```

例如：

```swift
XCTAssertEqual(
    proxy.url,
    "http://127.0.0.1:7890"
)
```

---

# 35. 开发顺序

严格按照以下顺序执行：

### Milestone 1

创建 macOS SwiftUI 项目。

实现：

```text
Models
Persistence
Sidebar
Basic UI
```

确保 Build 成功。

提交：

```text
feat: initialize ProxyPilot macOS application
```

### Milestone 2

实现：

```text
AppScanner
NSOpenPanel
Drag & Drop
App metadata
```

提交：

```text
feat: add macOS application discovery
```

### Milestone 3

实现：

```text
Proxy Profile
Proxy Editor
Validation
Persistence
```

提交。

### Milestone 4

实现：

```text
ProxyTester
TCP Test
HTTP Proxy Test
SOCKS5 Test
```

提交。

### Milestone 5

实现：

```text
LauncherEngine
ChromiumLauncher
EnvironmentLauncher
DirectLauncher
```

这是 MVP 核心。

提交。

### Milestone 6

重点验证：

```text
Codex Desktop
Cursor
Chrome
```

修复兼容性。

提交。

### Milestone 7

实现：

```text
ProcessManager
Restart
Restart Required
```

提交。

### Milestone 8

实现：

```text
Menu Bar
Master Switch
Settings
Launch at Login
```

提交。

### Milestone 9

实现：

```text
Keychain
Diagnostics
Error Handling
```

提交。

### Milestone 10

Tests + README + Release Build。

---

# 36. AI Agent 工作规则

开发过程中：

1. 不要一次性生成整个项目后宣称完成。
2. 每个 Milestone 必须 Build。
3. Build 失败必须先修复。
4. 不允许留大量 TODO 作为“实现”。
5. 核心逻辑必须有真实代码。
6. 不允许 Mock Proxy 代替实际代理测试。
7. 不允许修改 macOS System Proxy。
8. 不允许偷偷引入 TUN。
9. 不允许为了实现 Per-App Proxy 去关闭 SIP。
10. 不允许默认使用 sudo。
11. 每完成一个 Milestone 创建 Git commit。
12. 不要覆盖用户现有未提交代码。
13. 修改前检查 Git status。
14. 每次提交只包含本 Milestone 相关修改。

---

# 37. 重要技术验证：Codex

Codex 是 Phase 1 第一优先级。

开发完成 ChromiumLauncher 后，优先验证：

```text
/Applications/Codex.app
```

实际 executable 必须从：

```text
CFBundleExecutable
```

读取。

不要写死：

```text
Codex
```

启动过程：

```text
ProxyPilot
   │
   ▼
读取 Bundle
   │
   ▼
找到 CFBundleExecutable
   │
   ▼
生成 proxy arguments
   │
   ▼
生成 proxy environment
   │
   ▼
Foundation.Process
   │
   ▼
Codex
```

必须记录：

```text
Executable
Launch Strategy
Proxy Type
Proxy Address
Arguments
Result
```

敏感字段除外。

---

# 38. 一个重要的产品语义

Phase 1 的：

```text
Enable Proxy
```

真实含义是：

> “下一次由 ProxyPilot 启动该应用时使用指定代理配置。”

它不是：

> “动态修改当前已经运行的进程网络栈。”

所以运行中的应用改变配置必须明确显示：

```text
Restart Required
```

这是产品 UI 和技术实现都必须遵守的规则。

---

# 39. README

最终 README 必须包括：

```text
ProxyPilot

Per-App Proxy Manager for macOS

Features

Screenshots

Requirements

Installation

Quick Start

Codex Example

Cursor Example

HTTP Proxy

SOCKS5 Proxy

Bypass

Limitations

Architecture

Security

Build From Source

Roadmap
```

Limitations 必须明确：

> Phase 1 cannot transparently proxy arbitrary macOS applications. Applications must support Chromium proxy arguments or conventional proxy environment variables.

不要虚假宣传为：

> Works with every macOS application.

Phase 2 完成后才能重新评估该描述。

---

# 40. 最终目标

Phase 1：

```text
                    ProxyPilot
                        │
          ┌─────────────┼─────────────┐
          │             │             │
        Codex         Cursor        Chrome
          │             │             │
       Proxy A        Proxy A        DIRECT
          │             │
          └──────┬──────┘
                 ▼
            FlClash / Clash

TUN = OFF
System Proxy = OFF
```

Phase 2：

```text
Applications
      │
      ▼
NetworkExtension
      │
      ▼
Rule Engine
      │
 ┌────┼──────────┐
 ▼    ▼          ▼
Proxy A Proxy B DIRECT
```

最终产品愿景：

> A lightweight, native and privacy-friendly per-application proxy manager for macOS.

优先完成一个真正可使用的 MVP，而不是过早实现复杂的 NetworkExtension。

现在开始执行：

1. 检查当前工作目录和 Git 状态。
2. 如果项目不存在，创建 ProxyPilot macOS SwiftUI 工程。
3. 建立 README / docs。
4. 创建基础目录结构。
5. 完成 Milestone 1。
6. Build。
7. 修复全部 Build Error。
8. Git commit。
9. 继续 Milestone 2。
10. 按本文档持续执行，直到 Phase 1 Definition of Done 全部通过。
