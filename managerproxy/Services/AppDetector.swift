//
//  AppDetector.swift
//  ProxyPilot
//
//  Determines whether an app understands `--proxy-server=` (Chromium/Electron)
//  by looking at what actually ships inside the bundle. Bundle-id mappings from
//  `KnownApplications` are only used when the filesystem is inconclusive.
//

import Foundation

enum AppDetector {

    // MARK: Public

    static func detect(
        bundleURL: URL,
        bundleIdentifier: String,
        executableURL: URL? = nil
    ) -> ApplicationRuntime {
        if let runtime = detectFromFrameworks(bundleURL: bundleURL) {
            return runtime
        }
        if hasAsarPayload(bundleURL: bundleURL) {
            return .electron
        }
        if let known = KnownApplications.known(bundleIdentifier: bundleIdentifier) {
            return known.runtime
        }
        if let _ = executableURL {
            return .native
        }
        return .unknown
    }

    /// Human-readable justification, surfaced in the application detail pane.
    static func detectionReason(
        bundleURL: URL,
        bundleIdentifier: String,
        executableURL: URL? = nil
    ) -> String {
        if let runtime = detectFromFrameworks(bundleURL: bundleURL) {
            switch runtime {
            case .chromium: return Localized.string("Bundles a Chromium framework")
            case .electron: return Localized.string("Bundles Electron Framework.framework")
            default: break
            }
        }
        if hasAsarPayload(bundleURL: bundleURL) {
            return Localized.string("Ships an app.asar payload")
        }
        if let known = KnownApplications.known(bundleIdentifier: bundleIdentifier) {
            return Localized.format("Known application mapping (%@)", known.runtime.displayName)
        }
        return Localized.string("No Chromium/Electron runtime detected")
    }

    // MARK: Framework inspection

    private static func detectFromFrameworks(bundleURL: URL) -> ApplicationRuntime? {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path),
              !names.isEmpty else {
            return nil
        }

        for name in names {
            let lowered = name.lowercased()
            if lowered.contains("electron framework") {
                return .electron
            }
            if lowered.contains("chromium embedded framework") {
                return .chromium
            }
            if lowered.contains("chrome framework") || lowered.contains("chromium framework") {
                return .chromium
            }
        }
        return nil
    }

    private static func hasAsarPayload(bundleURL: URL) -> Bool {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let candidates = ["app.asar", "app.asar.unpacked", "electron.asar"]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent(candidate).path) {
                return true
            }
        }
        return false
    }

    // MARK: Proxy compatibility

    /// Compatibility matrix rendered in the application detail pane.
    struct CompatibilityReport {
        var chromiumSupported: Bool
        var environmentSupported: Bool
        var transparentSupported: Bool = false

        var environmentNote: String {
            environmentSupported
                ? Localized.string("Exports HTTP_PROXY / HTTPS_PROXY / ALL_PROXY")
                : Localized.string("Not recommended for this app")
        }
    }

    static func compatibility(for app: ManagedApplication) -> CompatibilityReport {
        let chromium = app.runtime.supportsChromiumArguments
        return CompatibilityReport(
            chromiumSupported: chromium,
            // Environment variables are always worth setting — many tools honour them,
            // but we never promise it works for every app.
            environmentSupported: true
        )
    }
}
