import AppKit
import CoreGraphics
import Foundation
import Metal
import MetalKit

/// Rasterizes vector cursor artwork into Metal textures.
///
/// Artwork is drawn in a top-left coordinate space and uploaded with a top-left
/// origin so the shader can sample it with plain normalized UVs.
public enum CursorTextureFactory {
    public static let textureSize = 256

    public static func makeTexture(for theme: CursorTheme, device: MTLDevice) -> MTLTexture? {
        guard let image = makeImage(for: theme) else { return nil }
        return makeTexture(from: image, device: device)
    }

    // MARK: - Images

    public static func makeImage(for theme: CursorTheme) -> CGImage? {
        let size = CGFloat(textureSize)
        return render(size: size) { ctx in
            let scale = size / 100.0
            ctx.scaleBy(x: scale, y: scale)

            switch theme {
            case .systemArrow:
                drawArrow(in: ctx, fill: NSColor.black.cgColor, stroke: NSColor.white.cgColor, lineWidth: 5)
            case .filledArrow:
                drawArrow(in: ctx, fill: NSColor.white.cgColor, stroke: NSColor.black.cgColor, lineWidth: 4.5)
            case .outlinedArrow:
                drawArrow(in: ctx, fill: nil, stroke: NSColor.white.cgColor, lineWidth: 5)
            case .dot:
                drawDot(in: ctx)
            case .crosshair:
                drawCrosshair(in: ctx)
            case .hand:
                drawHand(in: ctx)
            }
        }
    }

    // MARK: - Shapes (100 × 100 design space)

    private static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12, y: 6))
        path.addLine(to: CGPoint(x: 12, y: 76))
        path.addLine(to: CGPoint(x: 29, y: 61))
        path.addLine(to: CGPoint(x: 42, y: 91))
        path.addLine(to: CGPoint(x: 56, y: 85))
        path.addLine(to: CGPoint(x: 43, y: 56))
        path.addLine(to: CGPoint(x: 65, y: 54))
        path.closeSubpath()
        return path
    }

    private static func drawArrow(in ctx: CGContext, fill: CGColor?, stroke: CGColor, lineWidth: CGFloat) {
        let path = arrowPath()
        ctx.addPath(path)
        if let fill {
            ctx.setFillColor(fill)
            ctx.fillPath()
            ctx.addPath(path)
        }
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    private static func drawDot(in ctx: CGContext) {
        let circle = CGRect(x: 25, y: 25, width: 50, height: 50)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: circle)
    }

    private static func drawCrosshair(in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineWidth(9)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.move(to: CGPoint(x: 50, y: 14))
        ctx.addLine(to: CGPoint(x: 50, y: 86))
        ctx.move(to: CGPoint(x: 14, y: 50))
        ctx.addLine(to: CGPoint(x: 86, y: 50))
        ctx.strokePath()

        ctx.setLineWidth(5)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.move(to: CGPoint(x: 50, y: 14))
        ctx.addLine(to: CGPoint(x: 50, y: 86))
        ctx.move(to: CGPoint(x: 14, y: 50))
        ctx.addLine(to: CGPoint(x: 86, y: 50))
        ctx.strokePath()
    }

    private static func drawHand(in ctx: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 38, y: 78))
        path.addCurve(
            to: CGPoint(x: 48, y: 61),
            control1: CGPoint(x: 39, y: 70),
            control2: CGPoint(x: 43, y: 65)
        )
        path.addLine(to: CGPoint(x: 48, y: 28))
        path.addCurve(
            to: CGPoint(x: 56, y: 24),
            control1: CGPoint(x: 48, y: 22),
            control2: CGPoint(x: 56, y: 18)
        )
        path.addLine(to: CGPoint(x: 56, y: 50))
        path.addLine(to: CGPoint(x: 60, y: 50))
        path.addLine(to: CGPoint(x: 60, y: 22))
        path.addCurve(
            to: CGPoint(x: 68, y: 22),
            control1: CGPoint(x: 60, y: 15),
            control2: CGPoint(x: 68, y: 15)
        )
        path.addLine(to: CGPoint(x: 68, y: 50))
        path.addLine(to: CGPoint(x: 72, y: 50))
        path.addLine(to: CGPoint(x: 72, y: 27))
        path.addCurve(
            to: CGPoint(x: 80, y: 27),
            control1: CGPoint(x: 72, y: 20),
            control2: CGPoint(x: 80, y: 20)
        )
        path.addLine(to: CGPoint(x: 80, y: 52))
        path.addLine(to: CGPoint(x: 84, y: 52))
        path.addLine(to: CGPoint(x: 84, y: 38))
        path.addCurve(
            to: CGPoint(x: 92, y: 38),
            control1: CGPoint(x: 84, y: 31),
            control2: CGPoint(x: 92, y: 31)
        )
        path.addLine(to: CGPoint(x: 92, y: 66))
        path.addCurve(
            to: CGPoint(x: 74, y: 92),
            control1: CGPoint(x: 92, y: 82),
            control2: CGPoint(x: 85, y: 92)
        )
        path.addLine(to: CGPoint(x: 60, y: 92))
        path.addCurve(
            to: CGPoint(x: 38, y: 78),
            control1: CGPoint(x: 52, y: 92),
            control2: CGPoint(x: 44, y: 88)
        )
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(4)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // MARK: - Rendering

    /// Draws into a flipped (top-left origin) premultiplied RGBA bitmap.
    private static func render(size: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: Int(size),
                height: Int(size),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        draw(ctx)
        return ctx.makeImage()
    }

    private static func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
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
