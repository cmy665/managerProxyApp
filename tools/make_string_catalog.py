#!/usr/bin/env python3
"""Generates managerproxy/Localizable.xcstrings.

Keeps the whole translation table in one reviewable place and emits the String
Catalog Xcode compiles into <lang>.lproj/Localizable.strings.

    python3 tools/make_string_catalog.py

Keys are the English source strings exactly as they appear in code — including
printf placeholders such as "%@" and "%lld" — so a typo here shows up immediately
as an untranslated string in the UI rather than failing silently.

Deliberately NOT translated: Diagnostics log bodies, log category / level names,
protocol names (HTTP / HTTPS / SOCKS5 / DIRECT), environment variable names, and
Clash-style rule keywords (PROXY / DIRECT / BLOCK). Those are technical identifiers
that developers expect to see verbatim.
"""

import json
import pathlib

# key -> (zh-Hans, comment)
TRANSLATIONS: dict[str, tuple[str, str | None]] = {
    # ---------------------------------------------------------------- Commands
    "Enable All": ("全部启用", None),
    "Disable All": ("全部停用", None),
    "Test All Proxies": ("测试全部代理", None),
    "Settings…": ("设置…", None),
    "Diagnostics": ("诊断", None),

    # ----------------------------------------------------------------- Sidebar
    "Applications": ("应用", None),
    "Proxies": ("代理", None),
    "Settings": ("设置", None),
    "Per-App Proxy": ("按应用代理", None),

    # ----------------------------------------------------------------- MainView
    "Master switch is off": ("总开关已关闭", None),
    "Restart Managed Apps": ("重启受管应用", None),
    "Dismiss": ("忽略", None),
    "Drop .app bundles to add them": ("拖入 .app 即可添加", None),
    "ON": ("开", "Master switch state"),
    "OFF": ("关", "Master switch state"),
    "Master switch — when off, no app is launched with a proxy.":
        ("总开关：关闭后不会以代理方式启动任何应用。", None),
    "Test Proxy": ("测试代理", None),
    "Open Proxy Settings": ("打开代理设置", None),
    "OK": ("好", None),
    "Cancel": ("取消", None),
    "%@ is currently running.": ("%@ 正在运行。", None),
    "Force Quit %@": ("强制退出 %@", None),
    "Restart %@": ("重启 %@", None),
    "Added %@": ("已添加 %@", None),
    "%@ is already in the list": ("%@ 已在列表中", None),
    "%@ are still running. Restart required to remove proxy settings.":
        ("%@ 仍在使用代理设置运行，需要重启才能移除。", "Plural: several apps"),
    "%@ is still running. Restart required to remove proxy settings.":
        ("%@ 仍在使用代理设置运行，需要重启才能移除。", "Singular: one app"),
    ", ": ("、", "Separator between app names in a list"),

    # ------------------------------------------------------ ApplicationListView
    "Manage proxy settings for each application.": ("为每个应用单独配置代理。", None),
    "Search applications…": ("搜索应用…", None),
    "Add Application": ("添加应用", None),
    "Application": ("应用", None),
    "Bundle ID": ("Bundle ID", None),
    "Proxy": ("代理", None),
    "Status": ("状态", None),
    "No applications yet": ("还没有应用", None),
    "Add the apps you want to route through a proxy. ProxyPilot never touches other apps or your system-wide settings.":
        ("添加你希望走代理的应用。ProxyPilot 不会影响其他应用，也不会修改系统全局设置。", None),
    "Select an application to inspect it": ("选择一个应用查看详情", None),
    "%lld of %lld applications": ("共 %2$lld 个应用，显示 %1$lld 个", None),
    "Last scan %@": ("上次扫描：%@", None),

    # ------------------------------------------------------- ApplicationRowView
    "running": ("运行中", None),
    "Disable Proxy": ("停用代理", None),
    "Enable Proxy": ("启用代理", None),
    "Restart With Proxy": ("以代理重启", None),
    "Launch With Proxy": ("以代理启动", None),
    "Restart Required — Restart Now": ("需要重启 — 立即重启", None),
    "Test %@": ("测试 %@", None),
    "Reveal in Finder": ("在访达中显示", None),
    "Details": ("详情", None),
    "Remove from ProxyPilot": ("从 ProxyPilot 移除", None),
    "Actions": ("操作", None),
    "Assign a proxy profile to enable this app.": ("先指定代理配置才能启用此应用。", None),
    "Enable proxying for %@": ("为 %@ 启用代理", None),

    # ---------------------------------------------------- ApplicationDetailView
    "Direct (no proxy)": ("直连（不使用代理）", None),
    "This app connects directly. Choose a proxy profile to route its traffic.":
        ("此应用当前为直连。选择代理配置即可让其流量走代理。", None),
    "Mode": ("模式", None),
    "Resolves to %@": ("实际使用：%@", None),
    "Unsupported": ("不支持", None),
    "Bypass": ("绕过", None),
    "Add domain or IP…": ("添加域名或 IP…", None),
    "Add": ("添加", None),
    "Reset to the default bypass list": ("重置为默认绕过列表", None),
    "Applied as NO_PROXY and as Chromium’s --proxy-bypass-list.":
        ("同时写入 NO_PROXY 与 Chromium 的 --proxy-bypass-list。", None),
    "Proxy compatibility": ("代理兼容性", None),
    "Chromium Proxy": ("Chromium 代理", None),
    "--proxy-server supported": ("支持 --proxy-server", None),
    "Not available for this runtime": ("此运行时不支持", None),
    "Environment Proxy": ("环境变量代理", None),
    "Transparent Proxy": ("透明代理", None),
    "Requires Advanced Mode (Phase 2)": ("需要高级模式（Phase 2）", None),
    "Launch command": ("启动命令", None),
    "Copy the launch command": ("复制启动命令", None),
    "No plan available for this configuration.": ("当前配置无法生成启动方案。", None),
    "Testing…": ("测试中…", None),
    "The assigned proxy is not reachable — the app may not have network access.":
        ("指定的代理不可达 — 该应用可能无法联网。", None),
    "The app is running with an older configuration. Restart to apply the current settings.":
        ("应用正在使用旧配置运行，重启后生效。", None),
    "Path": ("路径", None),
    "Executable": ("可执行文件", None),
    "Runtime": ("运行时", None),
    "Detected by": ("检测依据", None),

    # ---------------------------------------------------- AddApplicationsSheet
    "Add Applications": ("添加应用", None),
    "Choose the apps you want ProxyPilot to manage.": ("选择希望 ProxyPilot 管理的应用。", None),
    "Rescan": ("重新扫描", None),
    "Search by name or bundle ID…": ("按名称或 Bundle ID 搜索…", None),
    "Scanning…": ("正在扫描…", None),
    "Nothing found yet": ("尚未发现应用", None),
    "ProxyPilot looks in /Applications, ~/Applications and /System/Applications. You can also browse for a specific .app.":
        ("ProxyPilot 会扫描 /Applications、~/Applications 和 /System/Applications，也可以手动选择 .app。", None),
    "Added": ("已添加", None),
    "Browse…": ("浏览…", None),
    "%lld selected": ("已选 %lld 个", None),
    "Add %lld application(s)": ("添加 %lld 个应用", None),
    "Nothing new to add": ("没有新增项", None),
    "Already in the list": ("已在列表中", None),

    # ------------------------------------------------------------ ProxyListView
    "Create and manage proxy profiles.": ("创建并管理代理配置。", None),
    "Search proxies…": ("搜索代理…", None),
    "Add Proxy": ("添加代理", None),
    "Name": ("名称", None),
    "Type": ("类型", None),
    "Address": ("地址", None),
    "built-in": ("内置", None),
    "Built-in": ("内置", None),
    "Edit": ("编辑", None),
    "Test Connection": ("测试连接", None),
    "Duplicate": ("复制", None),
    "Delete": ("删除", None),
    "No proxy profiles match “%@”.": ("没有匹配“%@”的代理配置。", None),

    # ---------------------------------------------------------- ProxyEditorView
    "Edit Proxy": ("编辑代理", None),
    "Host": ("主机", None),
    "Port": ("端口", None),
    "Authentication": ("身份验证", None),
    "Optional": ("可选", None),
    "Username": ("用户名", None),
    "Password": ("密码", None),
    "Enter username": ("输入用户名", None),
    "Enter password": ("输入密码", None),
    "Hide password": ("隐藏密码", None),
    "Show password": ("显示密码", None),
    "Stored in the macOS Keychain — never in a JSON file or the log.":
        ("保存在 macOS 钥匙串中，绝不写入 JSON 文件或日志。", None),
    "Proxy Available": ("代理可用", None),
    "Connection": ("连接", None),
    "HTTP": ("HTTP", None),
    "Save": ("保存", None),
    "Proxy added": ("已添加代理", None),
    "Proxy saved": ("已保存代理", None),

    # ------------------------------------------------------------ SettingsView
    "Preferences for ProxyPilot itself — never for your system proxy.":
        ("这些是 ProxyPilot 自身的偏好设置，不会改动系统代理。", None),
    "General": ("通用", None),
    "Launch ProxyPilot at Login": ("登录时启动 ProxyPilot", None),
    "Start the menu bar helper when you log in.": ("登录后自动运行菜单栏助手。", None),
    "Show Menu Bar Icon": ("显示菜单栏图标", None),
    "Keep quick per-app switches one click away.": ("随时一键切换各应用代理。", None),
    "Start Minimized": ("启动时最小化", None),
    "Open straight to the menu bar without showing the window.":
        ("只驻留菜单栏，不显示主窗口。", None),
    "Confirm Before Restarting Apps": ("重启应用前确认", None),
    "Always ask before quitting an app to apply proxy settings.":
        ("应用代理设置需要退出应用时，先向我确认。", None),
    "Appearance": ("外观", None),
    "Light matches the reference design; System follows macOS.":
        ("浅色与设计稿一致；跟随系统则使用 macOS 当前外观。", None),
    "System": ("跟随系统", None),
    "Light": ("浅色", None),
    "Dark": ("深色", None),
    "Default Proxy": ("默认代理", None),
    "Assigned automatically when you add a new application.":
        ("添加新应用时自动使用该配置。", None),
    "Default Bypass List": ("默认绕过列表", None),
    "Copied into every new application you add.": ("会复制到每个新添加的应用。", None),
    "Reset": ("重置", None),
    "Advanced": ("高级", None),
    "Enable Debug Logging": ("启用调试日志", None),
    "Include debug-level entries in Diagnostics.": ("在诊断中包含 debug 级别日志。", None),
    "Show Launch Command": ("显示启动命令", None),
    "Display the exact command used to start an app.":
        ("显示启动应用时使用的完整命令。", None),
    "Proxy Test URL": ("代理测试地址", None),
    "A small endpoint your proxy can reach. Default is Google's generate_204.":
        ("代理可访问的小型探测地址，默认使用 Google 的 generate_204。", None),
    "About": ("关于", None),
    "Version": ("版本", None),
    "Data folder": ("数据目录", None),
    "Running apps": ("运行中应用", None),
    "System proxy": ("系统代理", None),
    "Never modified": ("从不修改", None),
    "%lld managed": ("已托管 %lld 个", None),
    "Reveal Data Folder": ("显示数据目录", None),
    "Open Diagnostics": ("打开诊断", None),
    "Phase 1 cannot transparently proxy arbitrary macOS applications. Apps must support Chromium proxy arguments or conventional proxy environment variables.":
        ("Phase 1 无法透明代理任意 macOS 应用。目标应用必须支持 Chromium 代理参数或常规代理环境变量。", None),

    # --------------------------------------------------------- DiagnosticsView
    "Launch decisions, proxy tests and process events. Sensitive values are redacted.":
        ("启动决策、代理测试与进程事件。敏感信息已脱敏。", None),
    "Copy All": ("全部复制", None),
    "Clear": ("清除", None),
    "Filter log…": ("筛选日志…", None),
    "All categories": ("全部分类", None),
    "All levels": ("全部级别", None),
    "%lld of %lld entries": ("共 %2$lld 条日志，显示 %1$lld 条", None),
    "No log entries": ("暂无日志", None),
    "Launch an app or run a proxy test and the details will show up here.":
        ("启动应用或测试代理后，详情会显示在这里。", None),
    "Log copied to the clipboard": ("日志已复制到剪贴板", None),
    "Log cleared": ("日志已清除", None),

    # -------------------------------------------------------------- MenuBarView
    "Master switch": ("总开关", None),
    "+%lld more in the app": ("另有 %lld 个在应用内", None),
    "Open ProxyPilot": ("打开 ProxyPilot", None),
    "Tools": ("工具", None),
    "Test Proxy…": ("测试代理…", None),
    "View Logs…": ("查看日志…", None),
    "Check for Updates…": ("检查更新…", None),
    "About ProxyPilot": ("关于 ProxyPilot", None),
    "Proxying enabled": ("代理已启用", None),
    "Master switch off": ("总开关已关闭", None),
    "Quit ProxyPilot": ("退出 ProxyPilot", None),
    "ProxyPilot %@ is the latest build.": ("ProxyPilot %@ 已是最新版本。", None),
    "This is a Phase 1 build. Automatic updates arrive with the signed release channel.":
        ("这是 Phase 1 版本，自动更新将在签名发布渠道中提供。", None),

    # ------------------------------------------------------- Models / Services
    "Auto": ("自动", None),
    "Chromium": ("Chromium", None),
    "Environment": ("环境变量", None),
    "Direct": ("直连", None),
    "Pick the best strategy for the detected app runtime.":
        ("根据检测到的应用运行时自动选择。", None),
    "Pass --proxy-server=<url> to the app executable.":
        ("向应用传入 --proxy-server=<url> 参数。", None),
    "Export HTTP_PROXY / HTTPS_PROXY / ALL_PROXY before launching.":
        ("启动前导出 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY。", None),
    "Launch without any proxy configuration.": ("不添加任何代理配置直接启动。", None),
    "Electron": ("Electron", None),
    "Native": ("原生", None),
    "Unknown": ("未知", None),
    "Active": ("已生效", None),
    "Disabled": ("已停用", None),
    "Restart Required": ("需要重启", None),
    "Proxy Unavailable": ("代理不可用", None),
    "Proxy Missing": ("代理缺失", None),
    "Not tested": ("未测试", None),
    "Available · HTTP %lld": ("可用 · HTTP %lld", None),
    "Reachable · HTTP probe failed": ("可连通 · HTTP 探测失败", None),
    "Unavailable": ("不可用", None),
    "Available": ("可用", None),
    "Degraded": ("已降级", None),
    "Terminated": ("已终止", None),
    "Skipped": ("已跳过", None),
    "No proxy": ("不使用代理", None),
    "%@ — %@": ("%@ — %@", "Profile name — address"),
    "%@ could not be found on disk.": ("磁盘上找不到 %@。", None),
    "The application executable could not be found at %@.":
        ("找不到应用可执行文件：%@。", None),
    "The proxy %@ is not reachable.": ("代理 %@ 不可达。", None),
    "Unable to start %@ with proxy.": ("无法以代理方式启动 %@。", None),
    "%@ did not quit in time.": ("%@ 未能及时退出。", None),
    "%@ is still running.": ("%@ 仍在运行。", None),
    "The proxy configuration is invalid: %@": ("代理配置无效：%@", None),
    "The %@ launch strategy is not available for this application.":
        ("此应用不支持 %@ 启动方式。", None),
    "Settings could not be saved: %@": ("设置保存失败：%@", None),
    "The credential could not be stored securely: %@": ("凭据无法安全保存：%@", None),
    "ProxyPilot is switched off. Turn the master switch on to launch apps with a proxy.":
        ("ProxyPilot 已关闭。打开总开关后才会以代理方式启动应用。", None),
    "No proxy is assigned to this application.": ("此应用未指定代理。", None),
    "%@ has already been added.": ("%@ 已添加过。", None),
    "Check that your proxy client (FlClash, Clash, Surge…) is running and listening on this address.":
        ("请确认代理客户端（FlClash、Clash、Surge…）正在运行并监听该地址。", None),
    "The application may have been moved or uninstalled. Remove it and add it again.":
        ("应用可能已被移动或卸载，请移除后重新添加。", None),
    "Test the proxy connection, then try again.": ("请先测试代理连通性，然后重试。", None),
    "You can force quit the app, but unsaved work may be lost.":
        ("可以强制退出该应用，但未保存的内容可能丢失。", None),
    "Enable the master switch in the toolbar.": ("请打开工具栏中的总开关。", None),
    "ProxyPilot stores credentials in the macOS Keychain. Check Keychain Access permissions.":
        ("ProxyPilot 将凭据保存在 macOS 钥匙串中，请检查「钥匙串访问」的权限。", None),
    "Something went wrong.": ("出错了。", None),
    "Technical detail: %@": ("技术细节：%@", None),
    "%@ did not quit. Force quitting may discard unsaved work.":
        ("%@ 未能退出。强制退出可能丢失未保存的内容。", None),
    "%@ launched with proxy": ("已以代理方式启动 %@", None),
    "%@ launched": ("已启动 %@", None),
    "Launch at login could not be changed.": ("无法修改「登录时启动」。", None),
    "ProxyPilot must be in /Applications and signed for login items to work. (%@)":
        ("登录项需要 ProxyPilot 位于 /Applications 且已完成签名。（%@）", None),
    "Proxy settings require restarting the application.":
        ("代理设置需要重启应用才能生效。", None),
    "Bundles a Chromium framework": ("内置 Chromium 框架", None),
    "Bundles Electron Framework.framework": ("内置 Electron Framework.framework", None),
    "Ships an app.asar payload": ("内置 app.asar 载荷", None),
    "Known application mapping (%@)": ("已知应用映射（%@）", None),
    "No Chromium/Electron runtime detected": ("未检测到 Chromium / Electron 运行时", None),
    "Exports HTTP_PROXY / HTTPS_PROXY / ALL_PROXY":
        ("导出 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY", None),
    "Not recommended for this app": ("不建议用于此应用", None),
    "Name cannot be empty.": ("名称不能为空。", None),
    "Host cannot be empty.": ("主机不能为空。", None),
    "Host contains invalid characters.": ("主机包含无效字符。", None),
    "Port must be between 1 and 65535.": ("端口必须在 1 到 65535 之间。", None),

    # ------------------------------------------------------------ ProxyTester
    "Nothing is listening on %@:%lld.": ("没有进程监听 %@:%lld。", None),
    "Proxy returned HTTP %lld.": ("代理返回 HTTP %lld。", None),
    "The proxy did not complete the request.": ("代理未能完成该请求。", None),
    "Could not connect to the proxy.": ("无法连接到代理。", None),
    "The proxy host could not be resolved.": ("无法解析代理主机名。", None),
    "The request timed out.": ("请求超时。", None),
    "The connection was closed by the proxy.": ("连接被代理关闭。", None),
    "TLS handshake failed through the proxy.": ("经由代理的 TLS 握手失败。", None),
    "The site refused this exit node — switch to another node in your proxy client.":
        ("目标站点拒绝了当前出口节点，请在代理客户端里换个节点。", None),
    "The site restricts this region — switch to another node.":
        ("目标站点限制了该地区，请换个节点。", None),
    "The proxy requires authentication.": ("该代理需要身份验证。", None),
    "The proxy or its upstream is unavailable right now.": ("代理或其上游暂时不可用。", None),
    "SOCKS5 resolves domains locally in Chromium — prefer an HTTP profile for this app.":
        ("SOCKS5 下 Chromium 会在本地解析域名，建议此应用改用 HTTP 配置。", None),
    "%@ was launched outside ProxyPilot.": ("%@ 是在 ProxyPilot 之外启动的。", None),
    "Keep as is": ("保持现状", None),
    "It is running without the proxy you assigned. Restart it through ProxyPilot to apply the settings.":
        ("它当前未使用你指定的代理。通过 ProxyPilot 重启后才会生效。", None),
    "%@ proxy enabled — applies when ProxyPilot launches it.":
        ("%@ 已启用代理，将由 ProxyPilot 启动时生效。", None),
}

    

def main() -> None:
    root = pathlib.Path(__file__).resolve().parent.parent
    destination = root / "managerproxy" / "Localizable.xcstrings"

    strings: dict[str, dict] = {}
    for key, (value, comment) in sorted(TRANSLATIONS.items()):
        entry: dict = {"extractionState": "manual"}
        if comment:
            entry["comment"] = comment
        entry["localizations"] = {
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": value,
                }
            }
        }
        strings[key] = entry

    catalog = {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }

    destination.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {destination.relative_to(root)} with {len(strings)} keys")


if __name__ == "__main__":
    main()
