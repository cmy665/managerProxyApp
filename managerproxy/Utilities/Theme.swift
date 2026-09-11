//
//  Theme.swift
//  ProxyPilot
//
//  Brand palette + shared visual constants. Surfaces use semantic NSColors so the
//  app follows the system appearance, while the brand blue stays constant.
//

import SwiftUI

enum Theme {

    // MARK: Brand

    static let blue = Color(red: 0.176, green: 0.482, blue: 0.957)
    static let blueSoft = Color(red: 0.878, green: 0.925, blue: 0.996)

    // MARK: Status

    static let active = Color(red: 0.204, green: 0.702, blue: 0.373)
    static let warning = Color(red: 0.937, green: 0.596, blue: 0.114)
    static let danger = Color(red: 0.882, green: 0.278, blue: 0.259)
    static let neutral = Color.secondary

    // MARK: Surfaces

    static let cardCornerRadius: CGFloat = 10
    static let rowCornerRadius: CGFloat = 8

    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var tableHeaderBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }

    // MARK: Metrics

    static let sidebarWidth: CGFloat = 208
    static let rowHeight: CGFloat = 56
    static let inspectorWidth: CGFloat = 340
    static let contentPadding: CGFloat = 22

    // MARK: Fonts

    static let sectionTitle = Font.system(size: 20, weight: .semibold)
    static let sectionSubtitle = Font.system(size: 12)
    static let tableHeaderFont = Font.system(size: 11, weight: .semibold)
    static let appNameFont = Font.system(size: 13, weight: .semibold)
    static let monoCaption = Font.system(size: 11, design: .monospaced)
    static let caption = Font.system(size: 11)
    static let body = Font.system(size: 12)
}

// MARK: - Status colors

extension AppProxyStatus {
    var color: Color {
        switch self {
        case .active:               return Theme.active
        case .disabled:             return Theme.neutral
        case .direct:               return Theme.neutral
        case .restartRequired:      return Theme.warning
        case .proxyUnavailable:     return Theme.danger
        case .configurationMissing: return Theme.danger
        }
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .debug:   return Theme.neutral
        case .info:    return Theme.blue
        case .success: return Theme.active
        case .warning: return Theme.warning
        case .error:   return Theme.danger
        }
    }
}

extension ProxyHealth {
    var color: Color {
        guard hasBeenTested else { return Theme.neutral }
        if isFullyAvailable { return Theme.active }
        if isReachable { return Theme.warning }
        return Theme.danger
    }

    var statusLabel: String {
        guard hasBeenTested else { return Localized.string("Not tested") }
        if isFullyAvailable { return Localized.string("Available") }
        if isReachable { return Localized.string("Degraded") }
        return Localized.string("Unavailable")
    }
}
