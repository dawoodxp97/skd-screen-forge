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

/// Records global mouse telemetry (position, clicks, drags) at up to 125 Hz.
///
/// Position and buttons are **polled** rather than only read from a `CGEventTap`.
/// Event taps are suppressed for sandboxed apps even with Accessibility granted, which
/// previously produced an empty `cursor.jsonl` (and therefore no cursor, no click
/// effects, and no automatic zooms). Polling uses public, sandbox-safe CoreGraphics
/// queries and works unconditionally; a tap is still installed when available to add
/// scroll-wheel events.
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
    private let pollQueue = DispatchQueue(label: "studio.screenforge.cursor.poll", qos: .userInteractive)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
    private var fileHandle: FileHandle?

    private var samples: [CursorSample] = []
    private var flushedCount = 0
    private var configuration: Configuration?
    private var displayBounds: CGRect = .zero
    private var startHostSeconds: Double = 0
    private var lastMoveMs: Int = -.max
    private var lastClickMs: Int = -.max
    private var lastPosition = CGPoint(x: 0.5, y: 0.5)
    private var leftDown = false
    private var rightDown = false
    private var otherDown = false
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
        self.lastClickMs = -.max
        self.samples.removeAll(keepingCapacity: true)
        self.flushedCount = 0
        self.isRecording = true
        lock.unlock()

        if configuration.hideSystemCursor {
            CGDisplayHideCursor(configuration.displayID)
        }

        startPolling(intervalMs: max(configuration.sampleIntervalMs, 4))
        installScrollTap()
        startFlushTimer()
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

        pollTimer?.cancel()
        pollTimer = nil
        flushTimer?.cancel()
        flushTimer = nil
        removeTap()

        if let configuration, configuration.hideSystemCursor {
            CGDisplayShowCursor(configuration.displayID)
        }

        flush()
        lock.lock()
        fileHandle?.closeFile()
        fileHandle = nil
        let result = samples
        lock.unlock()
        return result
    }

    /// Thread-safe snapshot for live preview.
    public func snapshot() -> [CursorSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    // MARK: Polling

    private func startPolling(intervalMs: Int) {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        guard let event = CGEvent(source: nil) else { return }
        let location = event.location
        poll(location: location, left: buttonDown(.left), right: buttonDown(.right), other: buttonDown(.center))
    }

    private func buttonDown(_ button: CGMouseButton) -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: button)
    }

    private func poll(location: CGPoint, left: Bool, right: Bool, other: Bool) {
        lock.lock()
        guard isRecording, let configuration else {
            lock.unlock()
            return
        }
        let bounds = displayBounds
        let start = startHostSeconds
        let lastMove = lastMoveMs
        lock.unlock()

        let x = (location.x - bounds.minX) / max(bounds.width, 1)
        let y = (location.y - bounds.minY) / max(bounds.height, 1)
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return }

        let nowMs = Int((CACurrentMediaTime() - start) * 1000)
        guard nowMs >= 0 else { return }

        let normalized = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        var interaction: CursorSample.Interaction?

        // Button transitions are always recorded, even if the move is throttled.
        if left && !leftDown {
            let isDouble = nowMs - lastClickMs <= 320
            interaction = isDouble ? .doubleClick : .click
            lock.lock()
            lastClickMs = nowMs
            leftDown = true
            lock.unlock()
        } else if right && !rightDown {
            interaction = .rightClick
            lock.lock()
            lastClickMs = nowMs
            rightDown = true
            lock.unlock()
        } else if other && !otherDown {
            interaction = .middleClick
            lock.lock()
            otherDown = true
            lock.unlock()
        } else {
            lock.lock()
            leftDown = left
            rightDown = right
            otherDown = other
            lock.unlock()
        }

        if interaction == nil {
            let moved = hypot(normalized.x - lastPosition.x, normalized.y - lastPosition.y) > 0.0005
            guard moved || nowMs - lastMove >= configuration.sampleIntervalMs else { return }
            interaction = (left || right || other) ? .drag : .move
        }

        if interaction == .move || interaction == .drag {
            lock.lock()
            lastMoveMs = nowMs
            lastPosition = normalized
            lock.unlock()
        } else {
            lock.lock()
            lastPosition = normalized
            lock.unlock()
        }

        append(CursorSample(
            timeMs: nowMs,
            x: normalized.x,
            y: normalized.y,
            interaction: interaction ?? .move,
            visible: true
        ))
    }

    // MARK: Scroll tap (best effort)

    private func installScrollTap() {
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cursorEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Sandboxed apps usually cannot create taps; polling still covers moves/clicks.
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
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
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
    }

    // MARK: Event handling (scroll only)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .scrollWheel else { return }

        let location = event.location
        let x = (location.x - displayBounds.minX) / max(displayBounds.width, 1)
        let y = (location.y - displayBounds.minY) / max(displayBounds.height, 1)
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return }

        let nowMs = Int((CACurrentMediaTime() - startHostSeconds) * 1000)
        guard nowMs >= 0 else { return }

        append(CursorSample(
            timeMs: nowMs,
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            interaction: .scroll,
            visible: true
        ))
    }

    private func append(_ sample: CursorSample) {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
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
