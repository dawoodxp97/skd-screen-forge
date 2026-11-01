import SwiftUI

/// Output-time timeline: ruler, zoom/speed/annotation lanes, and a draggable playhead.
/// Times shown are always output times; region spans are projected through `TimelineMap`.
struct TimelineView: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var playback: PlaybackEngine

    @State private var isScrubbing = false
    @State private var hoveredRegion: String?

    private let inset: CGFloat = 14
    private let rulerHeight: CGFloat = 26
    private let markerLaneY: CGFloat = 30
    private let markerLaneHeight: CGFloat = 16
    private let zoomLaneY: CGFloat = 50
    private let zoomLaneHeight: CGFloat = 28
    private let noteLaneY: CGFloat = 82
    private let noteLaneHeight: CGFloat = 22
    private let speedLaneY: CGFloat = 108
    private let speedLaneHeight: CGFloat = 16
    private let audioLaneY: CGFloat = 128
    private let audioLaneHeight: CGFloat = 22
    private let height: CGFloat = 158

    private var durationMs: Double {
        max(playback.durationMs, document.outputDurationMs, 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            transport
            GeometryReader { geometry in
                let laneWidth = max(geometry.size.width - inset * 2, 1)
                ZStack(alignment: .topLeading) {
                    lanes(width: laneWidth)
                    ruler(width: laneWidth)
                    regionViews(width: laneWidth)
                    playhead(width: laneWidth, height: geometry.size.height)

                    Color.clear
                        .frame(width: geometry.size.width, height: rulerHeight + 8)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isScrubbing {
                                        isScrubbing = true
                                        playback.pause()
                                    }
                                    scrub(toX: value.location.x, width: laneWidth)
                                }
                                .onEnded { _ in
                                    isScrubbing = false
                                }
                        )
                }
            }
            .frame(height: height)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Pause" : "Play")

            Text(preciseTime(playback.outputTimeMs))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text("/")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(timeLabel(durationMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            HStack(spacing: 7) {
                legendDot(Theme.accent, "Zoom")
                legendDot(Theme.warning, "Speed")
                legendDot(Color(hex: 0xB48CFF), "Note")
                legendDot(Theme.success, "Layout")
                legendDot(.yellow, "Marker")
                legendDot(.teal, "Audio")
            }

            Divider()
                .frame(height: 18)
                .overlay(Theme.stroke)

            Button {
                document.addZoomAtPlayhead(outputMs: playback.outputTimeMs)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(TimelineIconButtonStyle())
            .help("Add a zoom at the playhead")

            Button {
                document.runAutoZoom()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(TimelineIconButtonStyle())
            .disabled(!document.hasCursorTelemetry)
            .help(document.hasCursorTelemetry
                  ? "Generate zooms from cursor activity"
                  : "No cursor telemetry in this recording")

            Menu {
                Button("Trim everything before playhead") {
                    document.trimStart(atOutputMs: playback.outputTimeMs)
                }
                Button("Trim everything after playhead") {
                    document.trimEnd(atOutputMs: playback.outputTimeMs)
                }
                if !document.project.timeline.speeds.isEmpty {
                    Divider()
                    Button("Remove all speed changes") {
                        document.apply { $0.timeline.speeds.removeAll() }
                    }
                }
                if !document.project.timeline.trims.isEmpty {
                    Button("Remove all trims") {
                        document.apply { $0.timeline.trims.removeAll() }
                    }
                }
            } label: {
                Image(systemName: "scissors")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Cut tools")

            Button {
                document.addMarker(
                    atOutputMs: playback.outputTimeMs,
                    label: "Marker \(document.project.timeline.markers.count + 1)"
                )
            } label: {
                Image(systemName: "bookmark")
            }
            .buttonStyle(TimelineIconButtonStyle())
            .help("Add a marker at the playhead (⌘M)")

            Menu {
                Button {
                    document.addTextAnnotation(atOutputMs: playback.outputTimeMs)
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                Button {
                    document.addCalloutAnnotation(type: .highlight, atOutputMs: playback.outputTimeMs)
                } label: {
                    Label("Highlight", systemImage: "rectangle.dashed")
                }
                Button {
                    document.addCalloutAnnotation(type: .blur, atOutputMs: playback.outputTimeMs)
                } label: {
                    Label("Mask", systemImage: "eye.slash")
                }
                Button {
                    document.addCalloutAnnotation(type: .figure, atOutputMs: playback.outputTimeMs)
                } label: {
                    Label("Shape", systemImage: "square.on.circle")
                }
            } label: {
                Image(systemName: "text.bubble")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Add an annotation at the playhead")
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Lanes

    private func lanes(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.backgroundRaised)
                .frame(width: width + inset * 2, height: height)
                .offset(x: 0, y: 0)

            laneBackground(width: width, y: markerLaneY, height: markerLaneHeight, tint: .yellow)
            laneBackground(width: width, y: zoomLaneY, height: zoomLaneHeight, tint: Theme.accent)
            laneBackground(width: width, y: noteLaneY, height: noteLaneHeight, tint: Color(hex: 0xB48CFF))
            laneBackground(width: width, y: speedLaneY, height: speedLaneHeight, tint: Theme.warning)
            laneBackground(width: width, y: audioLaneY, height: audioLaneHeight, tint: .teal)
        }
    }

    private func laneBackground(
        width: CGFloat,
        y: CGFloat,
        height: CGFloat,
        tint: Color
    ) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.05))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tint.opacity(0.08), lineWidth: 1)
            }
            .frame(width: width, height: height)
            .offset(x: inset, y: y)
    }

    // MARK: - Ruler

    private func ruler(width: CGFloat) -> some View {
        Canvas { context, size in
            let step = tickStep(width: width)
            let stepMs = step * 1000
            var time = 0.0
            while time <= durationMs + 0.5 {
                let x = inset + CGFloat(time / durationMs) * width
                var line = Path()
                line.move(to: CGPoint(x: x, y: rulerHeight - 7))
                line.addLine(to: CGPoint(x: x, y: rulerHeight - 1))
                context.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 1)

                let label = Text(timeLabel(time))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(label, at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)

                let minor = stepMs / 4
                for index in 1..<4 {
                    let minorX = inset + CGFloat((time + minor * Double(index)) / durationMs) * width
                    var tick = Path()
                    tick.move(to: CGPoint(x: minorX, y: rulerHeight - 4))
                    tick.addLine(to: CGPoint(x: minorX, y: rulerHeight - 1))
                    context.stroke(tick, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
                time += stepMs
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: inset, y: rulerHeight - 0.5))
            baseline.addLine(to: CGPoint(x: size.width - inset, y: rulerHeight - 0.5))
            context.stroke(baseline, with: .color(.white.opacity(0.10)), lineWidth: 1)
        }
        .frame(height: rulerHeight)
    }

    private func tickStep(width: CGFloat) -> Double {
        let seconds = durationMs / 1000
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let minimumPixels: CGFloat = 68
        for step in candidates {
            if Double(width) * (step / max(seconds, 0.001)) >= minimumPixels {
                return step
            }
        }
        return candidates.last ?? 600
    }

    // MARK: - Regions

    @ViewBuilder
    private func regionViews(width: CGFloat) -> some View {
        ForEach(document.project.timeline.zooms) { zoom in
            if let range = outputRange(sourceStart: zoom.startMs, sourceEnd: zoom.endMs) {
                chip(
                    title: zoomChipTitle(zoom),
                    color: Theme.accent,
                    selected: document.selectedZoomID == zoom.id,
                    startX: x(for: range.lowerBound, width: width),
                    chipWidth: chipWidth(range: range, width: width),
                    y: zoomLaneY + 3,
                    chipHeight: zoomLaneHeight - 6,
                    hovered: hoveredRegion == zoom.id
                ) {
                    selectZoom(zoom.id)
                } onDoubleTap: {
                    playback.seek(toOutputMs: range.lowerBound)
                } menu: {
                    Button("Go to start") { playback.seek(toOutputMs: range.lowerBound) }
                    Button("Delete zoom", role: .destructive) {
                        document.apply { $0.timeline.zooms.removeAll { $0.id == zoom.id } }
                        if document.selectedZoomID == zoom.id {
                            document.selectedZoomID = nil
                        }
                    }
                }
                .onHover { hoveredRegion = $0 ? zoom.id : (hoveredRegion == zoom.id ? nil : hoveredRegion) }
            }
        }

        ForEach(document.project.timeline.annotations) { annotation in
            if let range = outputRange(sourceStart: annotation.startMs, sourceEnd: annotation.endMs) {
                chip(
                    title: annotationTitle(annotation),
                    color: Color(hex: 0xB48CFF),
                    selected: document.selectedAnnotationID == annotation.id,
                    startX: x(for: range.lowerBound, width: width),
                    chipWidth: chipWidth(range: range, width: width),
                    y: noteLaneY + 2,
                    chipHeight: noteLaneHeight - 4,
                    hovered: hoveredRegion == annotation.id
                ) {
                    selectAnnotation(annotation.id)
                } onDoubleTap: {
                    playback.seek(toOutputMs: range.lowerBound)
                } menu: {
                    Button("Go to start") { playback.seek(toOutputMs: range.lowerBound) }
                    Button("Delete annotation", role: .destructive) {
                        document.apply {
                            $0.timeline.annotations.removeAll { $0.id == annotation.id }
                        }
                        if document.selectedAnnotationID == annotation.id {
                            document.selectedAnnotationID = nil
                        }
                    }
                }
                .onHover { hoveredRegion = $0 ? annotation.id : (hoveredRegion == annotation.id ? nil : hoveredRegion) }
            }
        }

        ForEach(document.project.timeline.speeds) { speed in
            if let range = outputRange(sourceStart: speed.startMs, sourceEnd: speed.endMs) {
                chip(
                    title: String(format: "%.2g×", speed.rate),
                    color: Theme.warning,
                    selected: document.selectedSpeedID == speed.id,
                    startX: x(for: range.lowerBound, width: width),
                    chipWidth: chipWidth(range: range, width: width),
                    y: speedLaneY + 1,
                    chipHeight: speedLaneHeight - 2,
                    hovered: hoveredRegion == speed.id
                ) {
                    selectSpeed(speed.id)
                } onDoubleTap: {
                    playback.seek(toOutputMs: range.lowerBound)
                } menu: {
                    Button("Go to start") { playback.seek(toOutputMs: range.lowerBound) }
                    Button("Delete speed change", role: .destructive) {
                        document.apply { $0.timeline.speeds.removeAll { $0.id == speed.id } }
                        if document.selectedSpeedID == speed.id {
                            document.selectedSpeedID = nil
                        }
                    }
                }
                .onHover { hoveredRegion = $0 ? speed.id : (hoveredRegion == speed.id ? nil : hoveredRegion) }
            }
        }

        // Audio clips are already in output time, so they map 1:1.
        ForEach(document.project.timeline.audioClips) { clip in
            let start = x(for: Double(clip.startMs), width: width)
            let end = x(for: Double(clip.endMs), width: width)
            chip(
                title: clip.muted ? "\(clip.label) (muted)" : clip.label,
                color: audioColor(clip.kind),
                selected: document.selectedAudioClipID == clip.id,
                startX: start,
                chipWidth: max(end - start, 30),
                y: audioLaneY + 2,
                chipHeight: audioLaneHeight - 4,
                hovered: hoveredRegion == clip.id
            ) {
                selectAudioClip(clip.id)
            } onDoubleTap: {
                playback.seek(toOutputMs: Double(clip.startMs))
            } menu: {
                Button("Go to start") { playback.seek(toOutputMs: Double(clip.startMs)) }
                Button(clip.muted ? "Unmute" : "Mute") {
                    document.apply { project in
                        guard let index = project.timeline.audioClips.firstIndex(where: { $0.id == clip.id }) else { return }
                        project.timeline.audioClips[index].muted.toggle()
                    }
                }
                Button("Delete clip", role: .destructive) {
                    document.deleteAudioClip(id: clip.id)
                }
            }
            .onHover { hoveredRegion = $0 ? clip.id : (hoveredRegion == clip.id ? nil : hoveredRegion) }
        }

        ForEach(document.project.timeline.markers) { marker in
            markerPin(marker, width: width)
        }
    }

    private func zoomChipTitle(_ zoom: ZoomRegion) -> String {
        let scale = String(format: "%.1f×", zoom.scale)
        return zoom.kind == .loupe ? "◎ \(scale)" : scale
    }

    private func audioColor(_ kind: AudioClipKind) -> Color {
        switch kind {
        case .voiceover: .teal
        case .music: Color(hex: 0x5AC8FA)
        case .soundEffect: Color(hex: 0xFF9F0A)
        case .external: Color(hex: 0x8E8E93)
        }
    }

    private func markerPin(_ marker: TimelineMarker, width: CGFloat) -> some View {
        let selected = document.selectedMarkerID == marker.id
        return VStack(spacing: 0) {
            Image(systemName: marker.kind.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(selected ? .black : Color(hexString: marker.colorHex))
                .frame(width: 14, height: 14)
                .background(
                    Circle().fill(selected ? Color(hexString: marker.colorHex) : Color.black.opacity(0.55))
                )
            Rectangle()
                .fill(Color(hexString: marker.colorHex).opacity(0.8))
                .frame(width: 1, height: markerLaneHeight - 12)
        }
        .frame(width: 16)
        .offset(
            x: x(for: Double(marker.timeMs), width: width) - 8,
            y: markerLaneY - 1
        )
        .contentShape(Rectangle())
        .onTapGesture { selectMarker(marker.id) }
        .contextMenu {
            Button("Go to marker") { playback.seek(toOutputMs: Double(marker.timeMs)) }
            Button("Delete marker", role: .destructive) {
                document.deleteMarker(id: marker.id)
            }
        }
        .help("\(marker.kind.label) · \(marker.label) · \(timeLabel(Double(marker.timeMs)))")
    }

    private func chip<T: View>(
        title: String,
        color: Color,
        selected: Bool,
        startX: CGFloat,
        chipWidth: CGFloat,
        y: CGFloat,
        chipHeight: CGFloat,
        hovered: Bool,
        action: @escaping () -> Void,
        onDoubleTap: @escaping () -> Void,
        @ViewBuilder menu: () -> T
    ) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(selected ? .white : Theme.textPrimary.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: chipWidth, height: chipHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(selected ? 0.55 : (hovered ? 0.30 : 0.20)))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(color.opacity(selected ? 0.9 : 0.35), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture { action() }
            .contextMenu(menuItems: menu)
            .offset(x: startX, y: y)
            .help(title)
    }

    // MARK: - Playhead

    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let progress = min(max(playback.outputTimeMs / durationMs, 0), 1)
        let x = inset + CGFloat(progress) * width
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 1)
                .shadow(color: .white.opacity(0.6), radius: 3)

            Path { path in
                path.move(to: CGPoint(x: -5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.closeSubpath()
            }
            .fill(.white)
            .frame(width: 10, height: 7)
        }
        .frame(width: 12, height: height)
        .offset(x: x - 6, y: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Selection

    private func selectZoom(_ id: String) {
        document.selectedZoomID = id
        document.selectedAnnotationID = nil
        document.selectedSpeedID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
        document.selectedMarkerID = nil
        document.selectedAudioClipID = nil
    }

    private func selectAnnotation(_ id: String) {
        document.selectedAnnotationID = id
        document.selectedZoomID = nil
        document.selectedSpeedID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
        document.selectedMarkerID = nil
        document.selectedAudioClipID = nil
    }

    private func selectSpeed(_ id: String) {
        document.selectedSpeedID = id
        document.selectedZoomID = nil
        document.selectedAnnotationID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
        document.selectedMarkerID = nil
        document.selectedAudioClipID = nil
    }

    private func selectMarker(_ id: String) {
        document.selectedMarkerID = id
        document.selectedZoomID = nil
        document.selectedAnnotationID = nil
        document.selectedSpeedID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
        document.selectedAudioClipID = nil
    }

    private func selectAudioClip(_ id: String) {
        document.selectedAudioClipID = id
        document.selectedZoomID = nil
        document.selectedAnnotationID = nil
        document.selectedSpeedID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
        document.selectedMarkerID = nil
    }

    // MARK: - Mapping

    private func x(for outputMs: Double, width: CGFloat) -> CGFloat {
        inset + CGFloat(min(max(outputMs / durationMs, 0), 1)) * width
    }

    private func chipWidth(range: ClosedRange<Double>, width: CGFloat) -> CGFloat {
        max(CGFloat((range.upperBound - range.lowerBound) / durationMs) * width, 30)
    }

    /// Projects a source-time region onto the output timeline. Regions whose
    /// endpoints fall inside a trim are clamped to the nearest surviving edit.
    private func outputRange(sourceStart: Int, sourceEnd: Int) -> ClosedRange<Double>? {
        guard sourceEnd > sourceStart else { return nil }
        let map = document.map
        let start = map.outputTime(forSourceMs: Double(sourceStart))
            ?? map.segments.first(where: {
                !$0.isRemoved && $0.sourceEndMs > Double(sourceStart)
            })?.outputStartMs
        let end = map.outputTime(forSourceMs: Double(sourceEnd))
            ?? map.segments.last(where: {
                !$0.isRemoved && $0.sourceStartMs < Double(sourceEnd)
            })?.outputEndMs
        guard let start, let end, end > start else { return nil }
        return start...end
    }

    private func scrub(toX x: CGFloat, width: CGFloat) {
        let progress = min(max((x - inset) / max(width, 1), 0), 1)
        playback.seek(toOutputMs: progress * durationMs)
    }

    private func annotationTitle(_ annotation: AnnotationRegion) -> String {
        if let text = annotation.text, !text.isEmpty {
            return text
        }
        return annotation.type.label
    }

    private func timeLabel(_ milliseconds: Double) -> String {
        let seconds = max(Int((milliseconds / 1000).rounded(.down)), 0)
        let minutes = seconds / 60
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    private func preciseTime(_ milliseconds: Double) -> String {
        let clamped = max(milliseconds, 0)
        let minutes = Int(clamped / 60_000)
        let seconds = Int(clamped / 1000) % 60
        let tenths = Int(clamped.truncatingRemainder(dividingBy: 1000) / 100)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

private struct TimelineIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.05))
            )
            .contentShape(Rectangle())
    }
}
