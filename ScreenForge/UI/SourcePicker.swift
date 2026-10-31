import SwiftUI

struct SourcePickerView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capture source").sectionLabel()
                Spacer()
                Button {
                    Task { await app.refreshTargets() }
                } label: {
                    HStack(spacing: 5) {
                        if app.isLoadingTargets {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(app.isLoadingTargets)
            }

            if !app.screenPermission {
                PermissionPrompt(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording access needed",
                    detail: "Allow ScreenForge to capture your screen, then reopen the app.",
                    actionTitle: "Open Settings",
                    action: { app.openPrivacySettings() }
                )
            } else if app.targets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text(app.isLoadingTargets ? "Looking for screens…" : "No screens or windows found")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(app.targets) { target in
                            TargetCard(
                                target: target,
                                isSelected: app.selectedTargetID == target.id
                            ) {
                                app.selectedTargetID = target.id
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 320)
            }
        }
        .panel()
    }
}

struct TargetCard: View {
    let target: CaptureTarget
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.panelElevated)
                        .frame(width: 42, height: 42)
                    Image(systemName: target.kind == .display ? "display" : "macwindow")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(target.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(target.resolutionLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.backgroundRaised)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.65) : Theme.stroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PermissionPrompt: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.warning)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.warning.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.25), lineWidth: 1)
        }
    }
}

struct RecentProjectsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent projects").sectionLabel()
                Spacer()
                Button("Show folder") { app.revealProjectsFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            if app.recentProjects.isEmpty {
                Text("Recordings you finish appear here, ready to edit and export.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(app.recentProjects, id: \.self) { url in
                        Button {
                            Task { await app.openProject(url: url) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.backgroundRaised)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .panel()
    }
}

struct CountdownOverlay: View {
    let value: Int
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Recording starts in")
                    .font(.system(size: 14, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Theme.textSecondary)

                Text("\(value)")
                    .font(.system(size: 148, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accentGradient)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 40)
                    .contentTransition(.numericText(countsDown: true))

                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(48)
        }
        .transition(.opacity)
    }
}
