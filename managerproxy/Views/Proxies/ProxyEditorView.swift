//
//  ProxyEditorView.swift
//  ProxyPilot
//
//  Create / edit a proxy profile, with a real connection test.
//  The password is written to the Keychain — never to JSON.
//

import SwiftUI

struct ProxyEditorView: View {

    let original: ProxyProfile?
    let onCancel: () -> Void

    @EnvironmentObject private var state: AppState

    @State private var draft: ProxyProfile
    @State private var password: String
    @State private var isPasswordVisible = false
    @State private var validationMessage: String?
    @State private var testProfile: ProxyProfile?

    init(original: ProxyProfile?, existingPassword: String, onCancel: @escaping () -> Void) {
        self.original = original
        self.onCancel = onCancel
        _draft = State(initialValue: original ?? ProxyProfile(name: "", type: .http,
                                                               host: ProxyProfile.defaultHost,
                                                               port: ProxyProfile.defaultPort))
        _password = State(initialValue: existingPassword)
    }

    private var isNew: Bool { original == nil }

    private var testedProfile: ProxyProfile? { testProfile.map { _ in draft } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    nameField
                    typeField
                    hostField
                    portField
                    authenticationSection
                    Hairline()
                    testSection
                }
                .padding(16)
            }
            Hairline()
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Sections

    private var title: some View {
        HStack {
            Text(isNew ? "Add Proxy" : "Edit Proxy")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !isNew {
                Text(draft.type.displayName)
                    .font(Theme.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var nameField: some View {
        FormRow(label: "Name") {
            TextField("FlClash", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.body)
        }
    }

    private var typeField: some View {
        FormRow(label: "Type") {
            Picker("", selection: $draft.type) {
                ForEach(ProxyType.selectable) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var hostField: some View {
        FormRow(label: "Host") {
            TextField("127.0.0.1", text: $draft.host)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var portField: some View {
        FormRow(label: "Port", hint: draft.validationError?.errorDescription) {
            TextField("\(ProxyProfile.defaultPort)", value: $draft.port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 110)
        }
    }

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                PanelSectionTitle(text: "Authentication")
                Text("Optional")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            FormRow(label: "Username") {
                TextField("Enter username", text: Binding(
                    get: { draft.username ?? "" },
                    set: { draft.username = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(Theme.body)
            }

            FormRow(label: "Password") {
                HStack(spacing: 6) {
                    Group {
                        if isPasswordVisible {
                            TextField("Enter password", text: $password)
                        } else {
                            SecureField("Enter password", text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.body)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isPasswordVisible ? "Hide password" : "Show password")
                }
            }

            Text("Stored in the macOS Keychain — never in a JSON file or the log.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                Task { await runTest() }
            } label: {
                HStack(spacing: 6) {
                    if state.testingProxyIDs.contains(draft.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(state.testingProxyIDs.contains(draft.id) ? "Testing…" : "Test Connection")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(draft.validationError != nil || state.testingProxyIDs.contains(draft.id))

            if let message = validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }

            if draft.validationError == nil, state.health(for: draft).hasBeenTested {
                testResult(state.health(for: draft))
            }
        }
    }

    private func testResult(_ health: ProxyHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusPill(
                    text: health.isFullyAvailable
                        ? Localized.string("Proxy Available")
                        : health.statusLabel,
                    color: health.color,
                    systemImage: health.isFullyAvailable ? "checkmark" : nil
                )
                Spacer(minLength: 0)
            }

            if health.isFullyAvailable {
                VStack(alignment: .leading, spacing: 3) {
                    resultRow(Localized.string("Connection"), Format.latency(health.tcpLatencyMs))
                    resultRow(Localized.string("HTTP"), Format.latency(health.httpLatencyMs))
                    resultRow(Localized.string("Status"), health.statusCode.map(String.init) ?? "—")
                }
            } else if let reason = health.failureReason {
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(health.color.opacity(0.08))
        )
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(SecondaryButtonStyle())
            Button(isNew ? "Add Proxy" : "Save") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.validationError != nil)
        }
        .padding(12)
    }

    // MARK: Actions

    private func save() {
        guard draft.validationError == nil else { return }
        do {
            if isNew {
                try state.addProxy(
                    name: draft.name,
                    type: draft.type,
                    host: draft.host,
                    port: draft.port,
                    username: draft.username,
                    password: password
                )
                state.toast = Localized.string("Proxy added")
            } else {
                try state.updateProxy(draft, password: password)
                state.toast = Localized.string("Proxy saved")
            }
            onCancel()
        } catch let error as ProxyProfile.ValidationError {
            validationMessage = error.errorDescription
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func runTest() async {
        validationMessage = nil
        guard draft.validationError == nil else {
            validationMessage = draft.validationError?.errorDescription
            return
        }
        testProfile = draft
        await state.testProxy(draft)
    }
}
