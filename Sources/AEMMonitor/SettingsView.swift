import AppKit
import SwiftUI
import UserNotifications

/// Settings view for managing programs and environments.
struct SettingsView: View {
    @ObservedObject var model: EnvironmentModel

    // State for the "add program" form.
    @State private var newProgramName = ""
    @State private var newProgramId = ""

    // State for inline editing.
    @State private var editingProgramIndex: Int? = nil
    @State private var editProgramName = ""
    @State private var editProgramId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Button {
                    model.showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Helper text
                    Text("Configure your Cloud Manager programs and environments. Author URL pattern: author-p{programId}-e{envId}.adobeaemcloud.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    NotificationSettingsSection(model: model)

                    Divider()

                    CloudManagerAccountsSection(model: model)

                    Divider()

                    // Existing programs
                    ForEach(model.config.programs.indices, id: \.self) { pi in
                        ProgramSettingsCard(
                            model: model,
                            programIndex: pi,
                            isEditing: editingProgramIndex == pi,
                            editName: $editProgramName,
                            editId: $editProgramId,
                            onStartEdit: {
                                editingProgramIndex = pi
                                editProgramName = model.config.programs[pi].name
                                editProgramId = model.config.programs[pi].id
                            },
                            onSaveEdit: {
                                model.updateProgram(at: pi, name: editProgramName, id: editProgramId)
                                editingProgramIndex = nil
                            },
                            onCancelEdit: {
                                editingProgramIndex = nil
                            }
                        )
                    }

                    Divider()

                    // Add program form
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add Program")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 6) {
                            TextField("Name", text: $newProgramName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            TextField("Program ID", text: $newProgramId)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(width: 90)
                            Button("Add") {
                                let name = newProgramName.trimmingCharacters(in: .whitespaces)
                                let pid = newProgramId.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty, !pid.isEmpty else { return }
                                model.addProgram(name: name, id: pid)
                                newProgramName = ""
                                newProgramId = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newProgramName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newProgramId.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Notification Settings

struct NotificationSettingsSection: View {
    @ObservedObject var model: EnvironmentModel

    /// Binding that writes through to config.json on every change.
    @MainActor
    private func binding<T>(_ keyPath: WritableKeyPath<NotificationSettings, T>) -> Binding<T> {
        Binding(
            get: { model.notificationSettings[keyPath: keyPath] },
            set: { newValue in model.updateNotificationSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications")
                .font(.subheadline.weight(.semibold))

            Toggle("Notify when a watched environment changes", isOn: binding(\.enabled))
                .font(.caption)

            Group {
                Picker("Notify on", selection: binding(\.mode)) {
                    Text("Every status change").tag(NotifyMode.allChanges)
                    Text("Only when it's up").tag(NotifyMode.wakeOnly)
                }
                .pickerStyle(.radioGroup)
                .font(.caption)

                Toggle("Play sound", isOn: binding(\.sound))
                    .font(.caption)

                Toggle("Keep watching after it's up (report re-hibernation)", isOn: binding(\.keepWatchingWhenUp))
                    .font(.caption)

                Toggle("Pipelines: also notify at each step (approvals and results always notify)", isOn: binding(\.pipelineSteps))
                    .font(.caption)
            }
            .disabled(!model.notificationSettings.enabled)

            HStack(spacing: 8) {
                permissionLabel
                Spacer()
                Button("Send Test") { model.sendTestNotification() }
                    .controlSize(.small)
            }

            diagnostics
        }
        .onAppear { model.refreshNotificationAuthorization() }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Always-visible status so a failure is never silent.
    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let err = model.lastNotificationError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canUseNotificationCenter,
               model.notificationAuthorization == .authorized,
               model.notificationAlertStyle == .none {
                HStack(spacing: 4) {
                    Text("Allowed, but banner style is None: notifications go to Notification Center only.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Fix") { openNotificationSettings() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            if let sent = model.lastNotificationSent {
                Text("Last sent to macOS: \(sent.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var permissionLabel: some View {
        if !model.canUseNotificationCenter {
            Text("Running via swift run: sound + log only. Use build-app.sh for banners.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            switch model.notificationAuthorization {
            case .denied:
                HStack(spacing: 4) {
                    Text("Blocked in System Settings.")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Button("Open") { openNotificationSettings() }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            case .notDetermined:
                Button("Allow Notifications") { model.requestNotificationPermission() }
                    .buttonStyle(.link)
                    .font(.caption2)
            case .authorized, .provisional:
                Text("Allowed")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            default:
                Text("Permission state \(model.notificationAuthorization.rawValue)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Program Settings Card

/// Displays one program with its environments and inline CRUD controls.
struct ProgramSettingsCard: View {
    @ObservedObject var model: EnvironmentModel
    let programIndex: Int
    let isEditing: Bool
    @Binding var editName: String
    @Binding var editId: String
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void

    // Add environment form state (local to each card).
    @State private var newEnvName = ""
    @State private var newEnvId = ""

    // Inline environment editing.
    @State private var editingEnvIndex: Int? = nil
    @State private var editEnvName = ""
    @State private var editEnvId = ""

    private var program: ProgramConfig {
        model.config.programs[programIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Program header row
            if isEditing {
                HStack(spacing: 6) {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    TextField("ID", text: $editId)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 80)
                    Button {
                        onSaveEdit()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    Button {
                        onCancelEdit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    Text("\(program.name)")
                        .font(.subheadline.weight(.semibold))
                    Text("(\(program.id))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        onStartEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    Button {
                        model.removeProgram(at: programIndex)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }

            // Status source
            Picker("Status from", selection: Binding(
                get: { program.accountId ?? "" },
                set: { model.setAccount($0.isEmpty ? nil : $0, forProgramAt: programIndex) }
            )) {
                Text("Login page check (no credentials)").tag("")
                ForEach(model.config.accounts) { a in
                    Text("Cloud Manager API: \(a.label)").tag(a.id)
                }
            }
            .font(.caption)
            .padding(.leading, 12)

            // Environment list
            ForEach(program.environments.indices, id: \.self) { ei in
                if editingEnvIndex == ei {
                    // Inline edit row
                    HStack(spacing: 6) {
                        TextField("Name", text: $editEnvName)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        TextField("Env ID", text: $editEnvId)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 80)
                        Button {
                            let n = editEnvName.trimmingCharacters(in: .whitespaces)
                            let eid = editEnvId.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty, !eid.isEmpty else { return }
                            model.updateEnvironment(programAt: programIndex, envAt: ei, name: n, id: eid)
                            editingEnvIndex = nil
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        Button {
                            editingEnvIndex = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 12)
                } else {
                    HStack(spacing: 6) {
                        Text("  \(program.environments[ei].name)")
                            .font(.system(.caption, design: .monospaced))
                        Text("(\(program.environments[ei].id))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            editingEnvIndex = ei
                            editEnvName = program.environments[ei].name
                            editEnvId = program.environments[ei].id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        Button {
                            model.removeEnvironment(programAt: programIndex, envAt: ei)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                    .padding(.leading, 12)
                }
            }

            // Add environment row
            HStack(spacing: 6) {
                TextField("Env name", text: $newEnvName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                TextField("Env ID", text: $newEnvId)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 80)
                Button {
                    let n = newEnvName.trimmingCharacters(in: .whitespaces)
                    let eid = newEnvId.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !eid.isEmpty else { return }
                    model.addEnvironment(toProgramAt: programIndex, name: n, id: eid)
                    newEnvName = ""
                    newEnvId = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.green)
                .disabled(newEnvName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newEnvId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 12)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}


// MARK: - Cloud Manager API credentials

/// OAuth Server-to-Server credentials from Adobe Developer Console. Client
/// id, org id and scopes go in config.json; the client secret goes in the
/// macOS Keychain only.
struct CloudManagerAccountsSection: View {
    @ObservedObject var model: EnvironmentModel

    @State private var editingId: String? = nil   // "new" for the add form
    @State private var label = ""
    @State private var clientId = ""
    @State private var orgId = ""
    @State private var scopes = CloudManagerAccount.defaultScopes
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cloud Manager API")
                .font(.subheadline.weight(.semibold))
            Text("Matches Cloud Manager's status exactly (including Restarting) and enables pipeline watching. Needs an OAuth Server-to-Server credential with the Cloud Manager API and the Developer product profile, from Adobe Developer Console. One credential per IMS org. The client secret is stored in the macOS Keychain.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.config.accounts) { a in
                if editingId == a.id {
                    form(existing: a)
                } else {
                    accountRow(a)
                }
            }

            if editingId == "new" {
                form(existing: nil)
            } else if editingId == nil {
                Button("Add Credential") { begin(nil) }
                    .controlSize(.small)
            }
        }
    }

    private func accountRow(_ a: CloudManagerAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(a.label).font(.caption.weight(.semibold))
                Text(model.hasSecret(a.id) ? "secret in Keychain" : "no secret" as String)
                    .font(.caption2)
                    .foregroundColor(model.hasSecret(a.id) ? Color.secondary : Color.red)
                Spacer()
                if model.accountBusy.contains(a.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { model.testAccount(a.id) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
                Button { begin(a) } label: { Image(systemName: "pencil").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Button { model.removeAccount(a.id) } label: { Image(systemName: "trash").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
            }
            Text("Org \(a.orgId)")
                .font(.caption2)
                .foregroundColor(.secondary)
            if let result = model.accountTestResult[a.id] {
                Text(result)
                    .font(.caption2)
                    .foregroundColor(result.hasPrefix("Failed") || result.contains("NOT available") ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let programs = model.accountPrograms[a.id], !programs.isEmpty {
                Text("Programs this credential can see:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(programs) { p in
                    HStack(spacing: 6) {
                        Text("\(p.name) (\(p.id))").font(.caption2)
                        Spacer()
                        let linked = model.config.programs.first(where: { $0.id == p.id })
                        if linked?.accountId == a.id {
                            Text("added").font(.caption2).foregroundColor(.secondary)
                        } else {
                            let title: String = linked == nil ? "Add" : "Use API"
                            Button(title) {
                                model.importProgram(p, accountId: a.id)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(model.accountBusy.contains(a.id))
                        }
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func form(existing: CloudManagerAccount?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label (e.g. foxx org)", text: $label)
            TextField("Client ID (API key)", text: $clientId)
            SecureField(existing == nil ? "Client secret" : "Client secret (leave blank to keep)" as String, text: $secret)
            TextField("Organization ID (…@AdobeOrg)", text: $orgId)
            TextField("Scopes (comma-separated, from Developer Console)", text: $scopes)
            HStack {
                Button("Save") {
                    var a = existing ?? CloudManagerAccount(label: "", clientId: "", orgId: "", scopes: "")
                    a.label = label.trimmingCharacters(in: .whitespaces)
                    a.clientId = clientId.trimmingCharacters(in: .whitespaces)
                    a.orgId = orgId.trimmingCharacters(in: .whitespaces)
                    a.scopes = scopes.trimmingCharacters(in: .whitespaces)
                    model.saveAccount(a, secret: secret)
                    secret = ""
                    editingId = nil
                    model.testAccount(a.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                          || clientId.trimmingCharacters(in: .whitespaces).isEmpty
                          || orgId.trimmingCharacters(in: .whitespaces).isEmpty
                          || (existing == nil && secret.isEmpty))
                Button("Cancel") {
                    secret = ""
                    editingId = nil
                }
                .controlSize(.small)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func begin(_ a: CloudManagerAccount?) {
        editingId = a?.id ?? "new"
        label = a?.label ?? ""
        clientId = a?.clientId ?? ""
        orgId = a?.orgId ?? ""
        scopes = a?.scopes ?? CloudManagerAccount.defaultScopes
        secret = ""
    }
}
