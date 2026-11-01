import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-hand inspector for the open project. Continuous controls write through
/// `ProjectDocument.apply`, so every change is normalized, autosaved, and undoable.
struct InspectorView: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var playback: PlaybackEngine
    @EnvironmentObject private var app: AppState

    @State private var tab: Tab = .zoom
    @State private var wallpaperCategory = "macOS"
    @State private var presetName = ""
    @State private var sensitivePhrases = ""

    enum Tab: String, CaseIterable, Identifiable {
        case zoom
        case style
        case cursor
        case camera
        case audio
        case captions
        case export

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .zoom: "magnifyingglass"
            case .style: "paintbrush.pointed"
            case .cursor: "cursorarrow"
            case .camera: "person.crop.square"
            case .audio: "waveform"
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
            case .audio: "Audio"
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
        if document.selectedAudioClip != nil {
            audioClipEditor
        } else if document.selectedMarker != nil {
            markerEditor
        } else if document.selectedAnnotation != nil {
            annotationEditor
        } else if document.selectedSpeed != nil {
            speedEditor
        } else if document.selectedLayout != nil {
            layoutEditor
        }
    }

    private var markerEditor: some View {
        InspectorSection("Selected marker") {
            if let marker = document.selectedMarker {
                TextField("Label", text: markerBinding(\.label, fallback: "Marker"))
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

                Picker("Kind", selection: markerBinding(\.kind, fallback: .marker)) {
                    ForEach(TimelineMarkerKind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("At \(timeLabel(marker.timeMs)) · output time")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Button("Move to playhead") {
                    document.apply { project in
                        guard let index = project.timeline.markers.firstIndex(where: { $0.id == marker.id }) else { return }
                        project.timeline.markers[index].timeMs = Int(playback.outputTimeMs)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(role: .destructive) {
                    document.deleteSelectedMarker()
                } label: {
                    Label("Delete marker", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
        }
    }

    private var audioClipEditor: some View {
        InspectorSection("Selected audio") {
            if let clip = document.selectedAudioClip {
                Text(clip.kind.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)

                TextField("Label", text: audioBinding(\.label, fallback: clip.kind.label))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.background)
                    )

                InspectorSlider(
                    title: "Volume",
                    value: audioBinding(\.volume, fallback: 1),
                    range: 0...2,
                    format: { String(format: "%.0f%%", $0 * 100) }
                )
                InspectorSlider(
                    title: "Fade in",
                    value: Binding(
                        get: { Double(document.selectedAudioClip?.fadeInMs ?? 0) },
                        set: { value in updateAudioClip { $0.fadeInMs = Int(value) } }
                    ),
                    range: 0...5_000,
                    format: { String(format: "%.2f s", $0 / 1000) }
                )
                InspectorSlider(
                    title: "Fade out",
                    value: Binding(
                        get: { Double(document.selectedAudioClip?.fadeOutMs ?? 0) },
                        set: { value in updateAudioClip { $0.fadeOutMs = Int(value) } }
                    ),
                    range: 0...5_000,
                    format: { String(format: "%.2f s", $0 / 1000) }
                )

                HStack(spacing: 8) {
                    Button("Start here") {
                        let start = Int(min(max(playback.outputTimeMs, 0), document.outputDurationMs))
                        updateAudioClip { $0.startMs = start }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button(clip.loops ? "Looping" : "Loop") {
                        updateAudioClip { $0.loops.toggle() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                InspectorToggle(
                    title: "Mute clip",
                    detail: "Keep it on the timeline but silent",
                    isOn: audioBinding(\.muted, fallback: false)
                )

                Text("\(timeLabel(clip.startMs)) → \(timeLabel(clip.endMs))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Button(role: .destructive) {
                    document.deleteSelectedAudioClip()
                } label: {
                    Label("Delete clip", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
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
        case .audio: audioTab
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
                .disabled(!document.hasCursorTelemetry)

                if !document.hasCursorTelemetry {
                    Text("This recording has no cursor telemetry, so there is nothing to suggest from. Add zooms manually at the playhead.")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                    HStack {
                        Text("3D tilt")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker("3D tilt", selection: Binding(
                            get: { document.selectedZoom?.rotation },
                            set: { value in updateZoom { $0.rotation = value } }
                        )) {
                            Text("None").tag(Rotation3DPreset?.none)
                            ForEach(Rotation3DPreset.allCases, id: \.self) { preset in
                                Text(preset.label).tag(Rotation3DPreset?.some(preset))
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

                HStack(spacing: 8) {
                    Button {
                        importBackgroundPanel()
                    } label: {
                        Label("Image", systemImage: "photo")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        useCurrentWallpaper()
                    } label: {
                        Label("Wallpaper", systemImage: "desktopcomputer")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if document.project.canvas.background.kind == .solid ||
                    document.project.canvas.background.kind == .gradient {
                    ColorField(
                        title: document.project.canvas.background.kind == .solid ? "Fill" : "Top",
                        hex: colorBinding(index: 0)
                    )
                    if document.project.canvas.background.kind == .gradient {
                        ColorField(title: "Bottom", hex: colorBinding(index: 1))
                    }
                }

                if document.project.canvas.background.kind == .image,
                   let path = document.project.canvas.background.imagePath {
                    Text(path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            InspectorSection("Wallpaper pack") {
                Picker("Category", selection: $wallpaperCategory) {
                    ForEach(WallpaperLibrary.categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(WallpaperLibrary.presets(in: wallpaperCategory)) { preset in
                        Button {
                            Task { await document.applyWallpaper(preset) }
                        } label: {
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
                                        if document.project.canvas.background.identifier == preset.id {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(Theme.accent, lineWidth: 2)
                                        }
                                    }
                                Text(preset.name)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }

            InspectorSection("Motion & image") {
                InspectorSlider(
                    title: "Motion blur",
                    value: binding(\.canvas.motionBlur),
                    range: 0...1,
                    format: percent
                )
                InspectorToggle(
                    title: "Super resolution",
                    detail: "Edge-directed upscale when magnified",
                    isOn: binding(\.canvas.superResolution)
                )
            }

            InspectorSection("Color grading") {
                HStack {
                    Text("Look")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Look", selection: binding(\.canvas.grade.preset)) {
                        ForEach(ColorGradePreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                InspectorSlider(
                    title: "Intensity",
                    value: binding(\.canvas.grade.intensity),
                    range: 0...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Grain",
                    value: binding(\.canvas.grade.grain),
                    range: 0...1,
                    format: percent
                )
                InspectorSlider(
                    title: "Sharpen",
                    value: binding(\.canvas.grade.sharpen),
                    range: 0...1,
                    format: percent
                )
                HStack(spacing: 8) {
                    Button {
                        importLUTPanel()
                    } label: {
                        Label("Import .cube", systemImage: "cube.transparent")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if document.project.canvas.grade.lutPath != nil {
                        Button("Clear LUT") { document.clearLUT() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let path = document.project.canvas.grade.lutPath {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            InspectorSection("Device mockup") {
                HStack {
                    Text("Frame")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Frame", selection: binding(\.canvas.deviceMockup.kind)) {
                        ForEach(DeviceMockupKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                Menu {
                    ForEach(DeviceMockupPreset.all) { preset in
                        Button(preset.name) {
                            document.apply { $0.canvas.deviceMockup = preset.mockup }
                        }
                    }
                } label: {
                    Label(
                        document.project.canvas.deviceMockup.model ?? "Choose a model",
                        systemImage: "square.grid.2x2"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                if document.project.canvas.deviceMockup.kind != .none {
                    InspectorSlider(
                        title: "Bezel",
                        value: binding(\.canvas.deviceMockup.bezel),
                        range: 0.01...0.14,
                        format: percent
                    )
                    ColorField(title: "Body", hex: binding(\.canvas.deviceMockup.colorHex))
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
                InspectorSlider(
                    title: "Sharpen",
                    value: binding(\.camera.sharpen),
                    range: 0...1,
                    format: percent
                )

                HStack {
                    Text("Grade")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Grade", selection: binding(\.camera.grade.preset)) {
                        ForEach(ColorGradePreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            }

            InspectorSection("Person cutout") {
                InspectorToggle(
                    title: "Cut out the speaker",
                    detail: "Matte the camera so only the person is drawn",
                    isOn: binding(\.camera.cutout)
                )
                Text("\(document.project.analysis.personMasks.count) matte frames stored")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Button {
                    Task { await document.generatePersonMatte() }
                } label: {
                    Label("Build person matte", systemImage: "person.crop.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(document.isAnalyzing)
                .help("Runs Apple's on-device person segmentation over the camera track")
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

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Mixer") {
                InspectorSlider(
                    title: "Microphone",
                    value: binding(\.audio.microphoneVolume),
                    range: 0...2,
                    format: percent
                )
                InspectorSlider(
                    title: "System audio",
                    value: binding(\.audio.systemVolume),
                    range: 0...2,
                    format: percent
                )
                InspectorSlider(
                    title: "External device",
                    value: binding(\.audio.externalVolume),
                    range: 0...2,
                    format: percent
                )
                InspectorSlider(
                    title: "Music",
                    value: binding(\.audio.musicVolume),
                    range: 0...2,
                    format: percent
                )
                InspectorSlider(
                    title: "Voiceover",
                    value: binding(\.audio.voiceoverVolume),
                    range: 0...2,
                    format: percent
                )
                InspectorSlider(
                    title: "Sound effects",
                    value: binding(\.audio.soundEffectVolume),
                    range: 0...2,
                    format: percent
                )
            }

            InspectorSection("Ducking") {
                InspectorToggle(
                    title: "Duck music under voice",
                    detail: "Lower music while a voiceover plays",
                    isOn: binding(\.audio.duckMusicUnderVoice)
                )
                InspectorSlider(
                    title: "Duck amount",
                    value: binding(\.audio.duckAmount),
                    range: 0...1,
                    format: percent
                )
            }

            InspectorSection("Voice cleanup") {
                HStack {
                    Text("Enhancement")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Enhancement", selection: binding(\.audio.voiceEnhancement)) {
                        ForEach(VoiceEnhancementMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                InspectorSlider(
                    title: "Noise reduction",
                    value: binding(\.audio.noiseReduction),
                    range: 0...1,
                    format: percent
                )
                Text("High-pass · gate · presence EQ · compressor · limiter, rendered offline and cached. Preview and export share the same chain.")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InspectorSection("Click sounds") {
                HStack {
                    Text("Pack")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("Pack", selection: Binding(
                        get: { document.project.cursor.clickSound ?? "" },
                        set: { value in
                            document.apply {
                                $0.cursor.clickSound = value.isEmpty ? nil : value
                            }
                        }
                    )) {
                        Text("None").tag("")
                        ForEach(ClickSoundLibrary.packs) { pack in
                            Text(pack.name).tag(pack.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 170)
                }
                InspectorSlider(
                    title: "Volume",
                    value: binding(\.audio.clickSoundVolume),
                    range: 0...1,
                    format: percent
                )
                Button {
                    Task {
                        await document.addClickSounds(
                            packID: document.project.cursor.clickSound
                                ?? ClickSoundLibrary.packs[0].id
                        )
                    }
                } label: {
                    Label("Render click track", systemImage: "cursorarrow.click.2")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!document.hasCursorTelemetry)
            }

            InspectorSection("Voiceover") {
                if document.isRecordingVoiceover {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Recording voiceover…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Button("Stop and place") {
                        Task { await document.stopVoiceover() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { document.cancelVoiceover() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.danger)
                } else {
                    Text("Record narration from the playhead and place it on the audio lane.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await document.startVoiceover(atOutputMs: playback.outputTimeMs) }
                    } label: {
                        Label("Record voiceover", systemImage: "mic.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            InspectorSection("Clips") {
                HStack(spacing: 8) {
                    Button {
                        importAudioPanel(kind: .music)
                    } label: {
                        Label("Music", systemImage: "music.note")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        importAudioPanel(kind: .soundEffect)
                    } label: {
                        Label("Sound", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if document.project.timeline.audioClips.isEmpty {
                    Text("No audio clips yet. Music and sound effects are mixed with the recorded tracks at export.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(document.project.timeline.audioClips) { clip in
                        HStack(spacing: 7) {
                            Image(systemName: clip.kind.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                            Text(clip.label)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(timeLabel(clip.startMs))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            document.selectedAudioClipID = clip.id
                            document.selectedMarkerID = nil
                            document.selectedAnnotationID = nil
                            document.selectedZoomID = nil
                        }
                    }
                }
            }

            InspectorSection("Analysis") {
                Text("Silence ranges fade the camera out automatically; face samples keep the speaker centered.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(document.project.analysis.silenceRanges.count) silent ranges · \(document.project.analysis.faceSamples.count) face samples")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    Task { await document.detectSilence() }
                } label: {
                    Label("Detect silence", systemImage: "waveform.badge.mic")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(document.isAnalyzing)

                Button {
                    Task { await document.analyzeFaces() }
                } label: {
                    Label("Analyze faces", systemImage: "person.crop.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(document.isAnalyzing)

                if let status = document.analysisStatus {
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            InspectorSection("Privacy scan") {
                Text("Detects faces and private text (emails, keys, numbers) and adds editable masks. Expands by 8 pt like Screen Studio.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Custom phrases, comma separated", text: $sensitivePhrases)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.background)
                    )
                Button {
                    let phrases = sensitivePhrases
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    Task {
                        await document.scanForSensitiveData(customPhrases: phrases)
                    }
                } label: {
                    Label("Scan for sensitive data", systemImage: "eye.slash")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(document.isScanningSensitiveData)

                if document.project.timeline.annotations.contains(where: { $0.generated == true }) {
                    Button("Remove auto masks") { document.clearGeneratedMasks() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.danger)
                }
            }

            InspectorSection("Markers") {
                if document.project.timeline.markers.isEmpty {
                    Text("Markers recorded live appear here. Add one at the playhead with ⌘M.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(document.project.timeline.markers) { marker in
                        HStack(spacing: 7) {
                            Image(systemName: marker.kind.symbol)
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hexString: marker.colorHex))
                            Text(marker.label)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(timeLabel(marker.timeMs))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            document.selectedMarkerID = marker.id
                            document.selectedAudioClipID = nil
                        }
                    }

                    Button("Promote to chapters") {
                        document.promoteMarkersToChapters()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
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
            InspectorSection("Presets") {
                Menu {
                    ForEach(ExportPreset.builtIn) { preset in
                        Button {
                            app.applyExportPreset(preset)
                        } label: {
                            Text("\(preset.name) — \(preset.detail)")
                        }
                    }
                } label: {
                    Label("Apply a preset", systemImage: "square.stack.3d.up")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)

                ForEach(ExportPreset.builtIn.filter { $0.matches(document.project.export) }) { preset in
                    Text(preset.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            InspectorSection("Project presets") {
                HStack(spacing: 8) {
                    TextField("Preset name", text: $presetName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.background)
                        )
                    Button {
                        Task {
                            await document.savePreset(named: presetName)
                            presetName = ""
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Save the current look as a preset")
                }

                if document.presets.isEmpty {
                    Text("Presets store canvas, camera, cursor, captions, audio mix, and export settings.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(document.presets) { preset in
                        HStack(spacing: 8) {
                            Button(preset.name) {
                                document.applyPreset(preset)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button {
                                Task { await document.deletePreset(preset) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }

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
                        Text("10").tag(10)
                        Text("24").tag(24)
                        Text("30").tag(30)
                        Text("50").tag(50)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
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
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                }

                Text("Delivers .\(document.project.export.fileExtension.uppercased())")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

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

                    HStack(spacing: 8) {
                        Button {
                            app.shareLastExport()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            Task { await app.createShareLink() }
                        } label: {
                            Label("Copy link", systemImage: "link")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .disabled(app.lastExportURL == nil)
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

    private func markerBinding<T>(
        _ keyPath: WritableKeyPath<TimelineMarker, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedMarker?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let id = document.selectedMarkerID else { return }
                document.apply { project in
                    guard let index = project.timeline.markers.firstIndex(where: { $0.id == id }) else { return }
                    project.timeline.markers[index][keyPath: keyPath] = value
                }
            }
        )
    }

    private func audioBinding<T>(
        _ keyPath: WritableKeyPath<AudioClip, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { document.selectedAudioClip?[keyPath: keyPath] ?? fallback },
            set: { value in updateAudioClip { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateAudioClip(_ mutation: @escaping (inout AudioClip) -> Void) {
        guard let id = document.selectedAudioClipID else { return }
        document.apply { project in
            guard let index = project.timeline.audioClips.firstIndex(where: { $0.id == id }) else { return }
            mutation(&project.timeline.audioClips[index])
        }
    }

    private func colorBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                let colors = document.project.canvas.background.colors
                return colors.indices.contains(index) ? colors[index] : "#000000"
            },
            set: { value in
                document.apply { project in
                    var colors = project.canvas.background.colors
                    while colors.count <= index { colors.append("#000000") }
                    colors[index] = value
                    project.canvas.background.colors = colors
                }
            }
        )
    }

    private func importBackgroundPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await document.importBackgroundImage(from: url) }
    }

    private func useCurrentWallpaper() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            document.notice = "macOS did not report a desktop picture for this display."
            return
        }
        Task {
            await document.importBackgroundImage(from: url)
            document.apply { $0.canvas.background.identifier = "current-wallpaper" }
        }
    }

    private func importLUTPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a 3D LUT (.cube)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "cube") ?? .data
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await document.importLUT(from: url) }
    }

    private func importAudioPanel(kind: AudioClipKind) {        let panel = NSOpenPanel()
        panel.title = kind == .music ? "Import music" : "Import a sound effect"
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await document.importAudio(
                from: url,
                kind: kind,
                atOutputMs: playback.outputTimeMs
            )
        }
    }

    private func timeLabel(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

/// A hex color row: macOS color well plus the literal hex value for copy/paste.
private struct ColorField: View {
    let title: String
    @Binding var hex: String

    private var color: Binding<Color> {
        Binding(
            get: { Color(hexString: hex) },
            set: { newValue in
                let converted = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                hex = String(
                    format: "#%02X%02X%02X",
                    Int((converted.redComponent * 255).rounded()),
                    Int((converted.greenComponent * 255).rounded()),
                    Int((converted.blueComponent * 255).rounded())
                )
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(hex.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
        }
    }
}

private struct BackgroundSwatch: View {    let preset: InspectorView.BackgroundPreset
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
