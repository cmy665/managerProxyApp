//
//  PersistenceAndRuleTests.swift
//  ProxyPilotTests
//
//  Round-trips every persisted model through a throwaway support directory.
//

import XCTest
@testable import ProxyPilot

final class PersistenceAndRuleTests: XCTestCase {

    private var directory: URL!
    private var service: PersistenceService!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProxyPilotPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = PersistenceService(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Timestamps are stored as ISO-8601 with millisecond precision, so compare
    /// them with an explicit tolerance rather than for exact equality.
    private func assertDatesClose(
        _ lhs: Date,
        _ rhs: Date,
        accuracy: TimeInterval = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            lhs.timeIntervalSince1970,
            rhs.timeIntervalSince1970,
            accuracy: accuracy,
            "dates drifted beyond the stored precision",
            file: file,
            line: line
        )
    }

    // MARK: Applications

    func testApplicationRoundTrip() throws {
        let app = ManagedApplication(
            name: "Codex",
            bundleIdentifier: "com.openai.codex",
            bundlePath: "/Applications/Codex.app",
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            enabled: true,
            proxyProfileID: UUID(),
            launchStrategy: .chromium,
            bypassDomains: ["localhost", "127.0.0.1", "::1"],
            runtime: .electron,
            version: "1.2.3"
        )
        service.saveApplications([app])

        let loaded = service.loadApplications()
        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded.first)

        XCTAssertEqual(restored.id, app.id)
        XCTAssertEqual(restored.name, app.name)
        XCTAssertEqual(restored.bundleIdentifier, app.bundleIdentifier)
        XCTAssertEqual(restored.bundlePath, app.bundlePath)
        XCTAssertEqual(restored.executablePath, app.executablePath)
        XCTAssertEqual(restored.enabled, app.enabled)
        XCTAssertEqual(restored.proxyProfileID, app.proxyProfileID)
        XCTAssertEqual(restored.launchStrategy, app.launchStrategy)
        XCTAssertEqual(restored.bypassDomains, app.bypassDomains)
        XCTAssertEqual(restored.runtime, app.runtime)
        XCTAssertEqual(restored.version, app.version)
        assertDatesClose(restored.createdAt, app.createdAt)
        assertDatesClose(restored.updatedAt, app.updatedAt)
    }

    func testDatePrecisionIsMilliseconds() throws {
        let now = Date()
        let record = LaunchRecord(
            appID: UUID(),
            proxyProfileID: nil,
            signature: "direct",
            strategy: .direct,
            date: now
        )
        service.saveLaunchRecords([record])

        let restored = try XCTUnwrap(service.loadLaunchRecords().first)
        assertDatesClose(restored.date, now)

        // The persisted value must carry a fractional component, otherwise
        // sub-second ordering information would be lost.
        let raw = try String(contentsOf: service.url(for: .launchRecords), encoding: .utf8)
        XCTAssertTrue(raw.contains("."), "expected fractional seconds in the stored timestamp")
    }

    func testLegacyWholeSecondTimestampsStillDecode() throws {
        // A file written before fractional seconds were introduced must still load.
        let legacy = #"[{"appID":"11111111-1111-1111-1111-111111111111","signature":"direct","strategy":"direct","date":"2026-09-10T11:00:00Z"}]"#
        try legacy.data(using: .utf8)!.write(to: service.url(for: .launchRecords))

        let restored = try XCTUnwrap(service.loadLaunchRecords().first)
        XCTAssertEqual(restored.signature, "direct")

        let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-10T11:00:00Z"))
        assertDatesClose(restored.date, reference, accuracy: 0.5)
    }

    func testLoadingFromAnEmptyDirectoryYieldsEmptyCollections() {
        XCTAssertTrue(service.loadApplications().isEmpty)
        XCTAssertTrue(service.loadProxies().isEmpty)
        XCTAssertTrue(service.loadRules().isEmpty)
        XCTAssertNil(service.loadSettings())
        XCTAssertTrue(service.loadLaunchRecords().isEmpty)
    }

    // MARK: Proxies

    func testProxiesRoundTrip() throws {
        let proxy = ProxyProfile(name: "FlClash", type: .http, host: "127.0.0.1", port: 7890)
        service.saveProxies([proxy])
        XCTAssertEqual(service.loadProxies(), [proxy])
    }

    func testBuiltInDirectProfileIsNeverPersisted() throws {
        service.saveProxies([ProxyProfile.direct, ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 1)])
        let loaded = service.loadProxies()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "A")
        XCTAssertFalse(loaded.contains { $0.isBuiltIn })
    }

    // MARK: Settings

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.showMenuBarIcon = false
        settings.confirmBeforeRestartingApps = false
        settings.enableDebugLogging = true
        settings.startMinimized = true
        settings.proxyTestURL = "https://example.com/204"
        settings.defaultBypassList = ["localhost", "*.local"]
        settings.masterEnabled = false

        service.saveSettings(settings)
        XCTAssertEqual(service.loadSettings(), settings)
    }

    func testSettingsDecodingToleratesMissingKeys() throws {
        let json = #"{"launchAtLogin":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.launchAtLogin)
        XCTAssertTrue(decoded.showMenuBarIcon, "defaults must fill in")
        XCTAssertEqual(decoded.proxyTestURL, AppSettings.defaultTestURL)
        XCTAssertEqual(decoded.defaultBypassList, AppSettings.defaultBypassList)
    }

    func testInvalidTestURLFallsBackToTheDefault() {
        var settings = AppSettings()
        settings.proxyTestURL = "not a url"
        XCTAssertEqual(settings.resolvedTestURL.absoluteString, AppSettings.defaultTestURL)

        settings.proxyTestURL = "ftp://example.com"
        XCTAssertEqual(settings.resolvedTestURL.absoluteString, AppSettings.defaultTestURL)

        settings.proxyTestURL = "https://example.com/generate_204"
        XCTAssertEqual(settings.resolvedTestURL.absoluteString, "https://example.com/generate_204")
    }

    func testNormalizedBypassListDropsDuplicatesAndBlanks() {
        var settings = AppSettings()
        settings.defaultBypassList = [" localhost ", "LOCALHOST", "", "  ", "::1"]
        XCTAssertEqual(settings.normalizedBypassList, ["localhost", "::1"])
    }

    // MARK: Rules

    func testRuleModelRoundTrip() throws {
        let appID = UUID()
        let proxyID = UUID()
        let rule = ProxyRule(
            appID: appID,
            domain: "api.openai.com",
            matchKind: .domainSuffix,
            action: .proxy,
            proxyProfileID: proxyID,
            priority: 10,
            enabled: true
        )
        service.saveRules([rule])

        let loaded = service.loadRules()
        XCTAssertEqual(loaded.count, 1)
        let decoded = try XCTUnwrap(loaded.first)
        XCTAssertEqual(decoded.id, rule.id)
        XCTAssertEqual(decoded.appID, appID)
        XCTAssertEqual(decoded.domain, "api.openai.com")
        XCTAssertEqual(decoded.matchKind, .domainSuffix)
        XCTAssertEqual(decoded.action, .proxy)
        XCTAssertEqual(decoded.proxyProfileID, proxyID)
        XCTAssertEqual(decoded.priority, 10)
    }

    func testRuleDecodingToleratesMissingKeys() throws {
        let json = #"{"domain":"github.com","action":"direct"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProxyRule.self, from: json)
        XCTAssertEqual(decoded.domain, "github.com")
        XCTAssertEqual(decoded.action, .direct)
        XCTAssertEqual(decoded.matchKind, .domain)
        XCTAssertTrue(decoded.enabled)
    }

    func testAllRuleActionsAreCodable() throws {
        for action in RuleAction.allCases {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(RuleAction.self, from: data), action)
        }
    }

    func testAllRuleMatchKindsAreCodable() throws {
        for kind in RuleMatchKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(RuleMatchKind.self, from: data), kind)
        }
    }

    // MARK: Launch records

    func testLaunchRecordRoundTrip() throws {
        let record = LaunchRecord(
            appID: UUID(),
            proxyProfileID: UUID(),
            signature: "http://127.0.0.1:7890",
            strategy: .chromium,
            arguments: ["--proxy-server=http://127.0.0.1:7890"],
            environmentKeys: ["ALL_PROXY"],
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"
        )
        service.saveLaunchRecords([record])

        let loaded = service.loadLaunchRecords()
        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.appID, record.appID)
        XCTAssertEqual(restored.proxyProfileID, record.proxyProfileID)
        XCTAssertEqual(restored.signature, record.signature)
        XCTAssertEqual(restored.strategy, record.strategy)
        XCTAssertEqual(restored.arguments, record.arguments)
        XCTAssertEqual(restored.environmentKeys, record.environmentKeys)
        XCTAssertEqual(restored.executablePath, record.executablePath)
        assertDatesClose(restored.date, record.date)
    }

    // MARK: Logging redaction

    func testSensitiveKeysAreRedacted() {
        XCTAssertEqual(LogRedactor.redact(key: "Password", value: "hunter2"), "••••••••")
        XCTAssertEqual(LogRedactor.redact(key: "proxy password", value: "hunter2"), "••••••••")
        XCTAssertEqual(LogRedactor.redact(key: "API_TOKEN", value: "abc"), "••••••••")
        XCTAssertEqual(LogRedactor.redact(key: "Authorization", value: "Bearer abc"), "••••••••")
        XCTAssertEqual(LogRedactor.redact(key: "Credential", value: "abc"), "••••••••")
        XCTAssertEqual(LogRedactor.redact(key: "Proxy", value: "http://127.0.0.1:7890"), "http://127.0.0.1:7890")
        XCTAssertEqual(LogRedactor.redact(key: "Username", value: "alice"), "alice")
    }

    func testLogEntryPersistsDetailAsPairedArrays() throws {
        let entry = LogEntry(
            category: .launcher,
            level: .success,
            message: "Launched Codex",
            detail: [("Executable", "/Applications/Codex.app/Contents/MacOS/Codex"), ("Proxy", "127.0.0.1:7890")]
        )
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([LogEntry].self, from: data)
        let restored = try XCTUnwrap(decoded.first)
        XCTAssertEqual(restored.message, "Launched Codex")
        XCTAssertEqual(restored.detail?.count, 2)
        XCTAssertEqual(restored.detail?.first?.0, "Executable")
        XCTAssertEqual(restored.detail?.first?.1, "/Applications/Codex.app/Contents/MacOS/Codex")

        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("detailKeys"), "tuples must be flattened for Codable")
    }

    @MainActor
    func testLogStoreCapsTheRingBuffer() {
        let store = LogStore(persistence: service)
        for index in 0..<800 {
            store.info("entry \(index)", category: .app)
        }
        XCTAssertLessThanOrEqual(store.entries.count, 600)
        XCTAssertEqual(store.entries.last?.message, "entry 799")
    }

    @MainActor
    func testLogStoreRedactsBeforeStoring() {
        let store = LogStore(persistence: service)
        store.info("signing in", category: .proxy, detail: [("password", "hunter2"), ("Host", "127.0.0.1")])
        let entry = store.entries.last
        let values = (entry?.detail ?? []).map(\.1)
        XCTAssertTrue(values.contains("••••••••"))
        XCTAssertFalse(values.contains("hunter2"))
    }
}
