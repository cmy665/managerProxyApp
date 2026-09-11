//
//  ApplicationListView.swift
//  ProxyPilot
//

import SwiftUI

struct ApplicationListView: View {

    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var isAddSheetPresented = false

    // Column widths shared by the header and the rows.
    private enum Column {
        static let bundleID: CGFloat = 200
        static let proxy: CGFloat = 176
        static let status: CGFloat = 158
        static let actions: CGFloat = 30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            content
        }
        .inspector(isPresented: $state.isInspectorPresented) {
            inspectorContent
                .inspectorColumnWidth(min: 300, ideal: Theme.inspectorWidth, max: 420)
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddApplicationsSheet(isPresented: $isAddSheetPresented)
                .environmentObject(state)
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            title: "Applications",
            subtitle: "Manage proxy settings for each application."
        ) {
            SearchField(placeholder: "Search applications…", text: $searchText)
            Button {
                isAddSheetPresented = true
            } label: {
                Label("Add Application", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.applications.isEmpty {
            EmptyStateView(
                systemImage: "square.grid.2x2",
                title: "No applications yet",
                message: "Add the apps you want to route through a proxy. ProxyPilot never touches other apps or your system-wide settings.",
                actionTitle: "Add Application",
                action: { isAddSheetPresented = true }
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    TableHeaderRow {
                        HStack(spacing: 10) {
                            Text("Application")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Bundle ID")
                                .frame(width: Column.bundleID, alignment: .leading)
                            Text("Proxy")
                                .frame(width: Column.proxy, alignment: .leading)
                            Text("Status")
                                .frame(width: Column.status, alignment: .leading)
                            Text("")
                                .frame(width: Column.actions)
                        }
                    }

                    ForEach(filteredApplications) { app in
                        ApplicationRowView(
                            app: app,
                            bundleIDWidth: Column.bundleID,
                            proxyWidth: Column.proxy,
                            statusWidth: Column.status,
                            actionsWidth: Column.actions,
                            isSelected: state.selectedApplicationID == app.id
                        )
                        Hairline()
                    }

                    footer
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Localized.format("%lld of %lld applications",
                                 filteredApplications.count,
                                 state.applications.count))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let lastScan = state.lastScanDate {
                Text(Localized.format("Last scan %@", Format.relative(lastScan)))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if let app = state.application(withID: state.selectedApplicationID ?? UUID()) {
            ApplicationDetailView(app: app)
                .environmentObject(state)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an application to inspect it")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Filtering

    private var filteredApplications: [ManagedApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.applications }
        return state.applications.filter { app in
            app.name.lowercased().contains(query)
                || app.bundleIdentifier.lowercased().contains(query)
                || app.bundlePath.lowercased().contains(query)
                || state.proxyForDisplay(app).lowercased().contains(query)
        }
    }
}
