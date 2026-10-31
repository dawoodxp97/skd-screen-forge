import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit

/// Rasterizes text annotations into Metal textures.
///
/// Text is laid out with Core Text at output resolution, then flipped into a
/// top-left-origin bitmap so the compositor can sample it with plain UVs.
public enum AnnotationTextureFactory {
    public static let maximumCacheDimension = 2_048

    public static func makeTexture(
        for annotation: AnnotationRegion,
        canvasSize: CGSize,
        device: MTLDevice
    ) -> MTLTexture? {
        guard annotation.type == .text,
              let text = annotation.text,
              !text.isEmpty,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return nil
        }

        let maxWidth = max(Int((annotation.rect.width * canvasSize.width).rounded()), 32)
        let maxHeight = max(Int((annotation.rect.height * canvasSize.height).rounded()), 32)
        guard maxWidth <= maximumCacheDimension, maxHeight <= maximumCacheDimension else { return nil }

        let scale = max(canvasSize.height / 1_080.0, 0.35)
        let padding = max(12 * scale, 4)
        let fontSize = max(annotation.style.fontSize * scale, 8)

        let weight: NSFont.Weight = annotation.style.isBold ? .semibold : .regular
        var font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        if annotation.style.isItalic,
           let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as NSFont? {
            font = italic
        }

        let paragraph = NSMutableParagraphStyle()
        switch annotation.style.alignment {
        case "left": paragraph.alignment = .left
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .center
        }

        let foreground = ColorHex.nsColor(annotation.style.colorHex)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph
            ]
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(
            width: CGFloat(maxWidth) - padding * 2,
            height: CGFloat(maxHeight) - padding * 2
        )
        guard constraint.width > 8, constraint.height > 8 else { return nil }

        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            &fitRange
        )
        let textWidth = min(ceil(suggested.width) + padding * 2, CGFloat(maxWidth))
        let textHeight = min(ceil(suggested.height) + padding * 2, CGFloat(maxHeight))
        guard textWidth > 2, textHeight > 2 else { return nil }

        guard let first = CGContext(
            data: nil,
            width: Int(textWidth),
            height: Int(textHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        first.clear(CGRect(x: 0, y: 0, width: textWidth, height: textHeight))
        first.setAllowsAntialiasing(true)
        first.setShouldSmoothFonts(true)

        if ColorHex.parse(annotation.style.backgroundHex).3 > 0.01 {
            let radius = min(12 * scale, min(textWidth, textHeight) * 0.2)
            let background = CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: textWidth, height: textHeight),
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            first.addPath(background)
            first.setFillColor(ColorHex.cgColor(annotation.style.backgroundHex))
            first.fillPath()
        }

        let textRect = CGRect(
            x: padding,
            y: padding,
            width: textWidth - padding * 2,
            height: textHeight - padding * 2
        )
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, first)

        guard let drawn = first.makeImage() else { return nil }

        // Flip into a top-left-origin bitmap.
        guard let flipped = CGContext(
            data: nil,
            width: Int(textWidth),
            height: Int(textHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        flipped.translateBy(x: 0, y: textHeight)
        flipped.scaleBy(x: 1, y: -1)
        flipped.draw(drawn, in: CGRect(x: 0, y: 0, width: textWidth, height: textHeight))

        guard let image = flipped.makeImage() else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        return try? loader.newTexture(cgImage: image, options: options)
    }
}
