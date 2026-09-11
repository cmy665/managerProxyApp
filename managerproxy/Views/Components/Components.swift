//
//  Components.swift
//  ProxyPilot
//
//  Small reusable pieces shared by every screen.
//

import SwiftUI

// MARK: - Page header

/// Title + subtitle on the left, controls on the right — matches the design's
/// "Applications / Manage proxy settings for each application." header.
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.sectionTitle)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(Theme.sectionSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                trailing()
            }
            .fixedSize()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Search field

struct SearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var width: CGFloat = 210

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.blue.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Icon button

struct IconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Status indicators

/// Colored dot + text label. Status is never communicated by colour alone.
struct StatusIndicator: View {
    let status: AppProxyStatus
    var showsText: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            if showsText {
                Text(status.label)
                    .font(Theme.caption)
                    .foregroundStyle(status.isWarning ? status.color : .secondary)
            }
        }
        .help(status.label)
    }
}

/// Pill used by the proxy list and the connection test result.
struct StatusPill: View {
    let text: String
    let color: Color
    var systemImage: String?
    var isFilled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(isFilled ? .white : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(isFilled ? color : color.opacity(0.12))
        )
    }
}

// MARK: - Mono label

/// Monospaced secondary text, e.g. a bundle identifier or a host:port pair.
struct MonoLabel: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(Theme.monoCaption)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: - App icon

struct AppIconView: View {
    let bundlePath: String
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: AppScanner.icon(for: bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Table header

struct TableHeaderRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(Theme.tableHeaderFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tableHeaderBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
    }
}

// MARK: - Labelled form row

struct FormRow<Content: View>: View {
    let label: LocalizedStringKey
    /// Kept as a `String` because it also receives validation errors.
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.blue.opacity(0.65))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Section title inside panels

struct PanelSectionTitle: View {
    let text: LocalizedStringKey

    var body: some View {
        // `.textCase` upper-cases for display only, so the lookup still uses the
        // original key and translators keep control of the wording.
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Divider

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

// MARK: - Key / value row

struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            if monospaced {
                MonoLabel(text: value, color: .primary)
            } else {
                Text(value)
                    .font(Theme.body)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}
