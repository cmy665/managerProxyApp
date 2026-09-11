//
//  AppScanner.swift
//  ProxyPilot
//
//  Discovers .app bundles in the standard locations and extracts the metadata
//  ProxyPilot needs (name, bundle id, executable, version, runtime).
//

import AppKit
import Foundation

final class AppScanner: @unchecked Sendable {

    // MARK: Search locations

    static var defaultSearchPaths: [URL] {
        var paths: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
        ]
        // System apps are useful targets too (Terminal, Xcode command line helpers).
        paths.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        paths.append(URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let searchPaths: [URL]
    /// How deep below a search root we still look for `.app` bundles.
    private let maximumDepth: Int

    init(searchPaths: [URL] = AppScanner.defaultSearchPaths, maximumDepth: Int = 3) {
        self.searchPaths = searchPaths
        self.maximumDepth = maximumDepth
    }

    // MARK: Scanning

    /// Scans every search path. Runs off the main thread — call from a background task.
    func scan() -> [DiscoveredApplication] {
        var found: [String: DiscoveredApplication] = [:]

        for root in searchPaths {
            for bundleURL in enumeratorBundles(in: root) {
                guard let app = AppScanner.makeDiscoveredApplication(from: bundleURL) else { continue }
                // Prefer the first hit; duplicates across roots keep the earliest path.
                if found[app.bundleIdentifier] == nil {
                    found[app.bundleIdentifier] = app
                }
            }
        }

        return found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func enumeratorBundles(in root: URL) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .nameKey]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return results
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if url.pathExtension == "app", values.isPackage == true || values.isDirectory == true {
                results.append(url)
                enumerator.skipDescendants()
                continue
            }

            // Depth guard for plain directories.
            let depth = url.pathComponents.count - root.pathComponents.count
            if values.isDirectory == true, depth >= maximumDepth {
                enumerator.skipDescendants()
            }
        }

        return results
    }

    // MARK: Single bundle

    /// Builds metadata for one `.app`. Also used by NSOpenPanel and drag & drop.
    static func makeDiscoveredApplication(from bundleURL: URL) -> DiscoveredApplication? {
        guard bundleURL.pathExtension == "app" else { return nil }
        guard let bundle = Bundle(url: bundleURL) else { return nil }

        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        let executableURL = bundle.executableURL

        let info = bundle.infoDictionary ?? [:]
        let rawName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""

        let runtime = AppDetector.detect(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL
        )

        return DiscoveredApplication(
            name: rawName,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundleURL.path,
            executablePath: executableURL?.path ?? "",
            version: version,
            runtime: runtime
        )
    }

    // MARK: Icons

    private static let iconCache = NSCache<NSString, NSImage>()

    /// Icons are resolved lazily and cached by bundle path.
    static func icon(for bundlePath: String) -> NSImage {
        if let cached = iconCache.object(forKey: bundlePath as NSString) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        iconCache.setObject(image, forKey: bundlePath as NSString)
        return image
    }
}
