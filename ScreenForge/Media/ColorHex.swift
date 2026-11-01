import AppKit
import CoreGraphics
import Foundation
import simd

/// Hex color helpers shared by the renderer and the SwiftUI chrome.
///
/// Accepts `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`. The final two digits are alpha,
/// matching CSS shorthand used in the project format.
public enum ColorHex {
    public static func rgba(_ hex: String, alpha: Float = 1) -> SIMD4<Float> {
        let parsed = parse(hex)
        return SIMD4<Float>(parsed.0, parsed.1, parsed.2, parsed.3 * alpha)
    }

    /// Multiplies RGB toward black; returns an opaque color.
    public static func darkened(_ hex: String, by amount: Float) -> SIMD4<Float> {
        let parsed = parse(hex)
        let factor = min(max(1 - amount, 0), 1)
        return SIMD4<Float>(parsed.0 * factor, parsed.1 * factor, parsed.2 * factor, 1)
    }

    public static func cgColor(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let parsed = parse(hex)
        return CGColor(
            srgbRed: CGFloat(parsed.0),
            green: CGFloat(parsed.1),
            blue: CGFloat(parsed.2),
            alpha: CGFloat(parsed.3) * alpha
        )
    }

    public static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        let parsed = parse(hex)
        return NSColor(
            srgbRed: CGFloat(parsed.0),
            green: CGFloat(parsed.1),
            blue: CGFloat(parsed.2),
            alpha: CGFloat(parsed.3) * alpha
        )
    }

    public static func parse(_ hex: String) -> (Float, Float, Float, Float) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 || text.count == 4 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else {
            return (0, 0, 0, 1)
        }

        if text.count == 6 {
            return (
                Float((value >> 16) & 0xFF) / 255,
                Float((value >> 8) & 0xFF) / 255,
                Float(value & 0xFF) / 255,
                1
            )
        }
        return (
            Float((value >> 24) & 0xFF) / 255,
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float(value & 0xFF) / 255
        )
    }
}
