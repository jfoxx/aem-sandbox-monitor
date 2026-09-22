import SwiftUI

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
