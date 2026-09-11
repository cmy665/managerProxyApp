//
//  LaunchPlan.swift
//  ProxyPilot
//
//  A fully-resolved description of how an app will be started.
//  Every value here comes from pure functions so the whole thing is unit-testable.
//

import Foundation

struct LaunchPlan: Equatable {
    var appID: UUID
    var appName: String
    var bundlePath: String
    var executablePath: String

    var strategy: LaunchStrategy

    /// Extra CLI arguments (Chromium: `--proxy-server=…`).
    var arguments: [String]

    /// The complete environment handed to the child process.
    var environment: [String: String]

    /// Only the variables ProxyPilot itself set — shown in the UI / diagnostics.
    var proxyEnvironment: [String: String]

    /// Fingerprint of the proxy configuration, used to detect "Restart Required".
    var proxySignature: String

    var proxyProfileID: UUID?

    // MARK: Presentation

    /// Human readable shell equivalent of this plan, with the proxy variables first.
    var shellCommand: String {
        var lines: [String] = []
        for key in LaunchPlanBuilder.managedEnvironmentKeys.sorted() {
            guard let value = proxyEnvironment[key] else { continue }
            lines.append("\(key)=\(LaunchPlanBuilder.shellQuote(value)) \\")
        }
        var command = LaunchPlanBuilder.shellQuote(executablePath)
        if !arguments.isEmpty {
            command += " " + arguments.map(LaunchPlanBuilder.shellQuote).joined(separator: " ")
        }
        lines.append(command)
        return lines.joined(separator: "\n")
    }

    var displayExecutable: String { executablePath }

    var usesProxy: Bool { !proxySignature.isEmpty && proxySignature != LaunchPlanBuilder.directSignature }
}

// MARK: - LaunchPlanBuilder

/// Pure, side-effect free builders. Unit tested in ProxyPilotTests.
enum LaunchPlanBuilder {

    static let directSignature = "direct"

    /// Environment variables ProxyPilot owns. Both cases are set because tools
    /// disagree about which one they honour.
    static let managedEnvironmentKeys: [String] = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy"
    ]

    /// Variables that must never be forwarded to a launched app — they can break
    /// code signing, inject libraries, or leak the host debug session.
    static let blockedEnvironmentPrefixes: [String] = [
        "DYLD_",
        "__XCODE",
        "XCODE_",
        "SWIFT_",
        "OS_ACTIVITY_",
        "__CF",
        "MallocStackLogging",
        "LIBRARY_PATH",
        "CPATH",
        "CLANG_"
    ]

    // MARK: Proxy URL

    static func proxyURLString(for proxy: ProxyProfile?) -> String? {
        guard let proxy, !proxy.isDirect, proxy.isValid else { return nil }
        return proxy.urlString
    }

    static func proxySignature(for proxy: ProxyProfile?) -> String {
        proxyURLString(for: proxy) ?? directSignature
    }

    // MARK: Bypass / NO_PROXY

    /// `localhost,127.0.0.1,::1` — the form used by NO_PROXY.
    static func noProxyValue(_ bypass: [String]) -> String {
        let cleaned = bypass
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: ",")
    }

    /// `localhost;127.0.0.1;::1` — the form Chromium expects.
    static func chromiumBypassList(_ bypass: [String]) -> String {
        let cleaned = bypass
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: ";")
    }

    // MARK: Environment

    /// The baseline environment for a launched app: inherited, minus anything that
    /// could interfere with the target process.
    static func sanitizedBaseEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]

        for (key, value) in source {
            if blockedEnvironmentPrefixes.contains(where: { key.hasPrefix($0) }) { continue }
            environment[key] = value
        }

        // Guarantee the essentials even when ProxyPilot itself was launched from an
        // unusual context (Xcode, launchd, a stripped-down shell).
        if environment["HOME"]?.isEmpty ?? true {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["USER"]?.isEmpty ?? true {
            environment["USER"] = NSUserName()
        }
        if environment["PATH"]?.isEmpty ?? true {
            environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if environment["TMPDIR"]?.isEmpty ?? true {
            environment["TMPDIR"] = NSTemporaryDirectory()
        }
        return environment
    }

    /// Only the proxy-related variables, which is what the UI shows.
    static func proxyEnvironment(for proxy: ProxyProfile?, bypass: [String]) -> [String: String] {
        var variables: [String: String] = [:]
        let noProxy = noProxyValue(bypass)
        let url = proxyURLString(for: proxy)

        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            variables[key] = url ?? ""
        }
        for key in ["http_proxy", "https_proxy", "all_proxy"] {
            variables[key] = url ?? ""
        }
        variables["NO_PROXY"] = noProxy
        variables["no_proxy"] = noProxy
        return variables
    }

    /// Baseline + proxy overlay.
    static func fullEnvironment(
        for proxy: ProxyProfile?,
        bypass: [String],
        base: [String: String]? = nil
    ) -> [String: String] {
        var environment = base ?? sanitizedBaseEnvironment()
        for (key, value) in proxyEnvironment(for: proxy, bypass: bypass) {
            environment[key] = value
        }
        return environment
    }

    // MARK: Chromium arguments

    static func chromiumArguments(for proxy: ProxyProfile?, bypass: [String]) -> [String] {
        guard let url = proxyURLString(for: proxy) else { return [] }

        var arguments = ["--proxy-server=\(url)"]
        let list = chromiumBypassList(bypass)
        if !list.isEmpty {
            // Chromium expects the whole value as one argument.
            arguments.append("--proxy-bypass-list=\(list)")
        }
        return arguments
    }

    // MARK: Shell rendering

    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:@=+,%")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `HTTP_PROXY=http://127.0.0.1:7890 /Applications/Codex.app/…/Codex --proxy-server=…`
    static func shellCommand(
        executablePath: String,
        arguments: [String],
        proxyEnvironment: [String: String],
        includeEnvironment: Bool = true
    ) -> String {
        var parts: [String] = []
        if includeEnvironment {
            for key in managedEnvironmentKeys.sorted() {
                guard let value = proxyEnvironment[key], !value.isEmpty else { continue }
                parts.append("\(key)=\(shellQuote(value))")
            }
        }
        parts.append(shellQuote(executablePath))
        parts.append(contentsOf: arguments.map(shellQuote))
        return parts.joined(separator: " ")
    }

    // MARK: Plan assembly

    static func makePlan(
        app: ManagedApplication,
        proxy: ProxyProfile?,
        strategy: LaunchStrategy
    ) -> LaunchPlan {
        let bypass = app.bypassDomains
        // Resolve `auto` first so the plan is identical no matter which entry point
        // produced it.
        let resolvedStrategy: LaunchStrategy = (strategy == .auto) ? app.effectiveStrategy : strategy

        let arguments: [String]
        switch resolvedStrategy {
        case .chromium:
            arguments = chromiumArguments(for: proxy, bypass: bypass)
        case .environment, .direct, .auto:
            arguments = []
        }

        return LaunchPlan(
            appID: app.id,
            appName: app.name,
            bundlePath: app.bundlePath,
            executablePath: app.executablePath,
            strategy: resolvedStrategy,
            arguments: arguments,
            environment: fullEnvironment(for: proxy, bypass: bypass),
            proxyEnvironment: proxyEnvironment(for: proxy, bypass: bypass),
            proxySignature: proxySignature(for: proxy),
            proxyProfileID: proxy?.id
        )
    }
}
