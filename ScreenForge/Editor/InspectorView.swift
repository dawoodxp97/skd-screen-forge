import AppKit
import SwiftUI

/// Right-hand inspector for the open project. Continuous controls write through
/// `ProjectDocument.apply`, so every change is normalized, autosaved, and undoable.
struct InspectorView: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var playback: PlaybackEngine
    @EnvironmentObject private var app: AppState

    @State private var tab: Tab = .zoom

    enum Tab: String, CaseIterable, Identifiable {
        case zoom
        case style
        case cursor
        case camera
        case captions
        case export

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .zoom: "magnifyingglass"
            case .style: "paintbrush.pointed"
            case .cursor: "cursorarrow"
            case .camera: "person.crop.square"
            case .captions: "captions.bubble"
            case .export: "square.and.arrow.up"
            }
        }

        var title: String {
            switch self {
            case .zoom: "Zooms"
            case .style: "Style"
            case .cursor: "Cursor"
            case .camera: "Camera"
            case .captions: "Captions"
            case .export: "Export"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectionEditors
                    tabContent
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tab == item ? Theme.accent : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tab == item ? Theme.accent.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(8)
    }

    // MARK: - Selection editors

    @ViewBuilder
    private var selectionEditors: some View {
        if document.selectedAnnotation != nil {
            annotationEditor
        } else if document.selectedSpeed != nil {
            speedEditor
        } else if document.selectedLayout != nil {
            layoutEditor
        }
    }

    private var annotationEditor: some View {
        InspectorSection("Selected annotation") {
            if let annotation = document.selectedAnnotation {
                Text(annotation.type.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)

                if annotation.type == .text {
                    TextField("Text", text: annotationTextBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.background)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        }
                }

                InspectorSlider(
                    title: "Opacity",
                    value: annotationBinding(\.style.opacity, fallback: 1),
                    range: 0...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Horizontal",
                    value: annotationBinding(\.rect.x, fallback: 0.25),
                    range: 0...0.95,
                    format: percent
                )
                InspectorSlider(
                    title: "Vertical",
                    value: annotationBinding(\.rect.y, fallback: 0.25),
                    range: 0...0.95,
                    format: percent
                )
                InspectorSlider(
                    title: "Width",
                    value: annotationBinding(\.rect.width, fallback: 0.5),
                    range: 0.05...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Height",
                    value: annotationBinding(\.rect.height, fallback: 0.3),
                    range: 0.05...1,
                    format: percent
                )

                HStack(spacing: 8) {
                    Button("Start here") { setAnnotationStartAtPlayhead() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("End here") { setAnnotationEndAtPlayhead() }
                        .buttonStyle(SecondaryButtonStyle())
                }

                Button(role: .destructive) {
                    document.deleteSelectedAnnotation()
                } label: {
                    Label("Delete annotation", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
        }
    }

    private var speedEditor: some View {
        InspectorSection("Selected speed") {
            if let speed = document.selectedSpeed {
                InspectorSlider(
                    title: "Rate",
                    value: speedBinding(\.rate, fallback: 2),
                    range: 0.25...4,
                    format: { String(format: "%.2f×", $0) }
                )
                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { rate in
                        Button(String(format: "%.1f×", rate)) {
                            updateSpeed { $0.rate = rate }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(abs(speed.rate - rate) < 0.01 ? .white : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                abs(speed.rate - rate) < 0.01
                                    ? Theme.warning.opacity(0.8)
                                    : Color.white.opacity(0.06)
                            )
                        )
                    }
                }

                Text(String(format: "%.1f s → %.1f s", Double(speed.startMs) / 1000, Double(speed.endMs) / 1000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                HStack(spacing: 8) {
                    Button("Start here") { setSpeedStartAtPlayhead() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("End here") { setSpeedEndAtPlayhead() }
                        .buttonStyle(SecondaryButtonStyle())
                }

                Button(role: .destructive) {
                    document.deleteSelectedSpeed()
                } label: {
                    Label("Delete speed change", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
        }
    }

    private var layoutEditor: some View {
        InspectorSection("Selected layout") {
            if document.selectedLayout != nil {
                Picker("Layout", selection: layoutBinding(\.kind, fallback: .cameraOverlay)) {
                    ForEach(LayoutKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                InspectorSlider(
                    title: "Transition",
                    value: Binding(
                        get: { Double(document.selectedLayout?.transitionMs ?? 500) },
                        set: { value in updateLayout { $0.transitionMs = Int(value) } }
                    ),
                    range: 0...2_000,
                    format: { String(format: "%.2f s", $0 / 1000) }
                )
                InspectorSlider(
                    title: "Camera X",
                    value: layoutBinding(\.cameraFocus.x, fallback: 0.82),
                    range: 0...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Camera Y",
                    value: layoutBinding(\.cameraFocus.y, fallback: 0.8),
                    range: 0...1,
                    format: percent
                )

                Button(role: .destructive) {
                    document.deleteSelectedLayout()
                } label: {
                    Label("Delete layout region", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .zoom: zoomTab
        case .style: styleTab
        case .cursor: cursorTab
        case .camera: cameraTab
        case .captions: captionsTab
        case .export: exportTab
        }
    }

    private var zoomTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Magic wand") {
                InspectorToggle(
                    title: "Auto zoom",
                    detail: "Suggest zooms from cursor activity",
                    isOn: binding(\.timeline.autoZoomEnabled)
                )
                Button {
                    document.runAutoZoom()
                } label: {
                    Label("Generate zooms", systemImage: "wand.and.stars")
                }
                .buttonStyle(SecondaryButtonStyle())

                if document.project.timeline.zooms.contains(where: \.generated) {
                    Button("Clear generated zooms") {
                        document.clearGeneratedZooms()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                }
            }

            if let zoom = document.selectedZoom {
                InspectorSection("Zoom") {
                    InspectorSlider(
                        title: "Scale",
                        value: zoomBinding(\.scale, fallback: 1.8),
                        range: 1...5,
                        format: { String(format: "%.2f×", $0) }
                    )

                    HStack {
                        Text("Kind")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker("Kind", selection: zoomBinding(\.kind, fallback: .classic)) {
                            ForEach(ZoomKind.allCases, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 130)
                    }

                    HStack {
                        Text("Easing")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker("Easing", selection: zoomBinding(\.easing, fallback: .screenStudio)) {
                            ForEach(ZoomEasing.allCases, id: \.self) { easing in
                                Text(easing.label).tag(easing)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 130)
                    }

                    InspectorSlider(
                        title: "Focus X",
                        value: zoomBinding(\.focus.x, fallback: 0.5),
                        range: 0...1,
                        format: percent
                    )
                    InspectorSlider(
                        title: "Focus Y",
                        value: zoomBinding(\.focus.y, fallback: 0.5),
                        range: 0...1,
                        format: percent
                    )

                    HStack(spacing: 8) {
                        Button("Start here") { setZoomStartAtPlayhead() }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("End here") { setZoomEndAtPlayhead() }
                            .buttonStyle(SecondaryButtonStyle())
                    }

                    Text(String(format: "%.2f s → %.2f s", Double(zoom.startMs) / 1000, Double(zoom.endMs) / 1000))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)

                    Button(role: .destructive) {
                        document.deleteSelectedZoom()
                    } label: {
                        Label("Delete zoom", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                }
            } else {
                InspectorSection("Zoom") {
                    Text("Select a zoom on the timeline, or add one at the playhead.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        document.addZoomAtPlayhead(outputMs: playback.outputTimeMs)
                    } label: {
                        Label("Add zoom", systemImage: "plus.magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var styleTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Canvas") {
                Picker("Aspect ratio", selection: binding(\.canvas.aspect)) {
                    ForEach(AspectRatio.allCases, id: \.self) { aspect in
                        Text(aspect.label).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                InspectorSlider(
                    title: "Padding",
                    value: binding(\.canvas.padding),
                    range: 0...0.45,
                    format: percent
                )
                InspectorSlider(
                    title: "Inset",
                    value: binding(\.canvas.inset),
                    range: 0...0.25,
                    format: percent
                )
                InspectorSlider(
                    title: "Corner radius",
                    value: binding(\.canvas.cornerRadius),
                    range: 0...0.2,
                    format: percent
                )
            }

            InspectorSection("Background") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(Self.backgroundPresets) { preset in
                        BackgroundSwatch(
                            preset: preset,
                            selected: document.project.canvas.background.identifier == preset.id
                        ) {
                            document.apply {
                                $0.canvas.background = BackgroundStyle(
                                    kind: preset.kind,
                                    identifier: preset.id,
                                    colors: preset.colors
                                )
                            }
                        }
                    }
                }
            }

            InspectorSection("Shadow") {
                InspectorSlider(
                    title: "Opacity",
                    value: binding(\.canvas.shadow.opacity),
                    range: 0...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Blur",
                    value: binding(\.canvas.shadow.blur),
                    range: 0...0.25,
                    format: { String(format: "%.1f", $0 * 100) }
                )
                InspectorSlider(
                    title: "Distance",
                    value: binding(\.canvas.shadow.distance),
                    range: 0...0.2,
                    format: { String(format: "%.1f", $0 * 100) }
                )
                InspectorSlider(
                    title: "Angle",
                    value: binding(\.canvas.shadow.angle),
                    range: 0...360,
                    format: { String(format: "%.0f°", $0) }
                )
            }
        }
    }

    private var cursorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Cursor") {
                InspectorToggle(
                    title: "Show synthetic cursor",
                    detail: "Re-rendered from recorded telemetry",
                    isOn: binding(\.cursor.visible)
                )

                HStack {
                    Text("Theme")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Theme", selection: binding(\.cursor.theme)) {
                        ForEach(CursorTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                InspectorSlider(
                    title: "Size",
                    value: binding(\.cursor.scale),
                    range: 0.25...5,
                    format: { String(format: "%.2f×", $0) }
                )
                InspectorSlider(
                    title: "Smoothing",
                    value: binding(\.cursor.smoothing),
                    range: 0...0.98,
                    format: percent
                )
                InspectorSlider(
                    title: "Motion blur",
                    value: binding(\.cursor.motionBlur),
                    range: 0...1,
                    format: percent
                )
            }

            InspectorSection("Clicks") {
                HStack {
                    Text("Effect")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Effect", selection: binding(\.cursor.clickEffect)) {
                        ForEach(ClickEffect.allCases, id: \.self) { effect in
                            Text(effect.label).tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                InspectorSlider(
                    title: "Effect size",
                    value: binding(\.cursor.clickEffectScale),
                    range: 0.25...3,
                    format: { String(format: "%.2f×", $0) }
                )
            }

            InspectorSection("Behavior") {
                InspectorSlider(
                    title: "Hide when idle",
                    value: Binding(
                        get: { Double(document.project.cursor.hideWhenIdleMs) },
                        set: { value in document.apply { $0.cursor.hideWhenIdleMs = Int(value) } }
                    ),
                    range: 0...10_000,
                    format: { $0 <= 0 ? "Never" : String(format: "%.1f s", $0 / 1000) }
                )
                InspectorToggle(
                    title: "Loop to start",
                    detail: "Glide the cursor home for seamless loops",
                    isOn: binding(\.cursor.loopToStart)
                )
                InspectorToggle(
                    title: "Clip to recording",
                    detail: "Keep the cursor inside the screen frame",
                    isOn: binding(\.cursor.clipToBounds)
                )
            }
        }
    }

    private var cameraTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Camera layer") {
                if document.project.source.webcamPath == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "webcam.slash")
                            .foregroundStyle(Theme.warning)
                        Text("This recording has no camera track. Camera capture is not connected in this build; settings below persist for imported projects.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                InspectorToggle(
                    title: "Enable camera",
                    detail: "Picture-in-picture and camera layouts",
                    isOn: binding(\.camera.enabled)
                )

                HStack {
                    Text("Mask")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Mask", selection: binding(\.camera.mask)) {
                        ForEach(WebcamMaskShape.allCases, id: \.self) { shape in
                            Text(shape.label).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                InspectorSlider(
                    title: "Overlay size",
                    value: binding(\.camera.sizeFraction),
                    range: 0.08...0.5,
                    format: percent
                )
                InspectorSlider(
                    title: "Shadow",
                    value: binding(\.camera.shadowOpacity),
                    range: 0...1,
                    format: percent
                )
            }

            InspectorSection("Behavior") {
                InspectorToggle(
                    title: "Mirror camera",
                    detail: "Match the familiar selfie view",
                    isOn: binding(\.camera.mirrored)
                )
                InspectorToggle(
                    title: "Reactive zoom",
                    detail: "Shrink the overlay as the screen zooms",
                    isOn: binding(\.camera.reactiveZoom)
                )
                InspectorToggle(
                    title: "Face tracking",
                    detail: "Keep the speaker centered",
                    isOn: binding(\.camera.faceTracking)
                )
                InspectorToggle(
                    title: "Hide during silence",
                    detail: "Fade the camera out when nobody speaks",
                    isOn: binding(\.camera.hideDuringSilence)
                )
            }
        }
    }

    private var captionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Captions") {
                InspectorToggle(
                    title: "Burn in captions",
                    detail: "Styled word-by-word subtitles",
                    isOn: binding(\.captions.enabled)
                )

                if document.transcript == nil {
                    Text("Generate a transcript in the Transcript section below to see captions in the preview and export.")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Style")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Style", selection: binding(\.captions.style)) {
                        ForEach(CaptionStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                HStack {
                    Text("Position")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Position", selection: binding(\.captions.position)) {
                        ForEach(CaptionPosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                Stepper(
                    value: binding(\.captions.wordsPerLine),
                    in: 1...12
                ) {
                    HStack {
                        Text("Words per line")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(document.project.captions.wordsPerLine)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                InspectorSlider(
                    title: "Font scale",
                    value: binding(\.captions.fontScale),
                    range: 0.5...2.5,
                    format: { String(format: "%.2f×", $0) }
                )
                InspectorToggle(
                    title: "Uppercase",
                    detail: "Render every caption in capitals",
                    isOn: binding(\.captions.uppercase)
                )

                TextField("Language (BCP-47)", text: binding(\.captions.language))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.background)
                    )
            }

            InspectorSection("Transcript") {
                if let transcript = document.transcript {
                    HStack(spacing: 6) {
                        Text("\(transcript.words.count) words")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(transcript.engine)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    InspectorToggle(
                        title: "Remove filler words",
                        detail: "Cut um, uh, erm, and filler “like”",
                        isOn: Binding(
                            get: { document.project.timeline.transcriptEdits.contains { $0.kind == .removeFiller } },
                            set: { document.setRemoveFillers($0) }
                        )
                    )

                    InspectorToggle(
                        title: "Compress long pauses",
                        detail: "Keep 120 ms of air around each cut",
                        isOn: Binding(
                            get: { document.project.timeline.transcriptEdits.contains { $0.kind == .removePause } },
                            set: { document.setRemovePauses($0) }
                        )
                    )

                    Text("\(document.captionCues.count) caption lines · \(document.project.timeline.trims.count) cuts")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)

                    Button {
                        Task { await document.generateTranscript() }
                    } label: {
                        Label("Re-run transcription", systemImage: "waveform")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(document.isTranscribing)
                } else {
                    Text("Transcribe the voice track on this Mac to edit by words and burn in captions.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Task { await document.generateTranscript() }
                    } label: {
                        Label(
                            document.isTranscribing ? "Transcribing…" : "Generate transcript",
                            systemImage: "waveform"
                        )
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(document.isTranscribing)

                    if let status = document.transcriptionStatus {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var exportTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Video") {
                Picker("Resolution", selection: binding(\.export.resolution)) {
                    ForEach(ExportResolution.allCases, id: \.self) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if document.project.export.resolution == .custom {
                    Stepper(
                        value: Binding(
                            get: { document.project.export.customLongEdge ?? 1920 },
                            set: { value in
                                document.apply { $0.export.customLongEdge = value }
                            }
                        ),
                        in: 480...7_680,
                        step: 120
                    ) {
                        HStack {
                            Text("Long edge")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(document.project.export.customLongEdge ?? 1920) px")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }

                HStack {
                    Text("Frame rate")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Frame rate", selection: binding(\.export.fps)) {
                        Text("24").tag(24)
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack {
                    Text("Codec")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Codec", selection: binding(\.export.codec)) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.label).tag(codec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }

                InspectorSlider(
                    title: "Quality",
                    value: binding(\.export.quality),
                    range: 0.1...1,
                    format: percent
                )
                InspectorToggle(
                    title: "Include audio",
                    detail: "Mix the microphone and system sound",
                    isOn: binding(\.export.includeAudio)
                )
            }

            InspectorSection("Deliver") {
                if app.isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(app.exportProgress?.phase.label ?? "Exporting")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(String(format: "%.0f%%", (app.exportProgress?.fraction ?? 0) * 100))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ProgressView(value: app.exportProgress?.fraction ?? 0)
                            .tint(Theme.accent)
                        Text(app.exportProgress?.message ?? "")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        Button("Cancel export") { app.cancelExport() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.danger)
                    }
                } else {
                    Button {
                        app.exportCurrentProject(format: .mp4)
                    } label: {
                        Label("Export MP4", systemImage: "film")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        app.exportCurrentProject(format: .gif)
                    } label: {
                        Label("Export GIF", systemImage: "photo.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
                } label: {
                    Label("Reveal project in Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<ScreenForgeProject, T>) -> Binding<T> {
        Binding(
            get: { document.project[keyPath: keyPath] },
            set: { value in
                document.apply { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func zoomBinding<T>(
        _ keyPath: WritableKeyPath<ZoomRegion, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedZoom?[keyPath: keyPath] ?? fallback },
            set: { value in updateZoom { $0[keyPath: keyPath] = value } }
        )
    }

    private func speedBinding<T>(
        _ keyPath: WritableKeyPath<SpeedRegion, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedSpeed?[keyPath: keyPath] ?? fallback },
            set: { value in updateSpeed { $0[keyPath: keyPath] = value } }
        )
    }

    private func layoutBinding<T>(
        _ keyPath: WritableKeyPath<LayoutRegion, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedLayout?[keyPath: keyPath] ?? fallback },
            set: { value in updateLayout { $0[keyPath: keyPath] = value } }
        )
    }

    private func annotationBinding<T>(
        _ keyPath: WritableKeyPath<AnnotationRegion, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedAnnotation?[keyPath: keyPath] ?? fallback },
            set: { value in updateAnnotation { $0[keyPath: keyPath] = value } }
        )
    }

    private var annotationTextBinding: Binding<String> {
        Binding(
            get: { document.selectedAnnotation?.text ?? "" },
            set: { value in updateAnnotation { $0.text = value } }
        )
    }

    private func updateZoom(_ mutation: @escaping (inout ZoomRegion) -> Void) {
        guard let id = document.selectedZoomID else { return }
        document.apply { project in
            guard let index = project.timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
            mutation(&project.timeline.zooms[index])
        }
    }

    private func updateSpeed(_ mutation: @escaping (inout SpeedRegion) -> Void) {
        guard let id = document.selectedSpeedID else { return }
        document.apply { project in
            guard let index = project.timeline.speeds.firstIndex(where: { $0.id == id }) else { return }
            mutation(&project.timeline.speeds[index])
        }
    }

    private func updateLayout(_ mutation: @escaping (inout LayoutRegion) -> Void) {
        guard let id = document.selectedLayoutID else { return }
        document.apply { project in
            guard let index = project.timeline.layouts.firstIndex(where: { $0.id == id }) else { return }
            mutation(&project.timeline.layouts[index])
        }
    }

    private func updateAnnotation(_ mutation: @escaping (inout AnnotationRegion) -> Void) {
        guard let id = document.selectedAnnotationID else { return }
        document.apply { project in
            guard let index = project.timeline.annotations.firstIndex(where: { $0.id == id }) else { return }
            mutation(&project.timeline.annotations[index])
        }
    }

    // MARK: - Playhead edits

    private var playheadSourceMs: Int {
        Int(document.map.sourceTime(forOutputMs: playback.outputTimeMs) ?? playback.outputTimeMs)
    }

    private func setZoomStartAtPlayhead() {
        let source = playheadSourceMs
        updateZoom { $0.startMs = min(max(source, 0), $0.endMs - 200) }
    }

    private func setZoomEndAtPlayhead() {
        let source = playheadSourceMs
        updateZoom { $0.endMs = max(min(source, document.project.source.durationMs), $0.startMs + 200) }
    }

    private func setAnnotationStartAtPlayhead() {
        let source = playheadSourceMs
        updateAnnotation { $0.startMs = min(max(source, 0), $0.endMs - 100) }
    }

    private func setAnnotationEndAtPlayhead() {
        let source = playheadSourceMs
        updateAnnotation { $0.endMs = max(min(source, document.project.source.durationMs), $0.startMs + 100) }
    }

    private func setSpeedStartAtPlayhead() {
        let source = playheadSourceMs
        updateSpeed { $0.startMs = min(max(source, 0), $0.endMs - 100) }
    }

    private func setSpeedEndAtPlayhead() {
        let source = playheadSourceMs
        updateSpeed { $0.endMs = max(min(source, document.project.source.durationMs), $0.startMs + 100) }
    }

    // MARK: - Formatting

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    // MARK: - Background presets

    fileprivate struct BackgroundPreset: Identifiable {
        let id: String
        let name: String
        let kind: BackgroundStyle.Kind
        let colors: [String]
    }

    private static let backgroundPresets: [BackgroundPreset] = [
        BackgroundPreset(id: "midnight", name: "Midnight", kind: .gradient, colors: ["#141E30", "#243B55"]),
        BackgroundPreset(id: "aurora", name: "Aurora", kind: .gradient, colors: ["#00C6FF", "#6A11CB"]),
        BackgroundPreset(id: "sunset", name: "Sunset", kind: .gradient, colors: ["#FF512F", "#DD2476"]),
        BackgroundPreset(id: "moss", name: "Moss", kind: .gradient, colors: ["#134E5E", "#71B280"]),
        BackgroundPreset(id: "ink", name: "Ink", kind: .gradient, colors: ["#0F0C29", "#302B63"]),
        BackgroundPreset(id: "sand", name: "Sand", kind: .gradient, colors: ["#F2994A", "#F2C94C"]),
        BackgroundPreset(id: "screen-blur", name: "Screen blur", kind: .screenBlur, colors: ["#111318", "#08090C"]),
        BackgroundPreset(id: "black", name: "Black", kind: .solid, colors: ["#000000", "#000000"]),
        BackgroundPreset(id: "white", name: "White", kind: .solid, colors: ["#FFFFFF", "#FFFFFF"])
    ]
}

// MARK: - Controls

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).sectionLabel()
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.backgroundRaised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }
}

private struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(format(value))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
                .controlSize(.small)
        }
    }
}

private struct InspectorToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
    }
}

private struct BackgroundSwatch: View {
    let preset: InspectorView.BackgroundPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: preset.colors.map { Color(hexString: $0) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 34)
                    .overlay {
                        if preset.kind == .screenBlur {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                selected ? Theme.accent : Color.white.opacity(0.08),
                                lineWidth: selected ? 2 : 1
                            )
                    }

                Text(preset.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }
}
