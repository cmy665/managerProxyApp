//
//  SNIHelper.swift
//  ProxyPilotTransparentProxy
//
//  Recovers the original hostname from the first bytes of a TCP connection
//  so the relay can use domain-based routing through upstream proxies that
//  reject raw-IP connections (common for geo-DNS, SNI-based vhosts, and
//  corporate proxies).
//
//  Two protocols are recognised:
//    - TLS  : parse the ClientHello's SNI extension (type 0x0000)
//    - HTTP : parse the "Host:" request header
//
//  Anything else returns nil and the caller falls back to the IP address.
//

import Foundation

enum SNIHelper {

    /// Attempts to extract a hostname from the first bytes of a client→server
    /// TCP stream. Returns nil when the data is not TLS or HTTP, or when no
    /// hostname is present.
    static func hostname(fromFirstBytes data: Data) -> String? {
        if let sni = parseTLSClientHelloSNI(data) {
            return sni
        }
        if let host = parseHTTPHost(data) {
            return host
        }
        return nil
    }

    // MARK: - TLS ClientHello SNI

    private static func parseTLSClientHelloSNI(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }

        // TLS record: ContentType=0x16 (Handshake), version 0x0301+.
        guard bytes[0] == 0x16,
              bytes[1] == 0x03,
              bytes[2] >= 0x01 else {
            return nil
        }

        // Handshake header starts at offset 5: msg_type(1) + length(3).
        let handshakeOffset = 5
        guard bytes.count > handshakeOffset + 4 else { return nil }
        // ClientHello = 0x01.
        guard bytes[handshakeOffset] == 0x01 else { return nil }

        // ClientHello body starts at handshakeOffset + 4 (msg_type + 3-byte length).
        var pos = handshakeOffset + 4
        guard bytes.count > pos + 2 + 32 else { return nil }

        // Skip client_version (2) + random (32).
        pos += 2 + 32

        // Skip session_id.
        guard pos < bytes.count else { return nil }
        let sessionIDLen = Int(bytes[pos])
        pos += 1 + sessionIDLen

        // Skip cipher_suites.
        guard pos + 2 <= bytes.count else { return nil }
        let cipherSuitesLen = Int(UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1]))
        pos += 2 + cipherSuitesLen

        // Skip compression_methods.
        guard pos + 1 <= bytes.count else { return nil }
        let compressionLen = Int(bytes[pos])
        pos += 1 + compressionLen

        // Extensions length.
        guard pos + 2 <= bytes.count else { return nil }
        let extensionsLen = Int(UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1]))
        pos += 2

        let extensionsEnd = pos + extensionsLen
        while pos + 4 <= bytes.count && pos < extensionsEnd {
            let extType = UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
            let extDataLen = Int(UInt16(bytes[pos + 2]) << 8 | UInt16(bytes[pos + 3]))
            pos += 4
            if extType == 0x0000 {
                // SNI extension.
                return parseSNIExtension(bytes: bytes, offset: pos, length: extDataLen)
            }
            pos += extDataLen
        }
        return nil
    }

    private static func parseSNIExtension(bytes: [UInt8], offset: Int, length: Int) -> String? {
        guard offset + 2 <= bytes.count, offset + length <= bytes.count else { return nil }
        // server_name_list_length (2 bytes).
        var pos = offset + 2
        while pos + 3 <= bytes.count && pos < offset + length {
            let nameType = bytes[pos]
            let nameLen = Int(UInt16(bytes[pos + 1]) << 8 | UInt16(bytes[pos + 2]))
            pos += 3
            guard nameType == 0x00 else {
                pos += nameLen
                continue
            }
            guard pos + nameLen <= bytes.count else { return nil }
            if let name = String(bytes: bytes[pos..<pos + nameLen], encoding: .utf8),
               !name.isEmpty {
                return name
            }
            return nil
        }
        return nil
    }

    // MARK: - HTTP Host header

    private static func parseHTTPHost(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Must look like an HTTP request line.
        let methods = ["GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "CONNECT ", "OPTIONS ", "PATCH "]
        guard methods.contains(where: { text.hasPrefix($0) }) else { return nil }
        // Find "Host: " header.
        guard let range = text.range(of: "\r\nHost: ", options: .caseInsensitive) else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.range(of: "\r\n") else {
            // Host might be the last header (no trailing CRLF yet).
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}
