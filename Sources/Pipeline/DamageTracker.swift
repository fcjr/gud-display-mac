import CoreVideo
import Foundation

// Finds what changed between consecutive captured frames. ScreenCaptureKit
// reports no dirty rects at all on a scaled stream (contentScale < 1), so the
// frame is compared against the previous one in tiles and the dirty tiles are
// grouped into a handful of rectangles. Whole-frame updates over full-speed
// USB cost tens of milliseconds; a moving cursor or a line of typing is a
// few tiles.
struct DamageTracker {
    static let tile = 16
    // More rects than this cost more in control-request round trips than the
    // bytes they save; fall back to the bounding box.
    static let maxRects = 6

    let width: Int
    let height: Int
    let tilesX: Int
    let tilesY: Int
    private var previous: [UInt8]
    private var havePrevious = false
    // Tiles changed by frames that were packed but never sent (superseded
    // while a flush was in progress); folded into the next frame's damage.
    private var carried: [Bool]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        tilesX = (width + Self.tile - 1) / Self.tile
        tilesY = (height + Self.tile - 1) / Self.tile
        previous = [UInt8](repeating: 0, count: width * height * 4)
        carried = [Bool](repeating: false, count: tilesX * tilesY)
    }

    mutating func reset() {
        havePrevious = false
        for i in carried.indices { carried[i] = false }
    }

    mutating func carry(tiles: [Bool]) {
        for (i, dirty) in tiles.enumerated() where dirty {
            carried[i] = true
        }
    }

    // Compares the (locked) BGRA buffer against the previous frame, remembers
    // it, and returns the dirty tile map, or nil when nothing changed.
    mutating func update(_ pixelBuffer: CVPixelBuffer, forceFull: Bool) -> [Bool]? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        var tiles = carried
        for i in carried.indices { carried[i] = false }

        let full = forceFull || !havePrevious
        previous.withUnsafeMutableBytes { prev in
            let prevBase = prev.baseAddress!
            for y in 0..<height {
                let src = base + y * bytesPerRow
                let dst = prevBase + y * rowBytes
                if !full {
                    let tileRow = (y / Self.tile) * tilesX
                    for tx in 0..<tilesX {
                        let x0 = tx * Self.tile * 4
                        let n = min(Self.tile * 4, rowBytes - x0)
                        if memcmp(src + x0, dst + x0, n) != 0 {
                            tiles[tileRow + tx] = true
                        }
                    }
                }
                memcpy(dst, src, rowBytes)
            }
        }
        havePrevious = true
        if full {
            for i in tiles.indices { tiles[i] = true }
        }
        return tiles.contains(true) ? tiles : nil
    }

    // Groups dirty tiles into rectangles: one per run of tile rows whose
    // horizontal extents are similar, else the bounding box.
    func rects(for tiles: [Bool]) -> [DamageRect] {
        var rows: [(y0: Int, y1: Int, x0: Int, x1: Int)] = []
        for ty in 0..<tilesY {
            var x0 = Int.max, x1 = Int.min
            for tx in 0..<tilesX where tiles[ty * tilesX + tx] {
                x0 = min(x0, tx)
                x1 = max(x1, tx + 1)
            }
            guard x0 != Int.max else { continue }
            if let last = rows.last, last.y1 == ty, abs(last.x0 - x0) <= 2, abs(last.x1 - x1) <= 2 {
                rows[rows.count - 1] = (last.y0, ty + 1, min(last.x0, x0), max(last.x1, x1))
            } else {
                rows.append((ty, ty + 1, x0, x1))
            }
        }
        guard !rows.isEmpty else { return [] }
        if rows.count > Self.maxRects {
            let y0 = rows.first!.y0, y1 = rows.last!.y1
            let x0 = rows.map(\.x0).min()!, x1 = rows.map(\.x1).max()!
            rows = [(y0, y1, x0, x1)]
        }
        return rows.map { row in
            DamageRect(x: row.x0 * Self.tile, y: row.y0 * Self.tile,
                       width: (row.x1 - row.x0) * Self.tile, height: (row.y1 - row.y0) * Self.tile)
                .clamped(toWidth: width, height: height)
        }
    }
}
