//
//  LaunchPlanBuilderTests.swift
//  ProxyPilotTests
//
//  The launcher is the core of the MVP, so every generated value is asserted here.
//

import XCTest
@testable import ProxyPilot

final class LaunchPlanBuilderTests: XCTestCase {

    private let httpProxy = ProxyProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "FlClash", type: .http, host: "127.0.0.1", port: 7890
    )

    private let socksProxy = ProxyProfile(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Local SOCKS", type: .socks5, host: "127.0.0.1", port: 1080
    )

    private func makeApp(
        strategy: LaunchStrategy = .auto,
        runtime: ApplicationRuntime = .electron,
        bypass: [String] = AppSettings.defaultBypassList
    ) -> ManagedApplication {
        ManagedApplication(
            name: "Codex",
            bundleIdentifier: "com.openai.codex",
            bundlePath: "/Applications/Codex.app",
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            proxyProfileID: httpProxy.id,
            launchStrategy: strategy,
            bypassDomains: bypass,
            runtime: runtime
        )
    }

    // MARK: Proxy URL

    func testProxyURLStringForHTTP() {
        XCTAssertEqual(LaunchPlanBuilder.proxyURLString(for: httpProxy), "http://127.0.0.1:7890")
    }

    func testProxyURLStringForSOCKS5() {
        XCTAssertEqual(LaunchPlanBuilder.proxyURLString(for: socksProxy), "socks5://127.0.0.1:1080")
    }

    func testProxyURLStringIsNilForDirectAndNil() {
        XCTAssertNil(LaunchPlanBuilder.proxyURLString(for: nil))
        XCTAssertNil(LaunchPlanBuilder.proxyURLString(for: .direct))
    }

    func testSignatureIdentifiesTheEndpoint() {
        XCTAssertEqual(LaunchPlanBuilder.proxySignature(for: httpProxy), "http://127.0.0.1:7890")
        XCTAssertEqual(LaunchPlanBuilder.proxySignature(for: nil), LaunchPlanBuilder.directSignature)
        XCTAssertEqual(LaunchPlanBuilder.proxySignature(for: .direct), LaunchPlanBuilder.directSignature)
    }

    func testSignatureChangesWhenThePortChanges() {
        var moved = httpProxy
        moved.port = 7891
        XCTAssertNotEqual(
            LaunchPlanBuilder.proxySignature(for: httpProxy),
            LaunchPlanBuilder.proxySignature(for: moved)
        )
    }

    // MARK: Environment generation

    func testEnvironmentSetsEveryCaseForHTTP() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: httpProxy, bypass: AppSettings.defaultBypassList)
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            XCTAssertEqual(env[key], "http://127.0.0.1:7890", "\(key) was not set")
        }
    }

    func testEnvironmentSetsEveryCaseForSOCKS5() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: socksProxy, bypass: AppSettings.defaultBypassList)
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            XCTAssertEqual(env[key], "socks5://127.0.0.1:1080", "\(key) was not set")
        }
    }

    func testDirectClearsProxyVariables() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: nil, bypass: AppSettings.defaultBypassList)
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            XCTAssertEqual(env[key], "", "\(key) must be explicitly cleared for DIRECT")
        }
    }

    func testNoProxyGeneration() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: httpProxy, bypass: AppSettings.defaultBypassList)
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(env["no_proxy"], "localhost,127.0.0.1,::1")
    }

    func testNoProxyTrimsAndDropsEmptyEntries() {
        XCTAssertEqual(LaunchPlanBuilder.noProxyValue([" localhost ", "", "   ", "*.local"]), "localhost,*.local")
    }

    func testNoProxyWithCustomDomains() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: httpProxy, bypass: ["localhost", "*.internal", "10.0.0.0/8"])
        XCTAssertEqual(env["NO_PROXY"], "localhost,*.internal,10.0.0.0/8")
    }

    func testEmptyBypassProducesEmptyNoProxy() {
        let env = LaunchPlanBuilder.proxyEnvironment(for: httpProxy, bypass: [])
        XCTAssertEqual(env["NO_PROXY"], "")
    }

    // MARK: Chromium arguments

    func testChromiumArgumentsForHTTP() {
        let args = LaunchPlanBuilder.chromiumArguments(for: httpProxy, bypass: AppSettings.defaultBypassList)
        XCTAssertEqual(args, [
            "--proxy-server=http://127.0.0.1:7890",
            "--proxy-bypass-list=localhost;127.0.0.1;::1"
        ])
    }

    func testChromiumArgumentsForSOCKS5() {
        let args = LaunchPlanBuilder.chromiumArguments(for: socksProxy, bypass: AppSettings.defaultBypassList)
        XCTAssertEqual(args.first, "--proxy-server=socks5://127.0.0.1:1080")
    }

    func testChromiumArgumentsAreEmptyForDirect() {
        XCTAssertTrue(LaunchPlanBuilder.chromiumArguments(for: nil, bypass: AppSettings.defaultBypassList).isEmpty)
        XCTAssertTrue(LaunchPlanBuilder.chromiumArguments(for: .direct, bypass: AppSettings.defaultBypassList).isEmpty)
    }

    func testChromiumBypassListUsesSemicolons() {
        XCTAssertEqual(LaunchPlanBuilder.chromiumBypassList(["localhost", "127.0.0.1", "::1"]), "localhost;127.0.0.1;::1")
    }

    func testChromiumArgumentsOmitBypassWhenListIsEmpty() {
        let args = LaunchPlanBuilder.chromiumArguments(for: httpProxy, bypass: [])
        XCTAssertEqual(args.count, 1)
        XCTAssertTrue(args[0].hasPrefix("--proxy-server="))
    }

    // MARK: Base environment hygiene

    func testSanitizedBaseEnvironmentBlocksLoaderAndDebugVariables() {
        let source = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_FRAMEWORK_PATH": "/tmp",
            "XCODE_RUNNING_FOR_PREVIEWS": "1",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/tmp"
        ]
        let env = LaunchPlanBuilder.sanitizedBaseEnvironment(from: source)
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["DYLD_FRAMEWORK_PATH"])
        XCTAssertNil(env["XCODE_RUNNING_FOR_PREVIEWS"])
        XCTAssertNil(env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"])
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testSanitizedBaseEnvironmentFillsEssentials() {
        let env = LaunchPlanBuilder.sanitizedBaseEnvironment(from: [:])
        XCTAssertFalse(env["HOME"]?.isEmpty ?? true)
        XCTAssertFalse(env["PATH"]?.isEmpty ?? true)
        XCTAssertFalse(env["USER"]?.isEmpty ?? true)
        XCTAssertFalse(env["TMPDIR"]?.isEmpty ?? true)
    }

    func testFullEnvironmentOverlaysProxyOnTopOfBase() {
        let env = LaunchPlanBuilder.fullEnvironment(
            for: httpProxy,
            bypass: AppSettings.defaultBypassList,
            base: ["HOME": "/Users/tester", "HTTP_PROXY": "http://stale:1"]
        )
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7890", "a stale inherited proxy must be overwritten")
    }

    // MARK: Plan assembly

    func testChromiumPlanForElectronApp() {
        let app = makeApp()
        let plan = LaunchPlanBuilder.makePlan(app: app, proxy: httpProxy, strategy: .auto)
        XCTAssertEqual(plan.strategy, .chromium)
        XCTAssertEqual(plan.arguments.first, "--proxy-server=http://127.0.0.1:7890")
        XCTAssertEqual(plan.environment["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertTrue(plan.usesProxy)
        XCTAssertEqual(plan.proxyProfileID, httpProxy.id)
    }

    func testEnvironmentPlanForNativeApp() {
        let app = makeApp(runtime: .native)
        let plan = LaunchPlanBuilder.makePlan(app: app, proxy: httpProxy, strategy: .auto)
        XCTAssertEqual(plan.strategy, .environment)
        XCTAssertTrue(plan.arguments.isEmpty, "a native app must not receive Chromium arguments")
        XCTAssertEqual(plan.environment["ALL_PROXY"], "http://127.0.0.1:7890")
    }

    func testExplicitDirectStrategyWinsOverAutoDetection() {
        let app = makeApp(strategy: .direct)
        let plan = LaunchPlanBuilder.makePlan(app: app, proxy: nil, strategy: .direct)
        XCTAssertEqual(plan.strategy, .direct)
        XCTAssertTrue(plan.arguments.isEmpty)
        XCTAssertEqual(plan.environment["HTTP_PROXY"], "")
        XCTAssertFalse(plan.usesProxy)
    }

    func testAutoStrategyResolvesToChromiumForChromiumRuntime() {
        let app = makeApp(runtime: .chromium)
        XCTAssertEqual(app.effectiveStrategy, .chromium)
    }

    func testAutoStrategyResolvesToEnvironmentForUnknownRuntime() {
        let app = makeApp(runtime: .unknown)
        XCTAssertEqual(app.effectiveStrategy, .environment)
    }

    // MARK: Shell rendering

    func testShellQuoteLeavesSafeValuesAlone() {
        XCTAssertEqual(LaunchPlanBuilder.shellQuote("/Applications/Codex.app/Contents/MacOS/Codex"),
                       "/Applications/Codex.app/Contents/MacOS/Codex")
    }

    func testShellQuoteEscapesSpaces() {
        XCTAssertEqual(LaunchPlanBuilder.shellQuote("/Applications/Visual Studio Code.app"),
                       "'/Applications/Visual Studio Code.app'")
    }

    func testShellCommandIncludesEnvironmentAndArguments() {
        let command = LaunchPlanBuilder.shellCommand(
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            arguments: ["--proxy-server=http://127.0.0.1:7890"],
            proxyEnvironment: LaunchPlanBuilder.proxyEnvironment(for: httpProxy, bypass: [])
        )
        XCTAssertTrue(command.contains("HTTP_PROXY=http://127.0.0.1:7890"))
        XCTAssertTrue(command.contains("HTTPS_PROXY=http://127.0.0.1:7890"))
        XCTAssertTrue(command.hasSuffix("/Applications/Codex.app/Contents/MacOS/Codex --proxy-server=http://127.0.0.1:7890"))
    }

    func testPlanShellCommandPutsVariablesBeforeTheExecutable() {
        let app = makeApp()
        let plan = LaunchPlanBuilder.makePlan(app: app, proxy: httpProxy, strategy: .auto)
        let command = plan.shellCommand
        guard let envIndex = command.range(of: "HTTP_PROXY=")?.lowerBound,
              let execIndex = command.range(of: "/Applications/Codex.app/Contents/MacOS/Codex")?.lowerBound else {
            return XCTFail("expected both an environment prefix and the executable path")
        }
        XCTAssertLessThan(envIndex, execIndex)
    }
}
