import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Built-in wallpaper pack.
///
/// Screen Studio ships ~180 raster wallpapers across nine families. ScreenForge
/// generates the same families procedurally at 1920×1080 so the app carries no
/// third-party artwork while still offering a populated, searchable pack.
public struct WallpaperPreset: Identifiable, Sendable, Equatable, Hashable {
    public enum Style: String, Sendable {
        case mesh
        case linear
        case radial
    }

    public var id: String
    public var name: String
    public var category: String
    public var colors: [String]
    public var style: Style
    public var angle: Double

    public init(
        id: String,
        name: String,
        category: String,
        colors: [String],
        style: Style = .mesh,
        angle: Double = 0
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.colors = colors
        self.style = style
        self.angle = angle
    }
}

public enum WallpaperLibrary {
    public static let categories = [
        "macOS", "Midnight", "Sunset", "Spring", "Radiant", "Energy", "Iridescent", "Glassmorphism", "Raycast"
    ]

    public static let all: [WallpaperPreset] = [
        // macOS
        WallpaperPreset(id: "macos-sonoma-dark", name: "Sonoma Dark", category: "macOS",
                        colors: ["#0B1026", "#1B2A5E", "#5B2A86"]),
        WallpaperPreset(id: "macos-sonoma-light", name: "Sonoma Light", category: "macOS",
                        colors: ["#F7B2C1", "#F6D8A8", "#9AD0EC"]),
        WallpaperPreset(id: "macos-sonoma-horizon", name: "Sonoma Horizon", category: "macOS",
                        colors: ["#141E30", "#3A1C71", "#D76D77"], style: .linear, angle: 20),
        WallpaperPreset(id: "macos-ventura", name: "Ventura", category: "macOS",
                        colors: ["#0F2027", "#203A43", "#2C5364"], style: .linear, angle: 135),
        WallpaperPreset(id: "macos-sequoia-blue", name: "Sequoia Blue", category: "macOS",
                        colors: ["#021B79", "#0575E6", "#00C6FF"]),
        WallpaperPreset(id: "macos-san-francisco", name: "San Francisco", category: "macOS",
                        colors: ["#232526", "#414345", "#8E9EAB"], style: .linear, angle: 90),

        // Midnight
        WallpaperPreset(id: "midnight-ink", name: "Midnight Ink", category: "Midnight",
                        colors: ["#0F0C29", "#302B63", "#24243E"]),
        WallpaperPreset(id: "midnight-navy", name: "Midnight Navy", category: "Midnight",
                        colors: ["#000428", "#004E92"], style: .linear, angle: 160),
        WallpaperPreset(id: "midnight-orchid", name: "Midnight Orchid", category: "Midnight",
                        colors: ["#1A0033", "#4B0082", "#8A2BE2"]),

        // Sunset
        WallpaperPreset(id: "sunset-ember", name: "Sunset Ember", category: "Sunset",
                        colors: ["#FF512F", "#DD2476", "#1A0033"]),
        WallpaperPreset(id: "sunset-peach", name: "Sunset Peach", category: "Sunset",
                        colors: ["#FDC830", "#F37335", "#C33764"], style: .linear, angle: 30),
        WallpaperPreset(id: "sunset-violet", name: "Sunset Violet", category: "Sunset",
                        colors: ["#FC466B", "#3F5EFB", "#0B0B1E"]),

        // Spring
        WallpaperPreset(id: "spring-meadow", name: "Spring Meadow", category: "Spring",
                        colors: ["#134E5E", "#71B280", "#E0F7C3"]),
        WallpaperPreset(id: "spring-blossom", name: "Spring Blossom", category: "Spring",
                        colors: ["#FCC5E4", "#FDA34F", "#A7E8BD"], style: .linear, angle: 60),
        WallpaperPreset(id: "spring-sage", name: "Spring Sage", category: "Spring",
                        colors: ["#355C7D", "#6C5B7B", "#C06C84"]),

        // Radiant
        WallpaperPreset(id: "radiant-coral", name: "Radiant Coral", category: "Radiant",
                        colors: ["#FF6A88", "#FF99AC", "#FEE140"]),
        WallpaperPreset(id: "radiant-cyan", name: "Radiant Cyan", category: "Radiant",
                        colors: ["#00DBDE", "#FC00FF"], style: .linear, angle: 45),
        WallpaperPreset(id: "radiant-gold", name: "Radiant Gold", category: "Radiant",
                        colors: ["#F7971E", "#FFD200", "#FFF6B7"]),

        // Energy
        WallpaperPreset(id: "energy-electric", name: "Electric", category: "Energy",
                        colors: ["#12C2E9", "#C471ED", "#F64F59"]),
        WallpaperPreset(id: "energy-lime", name: "Energy Lime", category: "Energy",
                        colors: ["#A8E063", "#56AB2F", "#0B3D0B"]),
        WallpaperPreset(id: "energy-magma", name: "Magma", category: "Energy",
                        colors: ["#F83600", "#F9D423", "#7A0B0B"]),

        // Iridescent
        WallpaperPreset(id: "iridescent-pearl", name: "Iridescent Pearl", category: "Iridescent",
                        colors: ["#E0EAFC", "#CFDEF3", "#F5D6E6"], style: .linear, angle: 120),
        WallpaperPreset(id: "iridescent-oil", name: "Oil Slick", category: "Iridescent",
                        colors: ["#00C9FF", "#92FE9D", "#B721FF"]),
        WallpaperPreset(id: "iridescent-holo", name: "Holographic", category: "Iridescent",
                        colors: ["#FBD3E9", "#BB377D", "#2D0B3A"]),

        // Glassmorphism
        WallpaperPreset(id: "glass-frost", name: "Frost", category: "Glassmorphism",
                        colors: ["#C9D6FF", "#E2E2E2", "#8E9EAB"], style: .linear, angle: 180),
        WallpaperPreset(id: "glass-deep", name: "Deep Glass", category: "Glassmorphism",
                        colors: ["#0F2027", "#2C5364", "#00C6FF"]),
        WallpaperPreset(id: "glass-blush", name: "Blush Glass", category: "Glassmorphism",
                        colors: ["#FFDEE9", "#B5FFFC", "#8E9EAB"]),

        // Raycast
        WallpaperPreset(id: "raycast-crimson", name: "Raycast Crimson", category: "Raycast",
                        colors: ["#FF0055", "#1A0010", "#400020"], style: .radial),
        WallpaperPreset(id: "raycast-azure", name: "Raycast Azure", category: "Raycast",
                        colors: ["#0066FF", "#001028", "#001F4D"], style: .radial),
        WallpaperPreset(id: "raycast-ember", name: "Raycast Ember", category: "Raycast",
                        colors: ["#FF7A00", "#1A0A00", "#3D1800"], style: .radial)
    ]

    public static func presets(in category: String) -> [WallpaperPreset] {
        all.filter { $0.category == category }
    }

    /// Renders a wallpaper into a CGImage suitable for the background layer.
    public static func image(for preset: WallpaperPreset, size: CGSize = CGSize(width: 1_920, height: 1_080)) -> CGImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let colors = preset.colors.map { ColorHex.cgColor($0) }
        let space = CGColorSpaceCreateDeviceRGB()
        let rect = CGRect(origin: .zero, size: size)

        switch preset.style {
        case .linear:
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: colors as CFArray,
                locations: evenlySpaced(count: colors.count)
            ) {
                let radians = preset.angle * .pi / 180
                let start = CGPoint(x: size.width / 2 - cos(radians) * size.width, y: size.height / 2 - sin(radians) * size.height)
                let end = CGPoint(x: size.width / 2 + cos(radians) * size.width, y: size.height / 2 + sin(radians) * size.height)
                context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }

        case .radial:
            context.setFillColor(colors.first ?? CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            if let glow = CGGradient(
                colorsSpace: space,
                colors: [colors.first ?? CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                locations: [0, 1]
            ) {
                context.drawRadialGradient(
                    glow,
                    startCenter: CGPoint(x: size.width * 0.35, y: size.height * 0.62),
                    startRadius: 0,
                    endCenter: CGPoint(x: size.width * 0.35, y: size.height * 0.62),
                    endRadius: size.width * 0.75,
                    options: [.drawsAfterEndLocation]
                )
            }

        case .mesh:
            if let base = CGGradient(
                colorsSpace: space,
                colors: colors as CFArray,
                locations: evenlySpaced(count: colors.count)
            ) {
                context.drawLinearGradient(
                    base,
                    start: CGPoint(x: 0, y: size.height),
                    end: CGPoint(x: size.width, y: 0),
                    options: []
                )
            }
            let blobs: [(Double, Double, Double)] = [
                (0.22, 0.72, 0.55),
                (0.78, 0.28, 0.60),
                (0.58, 0.86, 0.42)
            ]
            for (index, blob) in blobs.enumerated() {
                let color = colors[(index + 1) % max(colors.count, 1)]
                guard let glow = CGGradient(
                    colorsSpace: space,
                    colors: [color.copy(alpha: 0.55) ?? color, color.copy(alpha: 0) ?? color] as CFArray,
                    locations: [0, 1]
                ) else { continue }
                let center = CGPoint(x: size.width * blob.0, y: size.height * blob.1)
                context.drawRadialGradient(
                    glow,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: size.width * blob.2,
                    options: []
                )
            }
        }

        // Subtle vignette so screen content stays legible.
        if let vignette = CGGradient(
            colorsSpace: space,
            colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)] as CFArray,
            locations: [0.55, 1]
        ) {
            context.drawRadialGradient(
                vignette,
                startCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: size.width * 0.2,
                endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                endRadius: size.width * 0.8,
                options: [.drawsAfterEndLocation]
            )
        }

        return context.makeImage()
    }

    /// Writes the rendered wallpaper as a PNG and returns the file URL.
    public static func write(
        _ preset: WallpaperPreset,
        to directory: URL,
        size: CGSize = CGSize(width: 1_920, height: 1_080)
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wallpaper-\(preset.id).png")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let image = image(for: preset, size: size),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private static func evenlySpaced(count: Int) -> [CGFloat] {
        guard count > 1 else { return [0] }
        return (0..<count).map { CGFloat($0) / CGFloat(count - 1) }
    }
}
