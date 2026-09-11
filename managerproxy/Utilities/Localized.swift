//
//  Localized.swift
//  ProxyPilot
//
//  One place for user-facing strings that are produced *outside* a SwiftUI body.
//
//  SwiftUI resolves `Text("…")` against `Environment(\.locale)`. Strings built in
//  models and services (error messages, status labels, enum display names) have no
//  environment to read, so they go through here instead.
//
//  Two traps this type exists to avoid:
//
//   1. `String(localized:locale:)`'s `locale` argument only affects *formatting*
//      (plurals, number style). It does NOT select a translation — the lookup still
//      uses the bundle's preferred language. To pin a language you have to resolve
//      the matching `.lproj` bundle yourself, which is what `bundle(for:)` does.
//   2. `String.LocalizationValue` does not expose its key, so a runtime-selectable
//      path can't go through `String(localized:)` at all. These helpers take a plain
//      `String` key.
//
//  With no override the behaviour is the shipping one: follow the system language.
//

import Foundation

enum Localized {

    /// Set by tests or previews to pin a language. `nil` follows the system.
    static var localeOverride: Locale?

    private static var bundleCache: [String: Bundle] = [:]

    /// The `.lproj` bundle for `locale`, falling back to `Bundle.main`.
    private static func bundle(for locale: Locale) -> Bundle {
        let full = locale.identifier
        let language = String(full.prefix { $0 != "-" && $0 != "_" })

        for identifier in [full, language] where !identifier.isEmpty {
            if let cached = bundleCache[identifier] { return cached }
            guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            bundleCache[identifier] = bundle
            return bundle
        }
        return .main
    }

    private static var activeBundle: Bundle {
        guard let localeOverride else { return .main }
        return bundle(for: localeOverride)
    }

    /// Looks up `key`. A missing translation falls back to the key itself (English),
    /// which surfaces the gap in the UI instead of blanking it out.
    static func string(_ key: String) -> String {
        activeBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Looks up a format string and applies the arguments, so translators control
    /// word order through positional placeholders such as `%2$lld`.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
