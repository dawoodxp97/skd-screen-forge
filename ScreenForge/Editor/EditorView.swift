import AppKit
import SwiftUI

/// The editor: live Metal preview, inspector, and output-time timeline.
struct EditorView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var document: ProjectDocument
    @StateObject private var playback = PlaybackEngine()

    @State private var isLoading = true

    private var canvasSize: CGSize {
        Exporter.canvasSize(project: document.project, settings: document.project.export)
    }

    private var previewState: RenderState {
        document.renderer.state(atOutputMs: playback.outputTimeMs)
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
                .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    previewPanel
                    statusStrip
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                InspectorView(document: document, playback: playback)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            TimelineView(document: document, playback: playback)
        }
        .padding(16)
        .frame(minWidth: 1_040, minHeight: 680)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .task(id: document.id) {
            isLoading = true
            await playback.load(project: document.project, bundleURL: document.bundleURL)
            isLoading = false
        }
        .onDisappear {
            playback.pause()
        }
        .onChange(of: document.project.timeline.trims) { _, _ in
            reloadPlayback()
        }
        .onChange(of: document.project.timeline.speeds) { _, _ in
            reloadPlayback()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await document.saveNow()
                    app.showRecorder()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to recorder")

            VStack(alignment: .leading, spacing: 1) {
                Text(document.project.source.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(document.project.source.pixelWidth) × \(document.project.source.pixelHeight)")
                    Text("·")
                    Text("\(timeLabel(Double(document.project.source.durationMs)))")
                    if document.isDirty {
                        Text("· Saving…")
                            .foregroundStyle(Theme.warning)
                    } else {
                        Text("· Saved")
                            .foregroundStyle(Theme.success)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    document.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(!document.canUndo)
                .help("Undo (⌘Z)")

                Button {
                    document.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(!document.canRedo)
                .help("Redo (⇧⌘Z)")
            }

            Divider()
                .frame(height: 20)
                .overlay(Theme.stroke)

            Button {
                document.runAutoZoom()
            } label: {
                Label("Magic zoom", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Generate zooms from cursor activity")

            Button {
                document.addZoomAtPlayhead(outputMs: playback.outputTimeMs)
            } label: {
                Label("Add zoom", systemImage: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Add a zoom at the playhead")

            if app.isExporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(app.exportProgress?.phase.label ?? "Exporting")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Cancel") { app.cancelExport() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Theme.backgroundRaised))
            } else {
                Menu {
                    Button {
                        app.exportCurrentProject(format: .mp4)
                    } label: {
                        Label("Export MP4…", systemImage: "film")
                    }
                    Button {
                        app.exportCurrentProject(format: .gif)
                    } label: {
                        Label("Export GIF…", systemImage: "photo.stack")
                    }
                    Divider()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
                    } label: {
                        Label("Reveal project in Finder", systemImage: "folder")
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .bold))
                        Text("Export")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.accentGradient)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    // MARK: - Preview

    private var previewPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x161A24), Color(hex: 0x0A0B0F)],
                        center: .center,
                        startRadius: 10,
                        endRadius: 620
                    )
                )

            PreviewView(document: document, playback: playback)
                .aspectRatio(document.project.canvas.aspect.ratio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .padding(22)

            if isLoading || playback.isLoading {
                ProgressView("Preparing preview…")
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = playback.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text("Preview unavailable")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Try again") { reloadPlayback() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            VStack {
                HStack {
                    badge("PREVIEW", color: Theme.textSecondary)
                    Spacer()
                    badge(
                        "\(Int(canvasSize.width)) × \(Int(canvasSize.height))",
                        color: Theme.textTertiary
                    )
                }
                Spacer()
                HStack {
                    badge(previewState.layout.label, color: Theme.textTertiary)
                    if previewState.zoomScale > 1.01 {
                        badge(String(format: "%.1f× zoom", previewState.zoomScale), color: Theme.accent)
                    }
                    Spacer()
                    badge(
                        document.project.canvas.aspect.label,
                        color: Theme.textTertiary
                    )
                }
            }
            .padding(16)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35), in: Capsule())
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            Label("Preview matches export", systemImage: "checkmark.seal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.success)

            Text("\(document.project.timeline.zooms.count) zooms")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            Text("\(document.project.timeline.annotations.count) annotations")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            Text("\(document.project.timeline.trims.count) cuts")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            Text(timeLabel(playback.durationMs))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Helpers

    private func reloadPlayback() {
        let position = playback.outputTimeMs
        Task {
            await playback.load(project: document.project, bundleURL: document.bundleURL)
            playback.seek(toOutputMs: min(position, playback.durationMs))
        }
    }

    private func timeLabel(_ milliseconds: Double) -> String {
        let seconds = max(Int((milliseconds / 1000).rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.045))
            )
    }
}
