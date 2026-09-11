//
//  ProxyRule.swift
//  ProxyPilot
//
//  Phase 1 only persists the model — no domain-flow interception is implemented.
//  The type exists so Phase 2/3 can be added without a data migration.
//

import Foundation

// MARK: - RuleAction

enum RuleAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case proxy
    case direct
    case block

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxy:  return "PROXY"
        case .direct: return "DIRECT"
        case .block:  return "BLOCK"
        }
    }
}

// MARK: - RuleMatchKind

enum RuleMatchKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case domain
    case domainSuffix
    case ip
    case cidr
    case process
    case bundleID
    case port

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .domain:       return "DOMAIN"
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .ip:           return "IP"
        case .cidr:         return "CIDR"
        case .process:      return "PROCESS"
        case .bundleID:     return "BUNDLE-ID"
        case .port:         return "PORT"
        }
    }
}

// MARK: - ProxyRule

struct ProxyRule: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    var appID: UUID?

    var domain: String?

    var matchKind: RuleMatchKind

    var action: RuleAction

    var proxyProfileID: UUID?

    var priority: Int

    var enabled: Bool

    var createdAt: Date

    init(
        id: UUID = UUID(),
        appID: UUID? = nil,
        domain: String? = nil,
        matchKind: RuleMatchKind = .domain,
        action: RuleAction = .proxy,
        proxyProfileID: UUID? = nil,
        priority: Int = 0,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.domain = domain
        self.matchKind = matchKind
        self.action = action
        self.proxyProfileID = proxyProfileID
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, appID, domain, matchKind, action, proxyProfileID, priority, enabled, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        appID = try c.decodeIfPresent(UUID.self, forKey: .appID)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        matchKind = try c.decodeIfPresent(RuleMatchKind.self, forKey: .matchKind) ?? .domain
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action) ?? .proxy
        proxyProfileID = try c.decodeIfPresent(UUID.self, forKey: .proxyProfileID)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
