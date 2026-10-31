import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit

/// Rasterizes caption cues into images for the compositor.
///
/// Kept separate from `Compositor` so the typography can be rendered and inspected
/// without a GPU (unit tests render to bitmap and check coverage). The compositor
/// uploads the result and draws it as a textured quad.
public enum CaptionRasterizer {
    /// Font height as a fraction of the canvas height, before `fontScale`.
    static let baseFontFraction = 0.046
    /// Horizontal inset inside the caption box.
    static let horizontalInsetFraction = 0.04

    // MARK: - Images

    public static func makeImage(
        cue: CaptionCue,
        activeWordIndex: Int?,
        settings: CaptionSettings,
        canvasSize: CGSize,
        pixelScale: Double = 1
    ) -> CGImage? {
        guard !cue.text.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let box = CaptionGeometry.overlayRect(canvas: canvasSize, position: settings.position)
        let width = max(Int((box.width * pixelScale).rounded()), 16)
        let height = max(Int((box.height * pixelScale).rounded()), 16)
        guard width <= 4_096, height <= 2_048 else { return nil }

        let text = settings.uppercase ? cue.text.uppercased() : cue.text
        let fontSize = max(canvasSize.height * baseFontFraction * settings.fontScale * pixelScale, 6)
        let attributed = attributedText(
            text: text,
            cue: cue,
            activeWordIndex: settings.style == .karaoke ? activeWordIndex : nil,
            style: settings.style,
            fontSize: fontSize,
            uppercased: settings.uppercase
        )

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        drawBackground(in: context, size: CGSize(width: width, height: height), style: settings.style)

        let inset = CGFloat(width) * horizontalInsetFraction
        let textRect = CGRect(
            x: inset,
            y: CGFloat(height) * 0.12,
            width: CGFloat(width) - inset * 2,
            height: CGFloat(height) * 0.76
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        // Core Text draws from the bottom-left; the bitmap is flipped afterwards.
        CTFrameDraw(frame, context)
        context.restoreGState()

        guard let drawn = context.makeImage() else { return nil }
        return flipVertically(drawn)
    }

    /// Uploads a rasterized cue for the compositor.
    public static func makeTexture(
        cue: CaptionCue,
        activeWordIndex: Int?,
        settings: CaptionSettings,
        canvasSize: CGSize,
        pixelScale: Double,
        device: MTLDevice
    ) -> MTLTexture? {
        guard let image = makeImage(
            cue: cue,
            activeWordIndex: activeWordIndex,
            settings: settings,
            canvasSize: canvasSize,
            pixelScale: pixelScale
        ) else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        return try? loader.newTexture(cgImage: image, options: options)
    }

    /// Non-transparent pixel count, used by tests and the export self-check.
    public static func opaquePixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 3, to: data.count, by: 4) where data[index] > 8 {
            count += 1
        }
        return count
    }

    // MARK: - Typography

    private static func attributedText(
        text: String,
        cue: CaptionCue,
        activeWordIndex: Int?,
        style: CaptionStyle,
        fontSize: Double,
        uppercased: Bool
    ) -> NSAttributedString {
        let weight = weight(for: style)
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let foreground = foregroundColor(for: style)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)

        switch style {
        case .outline, .bold:
            attributed.addAttributes([
                .strokeColor: NSColor.black,
                .strokeWidth: -3.0
            ], range: NSRange(location: 0, length: attributed.length))

        case .plain:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = fontSize * 0.18
            shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.05)
            attributed.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: attributed.length))

        case .karaoke:
            if let activeWordIndex, cue.wordTimings.indices.contains(activeWordIndex) {
                // Words are joined with single spaces, so ranges can be accumulated.
                var location = 0
                for (index, timing) in cue.wordTimings.enumerated() {
                    let displayWord = uppercased ? timing.text.uppercased() : timing.text
                    let length = (displayWord as NSString).length
                    if index == activeWordIndex {
                        let range = NSRange(location: location, length: length)
                        if NSMaxRange(range) <= attributed.length {
                            attributed.addAttribute(
                                .foregroundColor,
                                value: NSColor(calibratedRed: 1, green: 0.84, blue: 0.2, alpha: 1),
                                range: range
                            )
                        }
                        break
                    }
                    location += length + 1
                }
            }

        case .minimal, .pill:
            break
        }

        return attributed
    }

    private static func weight(for style: CaptionStyle) -> NSFont.Weight {
        switch style {
        case .bold: .heavy
        case .minimal: .regular
        case .plain, .outline, .pill, .karaoke: .semibold
        }
    }

    private static func foregroundColor(for style: CaptionStyle) -> NSColor {
        switch style {
        case .minimal: NSColor.white.withAlphaComponent(0.88)
        default: .white
        }
    }

    private static func drawBackground(in context: CGContext, size: CGSize, style: CaptionStyle) {
        switch style {
        case .pill, .karaoke:
            let rect = CGRect(origin: .zero, size: size)
            let radius = min(size.height * 0.3, 40)
            let path = CGPath(
                roundedRect: rect.insetBy(dx: size.width * 0.01, dy: size.height * 0.04),
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            context.fillPath()

        case .plain, .outline, .bold, .minimal:
            break
        }
    }

    // MARK: - Bitmap

    private static func flipVertically(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
