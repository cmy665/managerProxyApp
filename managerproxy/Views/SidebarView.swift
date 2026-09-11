//
//  SidebarView.swift
//  ProxyPilot
//

import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var state: AppState

    private var primaryItems: [SidebarSelection] {
        [.applications, .proxies, .settings]
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            List(selection: $state.selection) {
                Section {
                    ForEach(primaryItems) { item in
                        Label(item.title, systemImage: item.symbolName)
                            .font(.system(size: 12.5))
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Hairline()
            diagnosticsRow
        }
        .frame(minWidth: Theme.sidebarWidth)
        .navigationSplitViewColumnWidth(min: Theme.sidebarWidth, ideal: Theme.sidebarWidth, max: 260)
    }

    // MARK: Brand

    private var brandHeader: some View {
        HStack(spacing: 9) {
            // The real logo, shipped as an asset so it always matches the app icon.
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("ProxyPilot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Per-App Proxy")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Diagnostics

    private var diagnosticsRow: some View {
        Button {
            state.selection = .diagnostics
        } label: {
            HStack(spacing: 8) {
                Image(systemName: SidebarSelection.diagnostics.symbolName)
                    .font(.system(size: 12.5))
                Text(SidebarSelection.diagnostics.title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.selection == .diagnostics ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state.selection == .diagnostics ? Theme.blue : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}
