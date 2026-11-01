import Foundation
import simd

/// Parser for Adobe/Iridas `.cube` 3D LUTs.
///
/// The compositor uploads the parsed table as an `MTLTexture` and samples it per
/// pixel. Parsing is pure Swift so it can be unit tested without Metal.
public struct CubeLUT: Sendable, Equatable {
    public enum ParseError: LocalizedError, Sendable {
        case missingSize
        case unsupportedSize(Int)
        case wrongEntryCount(expected: Int, actual: Int)
        case malformedLine(String)

        public var errorDescription: String? {
            switch self {
            case .missingSize:
                "The .cube file does not declare LUT_3D_SIZE."
            case .unsupportedSize(let size):
                "Unsupported LUT size \(size); expected 2–64."
            case .wrongEntryCount(let expected, let actual):
                "The LUT has \(actual) entries but \(expected) were expected."
            case .malformedLine(let line):
                "Could not read LUT line: \(line)"
            }
        }
    }

    public let title: String
    public let size: Int
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    /// RGB triples in `.cube` order: red varies fastest, then green, then blue.
    public let entries: [Float]

    public init(
        title: String = "",
        size: Int,
        domainMin: SIMD3<Float> = .zero,
        domainMax: SIMD3<Float> = .one,
        entries: [Float]
    ) throws {
        guard size >= 2, size <= 64 else { throw ParseError.unsupportedSize(size) }
        guard entries.count == size * size * size * 3 else {
            throw ParseError.wrongEntryCount(
                expected: size * size * size * 3,
                actual: entries.count
            )
        }
        self.title = title
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.entries = entries
    }

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(text: text)
    }

    public init(text: String) throws {
        var title = ""
        var size: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first?.uppercased() else { continue }

            if keyword == "TITLE" {
                let quoted = line.dropFirst(parts[0].count).trimmingCharacters(in: .whitespaces)
                title = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if keyword == "LUT_1D_SIZE" {
                // 1D LUTs are accepted as a degenerate 3D table later if needed.
                continue
            }
            if keyword == "LUT_3D_SIZE" {
                guard parts.count > 1, let parsed = Int(parts[1]) else {
                    throw ParseError.missingSize
                }
                size = parsed
                continue
            }
            if keyword == "DOMAIN_MIN" {
                domainMin = SIMD3<Float>(
                    Float(parts[safe: 1] ?? "") ?? 0,
                    Float(parts[safe: 2] ?? "") ?? 0,
                    Float(parts[safe: 3] ?? "") ?? 0
                )
                continue
            }
            if keyword == "DOMAIN_MAX" {
                domainMax = SIMD3<Float>(
                    Float(parts[safe: 1] ?? "") ?? 1,
                    Float(parts[safe: 2] ?? "") ?? 1,
                    Float(parts[safe: 3] ?? "") ?? 1
                )
                continue
            }
            guard parts.count >= 3,
                  let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2]) else {
                throw ParseError.malformedLine(line)
            }
            values.append(r)
            values.append(g)
            values.append(b)
        }

        guard let size else { throw ParseError.missingSize }
        try self.init(
            title: title,
            size: size,
            domainMin: domainMin,
            domainMax: domainMax,
            entries: values
        )
    }

    /// Trilinear lookup, used by tests and thumbnails.
    public func lookup(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let range = max(domainMax - domainMin, SIMD3<Float>(repeating: 0.0001))
        let normalized = simd_clamp((color - domainMin) / range, .zero, .one)
        let scaled = normalized * Float(size - 1)
        let lower = SIMD3<Int32>(Int32(floor(scaled.x)), Int32(floor(scaled.y)), Int32(floor(scaled.z)))
        let fraction = scaled - SIMD3<Float>(Float(lower.x), Float(lower.y), Float(lower.z))
        let upper = simd_min(lower &+ SIMD3<Int32>(repeating: 1), SIMD3<Int32>(repeating: Int32(size - 1)))

        func entry(_ x: Int32, _ y: Int32, _ z: Int32) -> SIMD3<Float> {
            let index = (Int(z) * size * size + Int(y) * size + Int(x)) * 3
            guard index + 2 < entries.count else { return .zero }
            return SIMD3<Float>(entries[index], entries[index + 1], entries[index + 2])
        }

        let c000 = entry(lower.x, lower.y, lower.z)
        let c100 = entry(upper.x, lower.y, lower.z)
        let c010 = entry(lower.x, upper.y, lower.z)
        let c110 = entry(upper.x, upper.y, lower.z)
        let c001 = entry(lower.x, lower.y, upper.z)
        let c101 = entry(upper.x, lower.y, upper.z)
        let c011 = entry(lower.x, upper.y, upper.z)
        let c111 = entry(upper.x, upper.y, upper.z)

        let c00 = simd_mix(c000, c100, SIMD3<Float>(repeating: fraction.x))
        let c10 = simd_mix(c010, c110, SIMD3<Float>(repeating: fraction.x))
        let c01 = simd_mix(c001, c101, SIMD3<Float>(repeating: fraction.x))
        let c11 = simd_mix(c011, c111, SIMD3<Float>(repeating: fraction.x))
        let c0 = simd_mix(c00, c10, SIMD3<Float>(repeating: fraction.y))
        let c1 = simd_mix(c01, c11, SIMD3<Float>(repeating: fraction.y))
        return simd_mix(c0, c1, SIMD3<Float>(repeating: fraction.z))
    }

    /// Identity table, useful as a neutral fallback.
    public static func identity(size: Int = 16) throws -> CubeLUT {
        var entries: [Float] = []
        entries.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    entries.append(Float(r) / Float(size - 1))
                    entries.append(Float(g) / Float(size - 1))
                    entries.append(Float(b) / Float(size - 1))
                }
            }
        }
        return try CubeLUT(title: "Identity", size: size, entries: entries)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
