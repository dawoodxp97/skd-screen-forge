import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum CursorRecorderError: LocalizedError, Sendable {
    case accessibilityDenied
    case eventTapUnavailable
    case fileSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Accessibility permission is required to record cursor movement. Enable ScreenForge in System Settings → Privacy & Security → Accessibility."
        case .eventTapUnavailable:
            "Could not create the cursor event tap. Another app may be blocking input monitoring."
        case .fileSetupFailed(let reason):
            "Could not create the cursor log: \(reason)"
        }
    }
}

/// Records global mouse telemetry (position, clicks, scrolls) at up to 125 Hz.
///
/// The screen itself is captured with the cursor hidden, so this log is the single
/// source of truth for the post-production cursor overlay.
public final class CursorRecorder: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var displayID: CGDirectDisplayID
        /// Minimum spacing between recorded move samples.
        public var sampleIntervalMs: Int
        public var hideSystemCursor: Bool
        /// Screen-space rect the cursor is normalized against (a window, or the display).
        public var normalizedBounds: CGRect?

        public init(
            displayID: CGDirectDisplayID,
            sampleIntervalMs: Int = 8,
            hideSystemCursor: Bool = true,
            normalizedBounds: CGRect? = nil
        ) {
            self.displayID = displayID
            self.sampleIntervalMs = sampleIntervalMs
            self.hideSystemCursor = hideSystemCursor
            self.normalizedBounds = normalizedBounds
        }
    }

    private let lock = NSLock()
    private let flushQueue = DispatchQueue(label: "studio.screenforge.cursor.flush", qos: .utility)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: DispatchSourceTimer?
    private var fileHandle: FileHandle?

    private var samples: [CursorSample] = []
    private var flushedCount = 0
    private var configuration: Configuration?
    private var displayBounds: CGRect = .zero
    private var startHostSeconds: Double = 0
    private var lastMoveMs: Int = -.max
    private var isRecording = false

    public init() {}

    // MARK: Permission

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        // The exported C global is not concurrency-safe in Swift 6; its documented
        // value is the stable dictionary key below.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Lifecycle

    public func start(configuration: Configuration, outputURL: URL) throws {
        lock.lock()
        guard !isRecording else {
            lock.unlock()
            return
        }

        guard CursorRecorder.hasAccessibilityPermission() else {
            lock.unlock()
            throw CursorRecorderError.accessibilityDenied
        }

        let bounds = configuration.normalizedBounds ?? CGDisplayBounds(configuration.displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            lock.unlock()
            throw CursorRecorderError.fileSetupFailed("Display bounds are empty")
        }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            }
            fileHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            lock.unlock()
            throw CursorRecorderError.fileSetupFailed(error.localizedDescription)
        }

        self.configuration = configuration
        self.displayBounds = bounds
        self.startHostSeconds = CACurrentMediaTime()
        self.lastMoveMs = -.max
        self.samples.removeAll(keepingCapacity: true)
        self.flushedCount = 0
        self.isRecording = true
        lock.unlock()

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cursorEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            cleanup()
            throw CursorRecorderError.eventTapUnavailable
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if configuration.hideSystemCursor {
            CGDisplayHideCursor(configuration.displayID)
        }

        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.flushTimer = timer
    }

    public func stop() -> [CursorSample] {
        lock.lock()
        guard isRecording else {
            let copy = samples
            lock.unlock()
            return copy
        }
        isRecording = false
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        flushTimer?.cancel()
        flushTimer = nil

        if let configuration, configuration.hideSystemCursor {
            CGDisplayShowCursor(configuration.displayID)
        }

        flush()
        lock.lock()
        fileHandle?.closeFile()
        fileHandle = nil
        let result = samples
        lock.unlock()

        tap = nil
        runLoopSource = nil
        return result
    }

    /// Thread-safe snapshot for live preview.
    public func snapshot() -> [CursorSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    // MARK: Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let location = event.location
        let x = (location.x - displayBounds.minX) / displayBounds.width
        let y = (location.y - displayBounds.minY) / displayBounds.height
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return }

        let nowMs = Int((Double(event.timestamp) / 1_000_000_000 - startHostSeconds) * 1000)
        guard nowMs >= 0 else { return }

        let interaction: CursorSample.Interaction
        switch type {
        case .leftMouseDown, .leftMouseUp:
            let clickState = event.getIntegerValueField(.mouseEventClickState)
            interaction = clickState >= 2 && type == .leftMouseDown ? .doubleClick : (type == .leftMouseUp ? .move : .click)
        case .rightMouseDown, .rightMouseUp:
            interaction = type == .rightMouseDown ? .rightClick : .move
        case .otherMouseDown, .otherMouseUp:
            interaction = type == .otherMouseDown ? .middleClick : .move
        case .scrollWheel:
            interaction = .scroll
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            interaction = .drag
        default:
            interaction = .move
        }

        if interaction == .move || interaction == .drag {
            guard nowMs - lastMoveMs >= (configuration?.sampleIntervalMs ?? 8) else { return }
            lastMoveMs = nowMs
        }

        let sample = CursorSample(
            timeMs: nowMs,
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            interaction: interaction,
            visible: true
        )

        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    // MARK: Flushing

    private func flush() {
        lock.lock()
        guard let fileHandle, samples.count > flushedCount else {
            lock.unlock()
            return
        }
        let pending = Array(samples[flushedCount...])
        flushedCount = samples.count
        lock.unlock()

        do {
            let data = try CursorJSONL.encode(pending)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
        } catch {
            NSLog("Cursor log flush failed: \(error.localizedDescription)")
        }
    }

    private func cleanup() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }
}

// MARK: - C callback

private func cursorEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let recorder = Unmanaged<CursorRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        recorder.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
