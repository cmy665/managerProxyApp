//
//  ProxyPilotError.swift
//  ProxyPilot
//
//  Unified, user-facing error model. UI never shows raw error codes.
//

import Foundation

enum ProxyPilotError: LocalizedError {
    case appNotFound(name: String)
    case executableNotFound(path: String)
    case proxyUnavailable(address: String)
    case launchFailed(name: String, reason: String)
    case terminationFailed(name: String)
    case forceTerminationDeclined(name: String)
    case invalidProxyConfiguration(reason: String)
    case unsupportedLaunchStrategy(strategy: String)
    case persistenceFailed(reason: String)
    case keychainFailed(reason: String)
    case masterSwitchDisabled
    case noProxySelected
    case duplicateApplication(name: String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return Localized.format("%@ could not be found on disk.", name)
        case .executableNotFound(let path):
            return Localized.format("The application executable could not be found at %@.", path)
        case .proxyUnavailable(let address):
            return Localized.format("The proxy %@ is not reachable.", address)
        case .launchFailed(let name, _):
            return Localized.format("Unable to start %@ with proxy.", name)
        case .terminationFailed(let name):
            return Localized.format("%@ did not quit in time.", name)
        case .forceTerminationDeclined(let name):
            return Localized.format("%@ is still running.", name)
        case .invalidProxyConfiguration(let reason):
            return Localized.format("The proxy configuration is invalid: %@", reason)
        case .unsupportedLaunchStrategy(let strategy):
            return Localized.format("The %@ launch strategy is not available for this application.", strategy)
        case .persistenceFailed(let reason):
            return Localized.format("Settings could not be saved: %@", reason)
        case .keychainFailed(let reason):
            return Localized.format("The credential could not be stored securely: %@", reason)
        case .masterSwitchDisabled:
            return Localized.string("ProxyPilot is switched off. Turn the master switch on to launch apps with a proxy.")
        case .noProxySelected:
            return Localized.string("No proxy is assigned to this application.")
        case .duplicateApplication(let name):
            return Localized.format("%@ has already been added.", name)
        }
    }

    /// A secondary sentence that tells the user what to do next.
    var recoverySuggestion: String? {
        switch self {
        case .proxyUnavailable:
            return Localized.string("Check that your proxy client (FlClash, Clash, Surge…) is running and listening on this address.")
        case .appNotFound, .executableNotFound:
            return Localized.string("The application may have been moved or uninstalled. Remove it and add it again.")
        case .launchFailed:
            return Localized.string("Test the proxy connection, then try again.")
        case .terminationFailed:
            return Localized.string("You can force quit the app, but unsaved work may be lost.")
        case .masterSwitchDisabled:
            return Localized.string("Enable the master switch in the toolbar.")
        case .keychainFailed:
            return Localized.string("ProxyPilot stores credentials in the macOS Keychain. Check Keychain Access permissions.")
        default:
            return nil
        }
    }

    /// Underlying technical detail, shown only in Diagnostics.
    var technicalDetail: String? {
        switch self {
        case .launchFailed(_, let reason):        return reason
        case .persistenceFailed(let reason):      return reason
        case .keychainFailed(let reason):         return reason
        case .invalidProxyConfiguration(let r):   return r
        default:                                   return nil
        }
    }
}

// MARK: - Presentation

struct ErrorPresentation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?
    let offersProxyTest: Bool
    let offersProxySettings: Bool

    init(error: ProxyPilotError) {
        self.title = error.errorDescription ?? Localized.string("Something went wrong.")
        self.message = error.technicalDetail.map { Localized.format("Technical detail: %@", $0) } ?? ""
        self.suggestion = error.recoverySuggestion
        switch error {
        case .proxyUnavailable, .launchFailed:
            self.offersProxyTest = true
            self.offersProxySettings = true
        default:
            self.offersProxyTest = false
            self.offersProxySettings = false
        }
    }

    init(title: String, message: String = "", suggestion: String? = nil) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.offersProxyTest = false
        self.offersProxySettings = false
    }
}
