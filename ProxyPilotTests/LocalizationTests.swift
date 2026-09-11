//
//  LocalizationTests.swift
//  ProxyPilotTests
//
//  Guards the Simplified Chinese localisation.
//
//  Xcode compiles Localizable.xcstrings into <lang>.lproj/Localizable.strings, so
//  the tests read the compiled table out of the host bundle. That catches the two
//  failure modes that are otherwise invisible: a key that was never translated,
//  and a translation whose format placeholders no longer match the source.
//

import XCTest
@testable import ProxyPilot

final class LocalizationTests: XCTestCase {

    private static let simplifiedChinese = "zh-Hans"

    // MARK: Helpers

    /// The compiled `zh-Hans` table from the host app bundle.
    private func chineseTable() throws -> [String: String] {
        // The tests are hosted by the app, so its resources live in Bundle.main.
        for bundle in [Bundle.main, Bundle(for: LocalizationTests.self)] {
            guard let path = bundle.path(forResource: Self.simplifiedChinese, ofType: "lproj") else { continue }
            let tableURL = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
            guard let data = try? Data(contentsOf: tableURL),
                  let table = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: String]
            else { continue }
            return table
        }
        throw XCTSkip("\(Self.simplifiedChinese).lproj/Localizable.strings was not found in the built bundle")
    }

    private func catalog() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)          // .../ProxyPilotTests/LocalizationTests.swift
            .deletingLastPathComponent()                     // .../ProxyPilotTests
            .deletingLastPathComponent()                     // repository root
        let url = root.appendingPathComponent("managerproxy/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["strings"] as? [String: Any], "catalog has no strings table")
    }

    /// Captures the conversion specifier only, so "%2$lld" and "%lld" both compare
    /// as "lld" and the positional index does not matter.
    private static let placeholderPattern = try! NSRegularExpression(
        pattern: "%(?:\\d+\\$)?([@a-zA-Z]+)"
    )

    private func placeholders(in value: String) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        return Self.placeholderPattern.matches(in: value, range: range).compactMap { match in
            guard let specifierRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[specifierRange])
        }.sorted()
    }

    // MARK: The catalog ships and is complete

    func testSimplifiedChineseIsCompiledIntoTheBundle() throws {
        let table = try chineseTable()
        XCTAssertFalse(table.isEmpty, "the zh-Hans table is empty")
    }

    func testEveryCatalogKeyHasChineseText() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 100, "the catalog looks suspiciously small")

        var missing: [String] = []
        var untranslated: [String] = []

        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let chinese = localizations[Self.simplifiedChinese] as? [String: Any],
                  let unit = chinese["stringUnit"] as? [String: Any],
                  let text = unit["value"] as? String
            else {
                missing.append(key)
                continue
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append(key)
            }
            // A translation that is byte-identical to the English source is almost
            // always a key that was added but never actually translated. Product
            // names and protocol names are the deliberate exceptions.
            if text == key, !Self.isIntentionalIdentity(text) {
                untranslated.append(key)
            }
        }

        XCTAssertTrue(missing.isEmpty, "keys without a zh-Hans value: \(missing.sorted())")
        XCTAssertTrue(untranslated.isEmpty, "keys left untranslated: \(untranslated.sorted())")
    }

    /// Strings that are the same in Chinese on purpose.
    private static func isIntentionalIdentity(_ key: String) -> Bool {
        let allowed: Set<String> = [
            "HTTP", "Bundle ID", "Chromium", "Electron", "ProxyPilot"
        ]
        if allowed.contains(key) { return true }
        // Pure placeholder / punctuation keys carry no words to translate.
        return key.rangeOfCharacter(from: .letters) == nil
    }

    func testFormatPlaceholdersSurviveTranslation() throws {
        let strings = try catalog()
        var mismatched: [(String, String)] = []

        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let chinese = localizations[Self.simplifiedChinese] as? [String: Any],
                  let unit = chinese["stringUnit"] as? [String: Any],
                  let text = unit["value"] as? String
            else { continue }

            let source = placeholders(in: key)
            guard !source.isEmpty else { continue }
            if placeholders(in: text) != source {
                mismatched.append((key, text))
            }
        }

        XCTAssertTrue(
            mismatched.isEmpty,
            "placeholder count/type differs from the source: \(mismatched.map(\.0).sorted())"
        )
    }

    // MARK: Spot checks of the compiled table

    func testCompiledTableContainsKeyTranslations() throws {
        let table = try chineseTable()
        let expected: [String: String] = [
            "Applications": "应用",
            "Proxies": "代理",
            "Restart Required": "需要重启",
            "Proxy Unavailable": "代理不可用",
            "Master switch is off": "总开关已关闭",
            "Add Application": "添加应用",
            "Reveal in Finder": "在访达中显示",
            "Show Menu Bar Icon": "显示菜单栏图标"
        ]
        for (key, value) in expected {
            XCTAssertEqual(table[key], value, "wrong or missing translation for “\(key)”")
        }
    }

    func testProtocolAndTechnicalNamesStayVerbatim() throws {
        let table = try chineseTable()
        // Protocol names are identifiers, not prose — translating them would break
        // copy/paste into proxy client configs.
        XCTAssertEqual(table["HTTP"], "HTTP")
        XCTAssertEqual(table["Bundle ID"], "Bundle ID")
        // Diagnostics log bodies are deliberately English-only, so they must not
        // appear in the catalogue at all.
        XCTAssertNil(table["Seeded default proxy profiles"])
        XCTAssertNil(table["Proxy available"])
    }

    // MARK: Runtime switching

    func testLocaleOverrideSwitchesModelStrings() {
        let direct = ProxyProfile.direct

        Localized.localeOverride = Locale(identifier: "en")
        XCTAssertEqual(direct.displayName, "Direct")

        Localized.localeOverride = Locale(identifier: Self.simplifiedChinese)
        XCTAssertEqual(direct.displayName, "直连")

        Localized.localeOverride = nil
    }

    func testStatusLabelsAreLocalised() {
        Localized.localeOverride = Locale(identifier: Self.simplifiedChinese)
        XCTAssertEqual(AppProxyStatus.restartRequired.label, "需要重启")
        XCTAssertEqual(AppProxyStatus.active.label, "已生效")
        Localized.localeOverride = nil
    }

    func testFormatArgumentsAreApplied() {
        Localized.localeOverride = Locale(identifier: Self.simplifiedChinese)
        let text = Localized.format("%@ is currently running.", "Codex")
        XCTAssertTrue(text.contains("Codex"), "the argument was dropped: \(text)")
        XCTAssertTrue(text.contains("正在运行"), "translation not applied: \(text)")
        Localized.localeOverride = nil
    }
}
