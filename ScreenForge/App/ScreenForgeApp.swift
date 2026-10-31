import AppKit
import SwiftUI

@main
struct ScreenForgeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("ScreenForge", id: "main") {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1_040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_320, height: 860)
        .commands {
            ScreenForgeCommands(app: app)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            Group {
                if app.mode == .editor, let document = app.document {
                    EditorView(document: document)
                        .id(document.id)
                } else {
                    RecorderView()
                }
            }
            .transition(.opacity)

            if let value = app.countdownValue {
                CountdownOverlay(value: value) {
                    app.discardCountdown()
                }
                .zIndex(2)
            }

            if app.recordingPhase == .finishing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Finishing recording…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Joining segments, cursor telemetry, and audio")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(26)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .zIndex(3)
            }
        }
        .overlay(alignment: .top) {
            if let status = app.statusMessage {
                StatusToast(text: status) {
                    app.statusMessage = nil
                }
                .padding(.top, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(4)
                .task(id: status) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    guard !Task.isCancelled else { return }
                    app.statusMessage = nil
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.mode)
        .animation(.easeInOut(duration: 0.18), value: app.countdownValue)
        .animation(.easeInOut(duration: 0.2), value: app.statusMessage)
        .alert(
            "ScreenForge",
            isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { presented in
                    if !presented { app.errorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                app.errorMessage = nil
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

// MARK: - Toast

struct StatusToast: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: - Commands

struct ScreenForgeCommands: Commands {
    @ObservedObject var app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                app.showRecorder()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(app.recordingPhase != .idle)

            Button("Open Project…") {
                app.openProjectPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Show Editor") {
                app.showEditor()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(app.document == nil)

            Button("Back to Recorder") {
                app.showRecorder()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Project") {
                guard let document = app.document else { return }
                Task { await document.saveNow() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(app.document == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                app.document?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(app.document?.canUndo != true)

            Button("Redo") {
                app.document?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(app.document?.canRedo != true)
        }

        CommandMenu("Project") {
            Button("Close Project") {
                app.closeProject()
            }
            .disabled(app.document == nil)

            Divider()

            Button("Reveal Projects Folder") {
                app.revealProjectsFolder()
            }

            Divider()

            Button("Export MP4…") {
                app.exportCurrentProject(format: .mp4)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(app.document == nil || app.isExporting)

            Button("Export GIF…") {
                app.exportCurrentProject(format: .gif)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(app.document == nil || app.isExporting)

            if app.isExporting {
                Divider()
                Button("Cancel Export") {
                    app.cancelExport()
                }
            }
        }
    }
}
