//
//  AppDetectorTests.swift
//  ProxyPilotTests
//
//  Runtime detection must be driven by what actually ships in the bundle, not by
//  the application's name.
//

import XCTest
@testable import ProxyPilot

final class AppDetectorTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProxyPilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    // MARK: Helpers

    /// Builds a synthetic .app with the given framework directory names.
    @discardableResult
    private func makeBundle(named name: String, frameworks: [String] = [], resources: [String] = []) throws -> URL {
        let bundle = sandbox.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        if !frameworks.isEmpty {
            let dir = contents.appendingPathComponent("Frameworks", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for framework in frameworks {
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent(framework, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        if !resources.isEmpty {
            let dir = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for resource in resources {
                FileManager.default.createFile(
                    atPath: dir.appendingPathComponent(resource).path,
                    contents: Data()
                )
            }
        }

        return bundle
    }

    // MARK: Framework signatures

    func testElectronFrameworkIsDetected() throws {
        let bundle = try makeBundle(named: "Cursor", frameworks: ["Electron Framework.framework"])
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.unknown"), .electron)
    }

    func testChromiumEmbeddedFrameworkIsDetected() throws {
        let bundle = try makeBundle(named: "CEFApp", frameworks: ["Chromium Embedded Framework.framework"])
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.unknown"), .chromium)
    }

    func testChromeFrameworkIsDetected() throws {
        let bundle = try makeBundle(named: "Browser", frameworks: ["Google Chrome Framework.framework"])
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.unknown"), .chromium)
    }

    func testAsarPayloadImpliesElectron() throws {
        let bundle = try makeBundle(named: "AsarApp", resources: ["app.asar"])
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.unknown"), .electron)
    }

    func testFrameworkSignatureOutranksTheKnownMapping() throws {
        // Chrome is known as Chromium, but this bundle actually ships Electron —
        // the filesystem is the source of truth.
        let bundle = try makeBundle(named: "Chrome", frameworks: ["Electron Framework.framework"])
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.google.Chrome"), .electron)
    }

    // MARK: Known mapping fallback

    func testKnownMappingIsUsedWhenTheBundleIsInconclusive() throws {
        let bundle = try makeBundle(named: "Discord")
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.hnc.Discord"), .electron)
    }

    func testChromiumPrefixIsRecognised() throws {
        let bundle = try makeBundle(named: "Brave")
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.brave.Browser"), .chromium)
    }

    func testUnrecognisedBundleWithoutExecutableIsUnknown() throws {
        let bundle = try makeBundle(named: "Mystery")
        XCTAssertEqual(AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.mystery"), .unknown)
    }

    func testUnrecognisedBundleWithExecutableIsNative() throws {
        let bundle = try makeBundle(named: "Mystery")
        let executable = sandbox.appendingPathComponent("binary")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        XCTAssertEqual(
            AppDetector.detect(bundleURL: bundle, bundleIdentifier: "com.example.mystery", executableURL: executable),
            .native
        )
    }

    // MARK: Capabilities

    func testChromiumAndElectronSupportProxyArguments() {
        XCTAssertTrue(ApplicationRuntime.chromium.supportsChromiumArguments)
        XCTAssertTrue(ApplicationRuntime.electron.supportsChromiumArguments)
        XCTAssertFalse(ApplicationRuntime.native.supportsChromiumArguments)
        XCTAssertFalse(ApplicationRuntime.unknown.supportsChromiumArguments)
    }

    func testDetectionReasonIsHumanReadable() throws {
        let bundle = try makeBundle(named: "Cursor", frameworks: ["Electron Framework.framework"])
        // Asserts on the technical term rather than the sentence, so it holds in
        // every localisation.
        XCTAssertTrue(
            AppDetector.detectionReason(bundleURL: bundle, bundleIdentifier: "com.example.unknown")
                .contains("Electron Framework.framework")
        )
    }

    // MARK: Compatibility matrix

    func testCompatibilityMatrixForElectronApp() {
        let app = ManagedApplication(
            name: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            bundlePath: "/Applications/Cursor.app",
            executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
            runtime: .electron
        )
        let report = AppDetector.compatibility(for: app)
        XCTAssertTrue(report.chromiumSupported)
        XCTAssertTrue(report.environmentSupported)
        XCTAssertFalse(report.transparentSupported, "transparent proxying is Phase 2")
    }

    func testCompatibilityMatrixForNativeApp() {
        let app = ManagedApplication(
            name: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            bundlePath: "/System/Applications/Utilities/Terminal.app",
            executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            runtime: .native
        )
        let report = AppDetector.compatibility(for: app)
        XCTAssertFalse(report.chromiumSupported)
        XCTAssertTrue(report.environmentSupported)
    }

    // MARK: Scanner metadata

    func testScannerRejectsNonAppBundles() {
        let notAnApp = sandbox.appendingPathComponent("readme.txt")
        FileManager.default.createFile(atPath: notAnApp.path, contents: Data())
        XCTAssertNil(AppScanner.makeDiscoveredApplication(from: notAnApp))
    }
}
