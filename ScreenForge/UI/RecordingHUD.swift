import AppKit
import SwiftUI

/// A floating, always-available recording bar shown while capturing.
@MainActor
public final class RecordingHUDController {
    private var panel: NSPanel?

    public init() {}

    public func show(appState: AppState) {
        guard panel == nil else { return }

        let size = NSSize(width: 540, height: 84)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let hosting = NSHostingView(
            rootView: RecordingHUDView().environmentObject(appState)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 24
            ))
        } else {
            panel.center()
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

struct RecordingHUDView: View {
    @EnvironmentObject private var app: AppState
    @State private var pulse = false

    private var isPaused: Bool { app.recordingPhase == .paused }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isPaused ? Color.orange : Color.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse && !isPaused ? 1.25 : 0.9)
                    .shadow(color: (isPaused ? Color.orange : Color.red).opacity(0.7), radius: 6)

                Circle()
                    .stroke((isPaused ? Color.orange : Color.red).opacity(0.35), lineWidth: 6)
                    .frame(width: 24, height: 24)
                    .scaleEffect(pulse && !isPaused ? 1.1 : 0.8)
                    .opacity(pulse && !isPaused ? 0 : 0.8)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(isPaused ? "Paused" : "Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    Text(app.elapsedLabel)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if app.recordingMarkerCount > 0 {
                        Label("\(app.recordingMarkerCount)", systemImage: "bookmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.yellow.opacity(0.9))
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await app.addRecordingMarker() }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.yellow)
            .help("Add a marker at this moment (⌘M)")

            Button {
                Task { await app.addRecordingMarker(kind: .flag) }
            } label: {
                Image(systemName: "flag.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Flag this moment for review")

            Button {
                Task { await app.pauseOrResume() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(isPaused ? "Resume recording" : "Pause recording")

            Button {
                Task { await app.stopRecording() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Color.red.opacity(0.85), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Finish recording")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .padding(6)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
