import SwiftUI

/// The recording home: choose a source, set audio/cursor options, check
/// permissions, then start a take. Recent projects open straight into the editor.
struct RecorderView: View {
    @EnvironmentObject private var app: AppState
    @State private var isHoveringRecord = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 34)
                .padding(.top, 26)
                .padding(.bottom, 18)

            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        hero
                        SourcePickerView()
                        CaptureOptionsView()
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(alignment: .leading, spacing: 18) {
                        recordCard
                        PermissionsView()
                        RecentProjectsView()
                    }
                    .frame(width: 340)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .task {
            app.refreshPermissions()
            if app.targets.isEmpty {
                await app.refreshTargets()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 38, height: 38)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("ScreenForge")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Native screen recording studio")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            HStack(spacing: 10) {
                if app.canReturnToEditor {
                    Button {
                        app.showEditor()
                    } label: {
                        Label("Back to editor", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    app.openProjectPanel()
                } label: {
                    Label("Open project", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    app.revealProjectsFolder()
                } label: {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show recordings folder")
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record once.")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Look extraordinary.")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentGradient)
            Text("Capture your screen and voice, then polish the take with automatic zooms, a synthetic cursor, and studio backgrounds — all on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .padding(.top, 4)
    }

    // MARK: - Record card

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready when you are").sectionLabel()

            if let target = app.selectedTarget {
                HStack(spacing: 10) {
                    Image(systemName: target.kind == .display ? "display" : "macwindow")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(target.resolutionLabel) · \(app.captureFPS) fps")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Circle()
                        .fill(app.canRecord ? Theme.success : Theme.warning)
                        .frame(width: 7, height: 7)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.backgroundRaised)
                )
            }

            Button {
                Task { await app.startRecording() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 26, height: 26)
                        Circle()
                            .fill(Theme.danger)
                            .frame(width: 12, height: 12)
                    }
                    Text(app.canRecord ? "Start recording" : "Enable screen access")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("⌘R")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentGradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(isHoveringRecord ? 0.09 : 0))
                        )
                )
                .shadow(color: Theme.accent.opacity(isHoveringRecord ? 0.55 : 0.3), radius: 18, y: 8)
                .scaleEffect(isHoveringRecord ? 1.01 : 1)
                .animation(.easeOut(duration: 0.16), value: isHoveringRecord)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringRecord = $0 }
            .disabled(app.recordingPhase != .idle)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Recordings stay on this Mac. Nothing is uploaded.")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
        }
        .panel()
    }
}

// MARK: - Options

struct CaptureOptionsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture options").sectionLabel()

            VStack(spacing: 0) {
                OptionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: app.microphonePermission ? "Voiceover and voice enhancement" : "Permission required",
                    isOn: $app.recordsMicrophone
                )
                Divider().overlay(Theme.stroke)
                OptionRow(
                    icon: "speaker.wave.2.fill",
                    title: "System audio",
                    detail: "App sound, music, and calls",
                    isOn: $app.recordsSystemAudio
                )
                Divider().overlay(Theme.stroke)
                OptionRow(
                    icon: "cursorarrow.motionlines",
                    title: "Cursor effects",
                    detail: app.accessibilityPermission ? "Synthetic cursor, clicks, smoothing" : "Accessibility permission required",
                    isOn: $app.recordsCursor
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.backgroundRaised)
            )

            HStack(spacing: 12) {
                Text("Frame rate")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("Frame rate", selection: $app.captureFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.backgroundRaised)
            )

            if app.recordsCursor && !app.accessibilityPermission {
                Button {
                    app.requestAccessibilityPermission()
                } label: {
                    Label("Grant Accessibility access for cursor telemetry", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
            }
        }
        .panel()
    }
}

private struct OptionRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Permissions").sectionLabel()
                Spacer()
                Button {
                    app.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Recheck permissions")
            }

            VStack(spacing: 0) {
                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    detail: "Required to capture your screen",
                    granted: app.screenPermission
                ) {
                    app.requestScreenPermission()
                }

                Divider().overlay(Theme.stroke)

                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Used when microphone is enabled",
                    granted: app.microphonePermission || !app.recordsMicrophone
                ) {
                    Task { await app.requestMicrophonePermission() }
                }

                Divider().overlay(Theme.stroke)

                PermissionRow(
                    icon: "cursorarrow.click",
                    title: "Accessibility",
                    detail: "Reads cursor position and clicks",
                    granted: app.accessibilityPermission || !app.recordsCursor
                ) {
                    app.requestAccessibilityPermission()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.backgroundRaised)
            )

            Button {
                app.openPrivacySettings()
            } label: {
                Text("Open System Settings →")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .panel()
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? Theme.success : Theme.warning)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.success)
            } else {
                Button("Grant", action: action)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.warning.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
