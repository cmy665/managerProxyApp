//
//  ProxyProfileTests.swift
//  ProxyPilotTests
//

import XCTest
@testable import ProxyPilot

final class ProxyProfileTests: XCTestCase {

    // MARK: URL generation

    func testHTTPProxyURL() {
        let proxy = ProxyProfile(name: "FlClash", type: .http, host: "127.0.0.1", port: 7890)
        XCTAssertEqual(proxy.urlString, "http://127.0.0.1:7890")
    }

    func testHTTPSProxyURL() {
        let proxy = ProxyProfile(name: "Secure", type: .https, host: "10.0.0.5", port: 8443)
        XCTAssertEqual(proxy.urlString, "https://10.0.0.5:8443")
    }

    func testSOCKS5ProxyURL() {
        let proxy = ProxyProfile(name: "Local SOCKS", type: .socks5, host: "127.0.0.1", port: 1080)
        XCTAssertEqual(proxy.urlString, "socks5://127.0.0.1:1080")
    }

    func testDirectProfileHasNoURL() {
        XCTAssertNil(ProxyProfile.direct.urlString)
        XCTAssertTrue(ProxyProfile.direct.isDirect)
        XCTAssertTrue(ProxyProfile.direct.isBuiltIn)
        XCTAssertFalse(ProxyProfile.direct.displayName.isEmpty)
        XCTAssertEqual(ProxyProfile.direct.displayAddress, "—")
        // The English wording is asserted in LocalizationTests, where the locale can
        // be pinned; here we only check the value exists.
    }

    func testHTTPAndSOCKS5ShareTheSameDefaultPort() {
        XCTAssertEqual(ProxyProfile.defaultPort, 7890)
        XCTAssertEqual(ProxyProfile.defaultHost, "127.0.0.1")

        // A profile that fails to decode its port must land on the same default, so
        // both protocols agree out of the box.
        let json = #"{"name":"Bare"}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(ProxyProfile.self, from: json)
        XCTAssertEqual(decoded?.port, 7890)
        XCTAssertEqual(decoded?.host, "127.0.0.1")
    }

    func testSubtitleFormat() {
        let proxy = ProxyProfile(name: "FlClash", type: .http, host: "127.0.0.1", port: 7890)
        XCTAssertEqual(proxy.subtitle, "HTTP  127.0.0.1:7890")
    }

    // MARK: Validation

    func testValidProfilePassesValidation() {
        let proxy = ProxyProfile(name: "FlClash", type: .http, host: "127.0.0.1", port: 7890)
        XCTAssertNil(proxy.validationError)
        XCTAssertTrue(proxy.isValid)
    }

    func testEmptyNameIsRejected() {
        let proxy = ProxyProfile(name: "   ", type: .http, host: "127.0.0.1", port: 7890)
        XCTAssertEqual(proxy.validationError, .emptyName)
    }

    func testEmptyHostIsRejected() {
        let proxy = ProxyProfile(name: "A", type: .http, host: "  ", port: 7890)
        XCTAssertEqual(proxy.validationError, .emptyHost)
    }

    func testHostWithSlashIsRejected() {
        let proxy = ProxyProfile(name: "A", type: .http, host: "http://127.0.0.1", port: 7890)
        XCTAssertEqual(proxy.validationError, .invalidHost)
    }

    func testPortZeroIsRejected() {
        let proxy = ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 0)
        XCTAssertEqual(proxy.validationError, .invalidPort)
    }

    func testPortAboveRangeIsRejected() {
        let proxy = ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 65536)
        XCTAssertEqual(proxy.validationError, .invalidPort)
    }

    func testBoundaryPortsAreAccepted() {
        XCTAssertNil(ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 1).validationError)
        XCTAssertNil(ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 65535).validationError)
    }

    func testInvalidProfileHasNoURL() {
        let proxy = ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 70000)
        XCTAssertNil(proxy.urlString)
    }

    // MARK: Selectable types

    func testDirectIsNotUserSelectable() {
        XCTAssertFalse(ProxyType.selectable.contains(.direct))
        XCTAssertEqual(ProxyType.selectable, [.http, .https, .socks5])
    }

    // MARK: Decoding tolerance

    func testDecodingToleratesMissingKeys() throws {
        let json = #"{"name":"Bare"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProxyProfile.self, from: json)
        XCTAssertEqual(decoded.name, "Bare")
        XCTAssertEqual(decoded.host, "127.0.0.1")
        XCTAssertEqual(decoded.port, 7890)
        XCTAssertEqual(decoded.type, .http)
        XCTAssertTrue(decoded.enabled)
    }

    func testCodableRoundTrip() throws {
        let original = ProxyProfile(
            name: "Office",
            type: .socks5,
            host: "10.0.0.1",
            port: 1080,
            username: "alice",
            passwordKeychainID: "proxy.abc",
            enabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyProfile.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testPasswordIsNeverPartOfTheModel() throws {
        // With no credential the key is omitted entirely.
        let bare = ProxyProfile(name: "A", type: .http, host: "127.0.0.1", port: 7890)
        let bareJSON = String(data: try JSONEncoder().encode(bare), encoding: .utf8) ?? ""
        XCTAssertFalse(bareJSON.contains("\"password\""), "there must be no plaintext password field")
        XCTAssertFalse(bareJSON.contains("passwordKeychainID"))

        // With a credential only the Keychain *reference* is stored.
        var withCredential = bare
        withCredential.username = "alice"
        withCredential.passwordKeychainID = "proxy.11111111"
        let json = String(data: try JSONEncoder().encode(withCredential), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"password\""), "the secret must never be serialised")
        XCTAssertTrue(json.contains("passwordKeychainID"))
        XCTAssertTrue(json.contains("proxy.11111111"))
    }
}
