import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture target

public struct CaptureTarget: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case display
        case window
    }

    public var id: String
    public var kind: Kind
    public var displayID: CGDirectDisplayID
    public var windowID: CGWindowID?
    public var title: String
    public var subtitle: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var cursorBounds: CGRect?

    public var resolutionLabel: String {
        "\(pixelWidth) × \(pixelHeight)"
    }
}

// MARK: - Recording phase

public enum RecordingPhase: Equatable {
    case idle
    case countdown
    case recording
    case paused
    case finishing

    public var isActive: Bool {
        self == .recording || self == .paused || self == .countdown
    }
}

// MARK: - App state

@MainActor
public final class AppState: ObservableObject {
    public enum Mode: Equatable {
        case recorder
        case editor
    }

    @Published public var mode: Mode = .recorder
    @Published public var document: ProjectDocument?

    // Capture
    @Published public var targets: [CaptureTarget] = []
    @Published public var selectedTargetID: String?
    @Published public var isLoadingTargets = false
    @Published public var recordsMicrophone = true
    @Published public var recordsSystemAudio = true
    @Published public var recordsCursor = true
    @Published public var captureFPS = 60

    @Published public var recordingPhase: RecordingPhase = .idle
    @Published public var countdownValue: Int?
    @Published public var elapsedMs: Int = 0

    // Permissions
    @Published public var screenPermission = false
    @Published public var microphonePermission = false
    @Published public var accessibilityPermission = false

    // Export
    @Published public var isExporting = false
    @Published public var exportProgress: ExportProgress?
    @Published public var lastExportURL: URL?
    @Published public var errorMessage: String?
    @Published public var statusMessage: String?

    @Published public private(set) var recentProjects: [URL] = []

    public let compositor: Compositor?

    private var session: RecordingSession?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var elapsedTimer: Timer?
    private var exportTask: Task<Void, Never>?
    private var hudController: RecordingHUDController?

    public init() {
        do {
            self.compositor = try Compositor()
        } catch {
            self.compositor = nil
            self.errorMessage = error.localizedDescription
        }
        refreshPermissions()
        refreshRecentProjects()
    }

    // MARK: - Derived

    public var canReturnToEditor: Bool {
        document != nil
    }

    public func showRecorder() {
        mode = .recorder
    }

    public func showEditor() {
        guard document != nil else { return }
        mode = .editor
    }

    public var selectedTarget: CaptureTarget? {
        guard let selectedTargetID else { return targets.first }
        return targets.first { $0.id == selectedTargetID } ?? targets.first
    }

    public var canRecord: Bool {
        recordingPhase == .idle && selectedTarget != nil && screenPermission
    }

    public var elapsedLabel: String {
        let totalSeconds = max(elapsedMs, 0) / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Targets

    public func refreshTargets() async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            var discovered: [CaptureTarget] = []
            for (index, display) in content.displays.enumerated() {
                discovered.append(CaptureTarget(
                    id: "display-\(display.displayID)",
                    kind: .display,
                    displayID: display.displayID,
                    windowID: nil,
                    title: index == 0 ? "Main display" : "Display \(index + 1)",
                    subtitle: "Entire screen",
                    pixelWidth: display.width,
                    pixelHeight: display.height,
                    cursorBounds: nil
                ))
            }

            let ownBundle = Bundle.main.bundleIdentifier
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let windows = content.windows.filter { window in
                window.isOnScreen &&
                window.frame.width >= 160 &&
                window.frame.height >= 120 &&
                window.owningApplication?.bundleIdentifier != ownBundle
            }

            for window in windows.prefix(40) {
                let width = Int((window.frame.width * scale).rounded()) / 2 * 2
                let height = Int((window.frame.height * scale).rounded()) / 2 * 2
                let appName = window.owningApplication?.applicationName ?? "Window"
                discovered.append(CaptureTarget(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    displayID: CGMainDisplayID(),
                    windowID: window.windowID,
                    title: window.title?.isEmpty == false ? window.title! : appName,
                    subtitle: appName,
                    pixelWidth: max(width, 2),
                    pixelHeight: max(height, 2),
                    cursorBounds: window.frame
                ))
            }

            targets = discovered
            if let selectedTargetID, discovered.contains(where: { $0.id == selectedTargetID }) {
                self.selectedTargetID = selectedTargetID
            } else {
                selectedTargetID = discovered.first(where: { $0.kind == .display })?.id ?? discovered.first?.id
            }
        } catch {
            errorMessage = "Could not list screens and windows. \(error.localizedDescription)"
        }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        screenPermission = CaptureEngine.hasScreenRecordingPermission()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityPermission = CursorRecorder.hasAccessibilityPermission()
    }

    public func requestScreenPermission() {
        _ = CaptureEngine.requestScreenRecordingPermission()
        statusMessage = "If macOS asked, enable ScreenForge in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        refreshPermissions()
    }

    public func requestMicrophonePermission() async {
        let granted = await MicrophoneRecorder.requestPermission()
        microphonePermission = granted
        if !granted {
            errorMessage = "Microphone access was denied. Enable ScreenForge in System Settings → Privacy & Security → Microphone."
        }
    }

    public func requestAccessibilityPermission() {
        _ = CursorRecorder.requestAccessibilityPermission()
        refreshPermissions()
        if !accessibilityPermission {
            recordsCursor = false
            statusMessage = "Cursor effects need Accessibility access. Recording will continue without synthetic cursor telemetry."
        }
    }

    public func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recording

    public func startRecording() async {
        guard recordingPhase == .idle else { return }
        guard let target = selectedTarget else {
            errorMessage = "Choose a screen or window first."
            return
        }
        guard screenPermission else {
            requestScreenPermission()
            return
        }
        if recordsMicrophone && !microphonePermission {
            await requestMicrophonePermission()
            guard microphonePermission else { return }
        }
        if recordsCursor && !accessibilityPermission {
            requestAccessibilityPermission()
        }

        recordingPhase = .countdown
        countdownValue = 3
        for value in stride(from: 3, through: 1, by: -1) {
            countdownValue = value
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        countdownValue = nil
        guard recordingPhase == .countdown else { return }

        do {
            let filter: SCContentFilter
            if let windowID = target.windowID {
                filter = try await CaptureEngine.makeWindowFilter(windowID: windowID)
            } else {
                filter = try await CaptureEngine.makeDisplayFilter(displayID: target.displayID)
            }

            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            let width = max(Int((rect.width * scale).rounded()) / 2 * 2, 2)
            let height = max(Int((rect.height * scale).rounded()) / 2 * 2, 2)

            let capture = CaptureConfiguration(
                displayID: target.displayID,
                windowID: target.windowID,
                fps: captureFPS,
                capturesSystemAudio: recordsSystemAudio,
                capturesMicrophone: false,
                showsCursor: false,
                pixelWidth: width,
                pixelHeight: height,
                cursorBounds: target.cursorBounds,
                segmentDuration: 10,
                codec: .hevc
            )

            let recordingSession = try RecordingSession(configuration: RecordingSession.Configuration(
                displayName: target.title,
                capture: capture,
                recordsMicrophone: recordsMicrophone,
                hideSystemCursor: true,
                recordsCursor: recordsCursor && accessibilityPermission,
                outputDirectory: RecordingSession.defaultOutputDirectory,
                enableVoiceProcessing: true
            ))
            try await recordingSession.start()
            session = recordingSession
            recordingPhase = .recording
            startedAt = Date()
            pausedAt = nil
            pausedTotal = 0
            elapsedMs = 0
            startElapsedTimer()
            showHUD()
        } catch {
            recordingPhase = .idle
            countdownValue = nil
            session = nil
            errorMessage = error.localizedDescription
            refreshPermissions()
        }
    }

    public func pauseOrResume() async {
        guard let session else { return }
        switch recordingPhase {
        case .recording:
            await session.pause()
            recordingPhase = .paused
            pausedAt = Date()
        case .paused:
            await session.resume()
            recordingPhase = .recording
            if let pausedAt {
                pausedTotal += Date().timeIntervalSince(pausedAt)
            }
            self.pausedAt = nil
        default:
            break
        }
    }

    public func stopRecording() async {
        guard let session, recordingPhase == .recording || recordingPhase == .paused else { return }
        recordingPhase = .finishing
        stopElapsedTimer()
        hideHUD()

        do {
            let result = try await session.stop()
            self.session = nil
            recordingPhase = .idle
            await openProject(url: result.projectBundleURL)
            refreshRecentProjects()
        } catch {
            self.session = nil
            recordingPhase = .idle
            errorMessage = error.localizedDescription
        }
    }

    public func cancelRecording() async {
        guard let session else { return }
        recordingPhase = .finishing
        stopElapsedTimer()
        hideHUD()
        await session.cancel()
        self.session = nil
        recordingPhase = .idle
        elapsedMs = 0
    }

    public func discardCountdown() {
        guard recordingPhase == .countdown else { return }
        recordingPhase = .idle
        countdownValue = nil
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                var elapsed = Date().timeIntervalSince(startedAt) - self.pausedTotal
                if let pausedAt = self.pausedAt {
                    elapsed -= Date().timeIntervalSince(pausedAt)
                }
                self.elapsedMs = max(Int(elapsed * 1000), 0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - HUD

    private func showHUD() {
        if hudController == nil {
            hudController = RecordingHUDController()
        }
        hudController?.show(appState: self)
    }

    private func hideHUD() {
        hudController?.hide()
    }

    // MARK: - Projects

    public func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a ScreenForge project"
        panel.allowedContentTypes = [UTType(exportedAs: "studio.screenforge.project")]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(url: url) }
    }

    public func openProject(url: URL) async {
        do {
            let project = try await ProjectStore.shared.load(from: url)
            let cursorSamples = try await ProjectStore.shared.loadCursor(from: url)
            let transcript = try await ProjectStore.shared.loadTranscript(from: url)
            guard let compositor else {
                errorMessage = "Metal is unavailable on this Mac."
                return
            }
            let document = ProjectDocument(
                bundleURL: url,
                project: project,
                cursorSamples: cursorSamples,
                compositor: compositor,
                transcript: transcript
            )
            self.document = document
            mode = .editor
            refreshRecentProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func closeProject() {
        guard let document else {
            mode = .recorder
            return
        }
        Task {
            await document.saveNow()
            self.document = nil
            self.mode = .recorder
            self.refreshRecentProjects()
        }
    }

    public func refreshRecentProjects() {
        let directory = RecordingSession.defaultOutputDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        recentProjects = urls
            .filter { $0.pathExtension == ProjectBundleLayout.fileExtension }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(8)
            .map { $0 }
    }

    public func revealProjectsFolder() {
        let directory = RecordingSession.defaultOutputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    // MARK: - Export

    public func exportCurrentProject(format: ExportFormat) {
        guard let document, !isExporting else { return }

        let panel = NSSavePanel()
        panel.title = "Export \(format.label)"
        panel.nameFieldStringValue = "\(document.project.source.displayName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = format == .gif ? [.gif] : [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        exportProgress = ExportProgress(phase: .preparing, fraction: 0, message: "Preparing")
        lastExportURL = nil

        exportTask = Task {
            do {
                let output = try await document.export(to: url, format: format) { progress in
                    Task { @MainActor in
                        self.exportProgress = progress
                    }
                }
                self.lastExportURL = output
                self.exportProgress = ExportProgress(
                    phase: .finishing,
                    fraction: 1,
                    message: "Saved \(output.lastPathComponent)"
                )
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.isExporting = false
        }
    }

    public func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }
}
