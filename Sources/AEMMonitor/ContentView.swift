import AppKit
import SwiftUI

/// The popover content shown when the user clicks the menu bar icon.
struct ContentView: View {
    @ObservedObject var model: EnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showSettings {
                SettingsView(model: model)
            } else if model.isEmpty {
                emptyState
            } else {
                monitorView
            }
        }
        .frame(width: 340, height: 440)
    }

    // MARK: - Monitor (main) view

    private var monitorView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top toolbar
            HStack {
                Text("AEM Monitor")
                    .font(.headline)
                Spacer()
                if model.anyWatching {
                    Button("Stop All") { model.stopAll() }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    Button("Watch All") { model.watchAll() }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.caption)
                }
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .padding(.leading, 6)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.programs.indices, id: \.self) { pi in
                        ProgramSection(model: model, programIndex: pi)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider()

            // Footer
            HStack {
                if let date = model.lastGlobalCheck {
                    Text("Last check: \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("No checks yet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty state (no programs configured)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cloud")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Environments Configured")
                .font(.headline)
            Text("Add your Cloud Manager programs and environments to start monitoring.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Open Settings") {
                model.showSettings = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Program Section

struct ProgramSection: View {
    @ObservedObject var model: EnvironmentModel
    let programIndex: Int

    private var program: AEMProgram {
        model.programs[programIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(program.name)  (\(program.id))")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(program.environments.indices, id: \.self) { ei in
                EnvironmentRow(model: model, programIndex: programIndex, envIndex: ei)
            }
        }
    }
}

// MARK: - Environment Row

struct EnvironmentRow: View {
    @ObservedObject var model: EnvironmentModel
    let programIndex: Int
    let envIndex: Int

    private var env: AEMEnvironment {
        model.programs[programIndex].environments[envIndex]
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(env.status.icon)
                .font(.system(size: 10))
                .help(env.status.label)

            Text(env.displayLabel)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if env.isWatching {
                HStack(spacing: 4) {
                    if env.status == .checking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("\(env.secondsUntilNext)s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Button("Stop") {
                        model.stopWatching(programIndex: programIndex, envIndex: envIndex)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            } else {
                Button("Watch") {
                    model.startWatching(programIndex: programIndex, envIndex: envIndex)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(env.isWatching ? Color.accentColor.opacity(0.07) : Color.clear)
        )
    }
}
