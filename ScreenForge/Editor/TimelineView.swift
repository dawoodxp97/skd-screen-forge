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
    private let zoomLaneY: CGFloat = 36
    private let noteLaneY: CGFloat = 72
    private let speedLaneY: CGFloat = 104
    private let height: CGFloat = 132

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
            .help("Generate zooms from cursor activity")

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
                document.addTextAnnotation(atOutputMs: playback.outputTimeMs)
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(TimelineIconButtonStyle())
            .help("Add a text annotation at the playhead")
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

            laneBackground(width: width, y: zoomLaneY, height: 30, tint: Theme.accent)
            laneBackground(width: width, y: noteLaneY, height: 26, tint: Color(hex: 0xB48CFF))
            laneBackground(width: width, y: speedLaneY, height: 20, tint: Theme.warning)
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
                    title: String(format: "%.1f×", zoom.scale),
                    color: Theme.accent,
                    selected: document.selectedZoomID == zoom.id,
                    startX: x(for: range.lowerBound, width: width),
                    chipWidth: chipWidth(range: range, width: width),
                    y: zoomLaneY + 3,
                    chipHeight: 24,
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
                    y: noteLaneY + 3,
                    chipHeight: 20,
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
                    y: speedLaneY + 2,
                    chipHeight: 16,
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
    }

    private func selectAnnotation(_ id: String) {
        document.selectedAnnotationID = id
        document.selectedZoomID = nil
        document.selectedSpeedID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
    }

    private func selectSpeed(_ id: String) {
        document.selectedSpeedID = id
        document.selectedZoomID = nil
        document.selectedAnnotationID = nil
        document.selectedLayoutID = nil
        document.selectedTrimID = nil
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
