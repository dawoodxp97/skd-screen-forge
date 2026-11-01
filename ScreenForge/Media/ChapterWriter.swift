import Foundation

/// Writes chapter markers into an exported MP4/MOV.
///
/// QuickTime chapters live in a `chpl` box inside `moov/udta`; many players and
/// editors (QuickTime Player, IINA, FCP, YouTube metadata tools) read it. The writer
/// edits the finished file in place so it works for both `AVAssetWriter` outputs and
/// passthrough muxes.
public enum ChapterWriter {
    public struct Chapter: Sendable, Equatable {
        public var timeMs: Int
        public var title: String

        public init(timeMs: Int, title: String) {
            self.timeMs = timeMs
            self.title = title
        }
    }

    public enum WriteError: LocalizedError, Sendable {
        case unreadable
        case malformedMovie
        case unsupportedLargeBox

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The exported movie could not be read for chapter metadata."
            case .malformedMovie: "The exported movie has an unexpected box structure."
            case .unsupportedLargeBox: "64-bit movie boxes are not supported for chapters."
            }
        }
    }

    /// Inserts or replaces the chapter list in `url`.
    public static func write(chapters: [Chapter], to url: URL) throws {
        guard !chapters.isEmpty else { return }
        guard let data = try? Data(contentsOf: url) else { throw WriteError.unreadable }

        let sorted = chapters
            .sorted { $0.timeMs < $1.timeMs }
            .prefix(255)
            .map { chapter -> Chapter in
                var copy = chapter
                copy.title = String(chapter.title.prefix(255))
                return copy
            }
        let chpl = makeChplBox(chapters: Array(sorted))

        var updated = data
        let topLevel = try boxes(in: updated, range: 0..<updated.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
            throw WriteError.malformedMovie
        }
        if moov.largeSize { throw WriteError.unsupportedLargeBox }

        let moovPayload = moov.payloadRange
        let children = try boxes(in: updated, range: moovPayload)
        var insertedAt = moovPayload.upperBound
        var delta = 0

        if let udta = children.first(where: { $0.type == "udta" }) {
            if udta.largeSize { throw WriteError.unsupportedLargeBox }
            let udtaChildren = try boxes(in: updated, range: udta.payloadRange)
            if let existing = udtaChildren.first(where: { $0.type == "chpl" }) {
                delta = chpl.count - existing.range.count
                insertedAt = existing.range.lowerBound
                updated.replaceSubrange(existing.range, with: chpl)
                if delta != 0 {
                    updateSize(in: &updated, boxStart: udta.range.lowerBound, delta: delta)
                    updateSize(in: &updated, boxStart: moov.range.lowerBound, delta: delta)
                }
            } else {
                insertedAt = udta.payloadRange.upperBound
                delta = chpl.count
                updated.insert(contentsOf: chpl, at: insertedAt)
                updateSize(in: &updated, boxStart: udta.range.lowerBound, delta: delta)
                updateSize(in: &updated, boxStart: moov.range.lowerBound, delta: delta)
            }
        } else {
            var udtaBox = Data()
            udtaBox.append(contentsOf: [0, 0, 0, 0])
            udtaBox.append(contentsOf: Array("udta".utf8))
            udtaBox.append(chpl)
            setSize(in: &udtaBox, at: 0, size: udtaBox.count)

            insertedAt = moovPayload.upperBound
            delta = udtaBox.count
            updated.insert(contentsOf: udtaBox, at: insertedAt)
            updateSize(in: &updated, boxStart: moov.range.lowerBound, delta: delta)
        }

        // Fast-start files place `moov` before `mdat`; inserting bytes then moves
        // every media chunk. Rebase stco/co64 so the movie still decodes.
        if delta != 0 {
            let newMoovRange = moov.range.lowerBound..<(moov.range.upperBound + delta)
            try adjustChunkOffsets(
                in: &updated,
                range: newMoovRange,
                insertionPoint: insertedAt,
                delta: delta
            )
        }

        try updated.write(to: url, options: .atomic)
    }

    // MARK: - chpl

    static func makeChplBox(chapters: [Chapter]) -> Data {
        var payload = Data()
        payload.append(1)                                  // version
        payload.append(contentsOf: [0, 0, 0])              // flags
        payload.append(contentsOf: [0, 0, 0, 0])           // reserved
        payload.append(UInt8(min(chapters.count, 255)))    // chapter count

        for chapter in chapters.prefix(255) {
            var start = UInt64(max(chapter.timeMs, 0)) * 10_000
            withUnsafeBytes(of: &start) { raw in
                for byte in raw.reversed() { payload.append(byte) }
            }
            let title = Array(chapter.title.utf8)
            payload.append(UInt8(min(title.count, 255)))
            payload.append(contentsOf: title.prefix(255))
        }

        var box = Data()
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: Array("chpl".utf8))
        box.append(payload)
        setSize(in: &box, at: 0, size: box.count)
        return box
    }

    /// Reads chapter titles back out; used by tests and diagnostics.
    public static func readChapters(from url: URL) throws -> [Chapter] {
        let data = try Data(contentsOf: url)
        let topLevel = try boxes(in: data, range: 0..<data.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
            throw WriteError.malformedMovie
        }
        let udta = try boxes(in: data, range: moov.payloadRange).first { $0.type == "udta" }
        guard let udta,
              let chpl = try boxes(in: data, range: udta.payloadRange).first(where: { $0.type == "chpl" }) else {
            return []
        }

        let payload = data.subdata(in: chpl.payloadRange)
        guard payload.count >= 9 else { return [] }
        let count = Int(payload[8])
        var chapters: [Chapter] = []
        var offset = 9
        for _ in 0..<count {
            guard offset + 9 <= payload.count else { break }
            let start = payload[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let length = Int(payload[offset + 8])
            offset += 9
            guard offset + length <= payload.count else { break }
            let title = String(decoding: payload[offset..<(offset + length)], as: UTF8.self)
            offset += length
            chapters.append(Chapter(timeMs: Int(start / 10_000), title: title))
        }
        return chapters
    }

    // MARK: - Chunk offset rebasing

    /// Adds `delta` to stco/co64 entries whose file offset is at or after the
    /// insertion point. Recurses through the moov tree.
    private static func adjustChunkOffsets(
        in data: inout Data,
        range: Range<Int>,
        insertionPoint: Int,
        delta: Int
    ) throws {
        for box in try boxes(in: data, range: range) {
            switch box.type {
            case "stco":
                rebaseStco(in: &data, box: box, insertionPoint: insertionPoint, delta: delta, is64: false)
            case "co64":
                rebaseStco(in: &data, box: box, insertionPoint: insertionPoint, delta: delta, is64: true)
            case "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex", "moof":
                try adjustChunkOffsets(
                    in: &data,
                    range: box.payloadRange,
                    insertionPoint: insertionPoint,
                    delta: delta
                )
            default:
                continue
            }
        }
    }

    private static func rebaseStco(
        in data: inout Data,
        box: Box,
        insertionPoint: Int,
        delta: Int,
        is64: Bool
    ) {
        let payloadStart = box.payloadRange.lowerBound
        guard payloadStart + 8 <= box.payloadRange.upperBound else { return }
        let count = Int(be32(data, at: payloadStart + 4))
        let entrySize = is64 ? 8 : 4
        var offset = payloadStart + 8

        for _ in 0..<count {
            guard offset + entrySize <= box.payloadRange.upperBound else { break }
            if is64 {
                let value = Int64(bitPattern: be64(data, at: offset))
                if value >= Int64(insertionPoint) {
                    let rebased = max(value + Int64(delta), 0)
                    writeBE64(UInt64(rebased), into: &data, at: offset)
                }
            } else {
                let value = Int64(be32(data, at: offset))
                if value >= Int64(insertionPoint) {
                    let rebased = max(value + Int64(delta), 0)
                    writeBE32(UInt32(clamping: rebased), into: &data, at: offset)
                }
            }
            offset += entrySize
        }
    }

    private static func writeBE32(_ value: UInt32, into data: inout Data, at offset: Int) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private static func writeBE64(_ value: UInt64, into data: inout Data, at offset: Int) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }

    // MARK: - Box helpers

    struct Box {
        var type: String
        var range: Range<Int>
        var headerSize: Int
        var largeSize: Bool

        var payloadRange: Range<Int> {
            (range.lowerBound + headerSize)..<range.upperBound
        }
    }

    static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size32 = Int(be32(data, at: offset))
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var headerSize = 8
            var boxSize = size32
            var large = false

            if size32 == 1 {
                guard offset + 16 <= range.upperBound else { throw WriteError.malformedMovie }
                boxSize = Int(be64(data, at: offset + 8))
                headerSize = 16
                large = true
            } else if size32 == 0 {
                boxSize = range.upperBound - offset
            }

            guard boxSize >= headerSize, offset + boxSize <= range.upperBound else {
                throw WriteError.malformedMovie
            }
            result.append(Box(
                type: type,
                range: offset..<(offset + boxSize),
                headerSize: headerSize,
                largeSize: large
            ))
            offset += boxSize
        }
        return result
    }

    private static func be32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func be64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func setSize(in data: inout Data, at offset: Int, size: Int) {
        let value = UInt32(size).bigEndian
        withUnsafeBytes(of: value) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private static func updateSize(in data: inout Data, boxStart: Int, delta: Int) {
        guard boxStart + 4 <= data.count else { return }
        let current = Int(be32(data, at: boxStart))
        setSize(in: &data, at: boxStart, size: current + delta)
    }
}
