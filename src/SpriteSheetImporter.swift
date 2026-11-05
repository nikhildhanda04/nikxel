import AppKit

/// Turns a raw sprite sheet -- including the magenta-backed one the bundled
/// Gemini prompt produces -- into the 256x640 transparent sheet the avatar
/// renderer expects. This is a port of remove_magenta.py so the onboarding
/// "Your avatar" step can accept whatever Gemini hands back without the user
/// having to run Python (and install Pillow) first.
enum SpriteSheetImporter {
    enum ImportError: Error, LocalizedError {
        case unreadable
        case tooSmall
        case empty
        case wrongGrid(rowsFound: Int, colsFound: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that PNG."
            case .tooSmall: return "That image is too small to slice into \(NikxelSprites.cols)x\(NikxelSprites.rows) frames."
            case .empty: return "That sheet came out empty -- every frame was background. Is it the right image?"
            case .wrongGrid(let r, let c):
                return "That sheet reads as \(r) rows x \(c) poses, but Nikxel needs \(NikxelSprites.rows) x \(NikxelSprites.cols). Gemini often ignores the grid -- ask it again for \(NikxelSprites.rows) rows of \(NikxelSprites.cols) frames, with a clear magenta gap between rows."
            }
        }
    }

    private static let f = NikxelSprites.frameSize            // 64
    private static let cols = NikxelSprites.cols              // 4
    private static let rows = NikxelSprites.rows              // 10
    private static var sheetW: Int { cols * f }               // 256
    private static var sheetH: Int { rows * f }               // 640

    /// A plain top-left-origin RGBA8 buffer. CoreGraphics contexts are
    /// bottom-left origin, which would silently flip the row-per-state grid, so
    /// everything here works on explicit top-first pixels instead.
    private struct Bitmap {
        var w: Int
        var h: Int
        var px: [UInt8]

        init(w: Int, h: Int) {
            self.w = w; self.h = h
            px = [UInt8](repeating: 0, count: w * h * 4)
        }

        @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }
        @inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 { px[idx(x, y) + 3] }
        @inline(__always) mutating func clear(_ x: Int, _ y: Int) {
            let i = idx(x, y)
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
        }
    }

    // MARK: - Entry point

    /// Reads `url`, keys out the magenta, re-frames every cell, and returns
    /// 256x640 PNG data ready to write to disk.
    /// Reads `url`, keys out the magenta, and lays every pose out on the
    /// 256x640 grid the renderer expects.
    static func process(url: URL) throws -> Data {
        var src = try load(url)
        guard src.w >= cols, src.h >= rows else { throw ImportError.tooSmall }
        keyOutMagenta(&src)

        // Find the grid instead of assuming the image divides evenly into it.
        // Gemini's sheets routinely don't: one real example was 1312x3264, and
        // 3264/10 isn't whole, so slicing at fixed 64px boundaries cut straight
        // through every character -- which is exactly what made the avatar look
        // mangled as it changed state.
        let rowBands = grid(of: src, horizontal: true, expected: rows)
        let colBands = grid(of: src, horizontal: false, expected: cols)
        guard rowBands.count == rows, colBands.count == cols else {
            throw ImportError.wrongGrid(rowsFound: rowBands.count, colsFound: colBands.count)
        }

        // One scale for the whole sheet, sized so the tallest row band and the
        // widest column band both fit with room for the outline. Scaling each
        // pose to its own fixed height is what made the avatar pop between
        // states, so every cell shares this factor.
        let tallest = rowBands.map { $0.end - $0.start + 1 }.max() ?? 1
        let widest = colBands.map { $0.end - $0.start + 1 }.max() ?? 1
        let scale = min(1.0, Double(f - 4) / Double(max(tallest, widest)))

        var out = Bitmap(w: sheetW, h: sheetH)
        for (r, rowBand) in rowBands.enumerated() {
            for (c, colBand) in colBands.enumerated() {
                let cell = sampleCell(
                    src,
                    x: colBand.start, y: rowBand.start,
                    w: colBand.end - colBand.start + 1,
                    h: rowBand.end - rowBand.start + 1,
                    scale: scale
                )
                blit(cell, into: &out, atX: c * f, y: r * f)
            }
        }

        for _ in 0..<3 { cleanMagentaFringe(&out) }
        hardenEdges(&out)
        addOutline(&out)
        return try png(from: out)
    }

    /// The sheet's real row (or column) boundaries: runs of lines holding
    /// artwork, separated by background. Where two rows touch -- a jump pose
    /// reaching into the row above, say -- the runs merge, so oversized bands
    /// are split back apart at their emptiest line until the count matches.
    private static func grid(of bmp: Bitmap, horizontal: Bool, expected: Int) -> [(start: Int, end: Int)] {
        let outer = horizontal ? bmp.h : bmp.w
        let inner = horizontal ? bmp.w : bmp.h
        // A couple of stray pixels left by the chroma key shouldn't glue two
        // bands together, so a line needs real content to count as occupied.
        let threshold = max(1, inner / 100)

        var occupancy = [Int](repeating: 0, count: outer)
        for i in 0..<outer {
            var count = 0
            for j in 0..<inner {
                let a = horizontal ? bmp.alpha(j, i) : bmp.alpha(i, j)
                if a > 30 { count += 1 }
            }
            occupancy[i] = count
        }

        var result: [(start: Int, end: Int)] = []
        var start: Int? = nil
        for i in 0..<outer {
            if occupancy[i] > threshold {
                if start == nil { start = i }
            } else if let s = start {
                result.append((s, i - 1)); start = nil
            }
        }
        if let s = start { result.append((s, outer - 1)) }

        var attempts = 0
        while result.count < expected, attempts < expected * 2 {
            attempts += 1
            guard let i = tallestBand(result), result[i].end - result[i].start >= 3 else { break }
            let (bandStart, bandEnd) = result[i]
            // Split in the middle half -- the seam between two merged poses is
            // in there, and the band's own edges obviously are not.
            let quarter = (bandEnd - bandStart) / 4
            let low = bandStart + quarter, high = bandEnd - quarter
            guard high > low else { break }
            var seam = low
            for line in low...high where occupancy[line] < occupancy[seam] { seam = line }
            // Only split where the seam is near-empty. A sheet with the wrong
            // number of rows has no seam to find, so its emptiest middle line
            // still runs through artwork -- splitting there would manufacture
            // the right band count out of sliced characters and hide the real
            // problem. Measured: a genuine touch-seam sits around 8% of the
            // width, a cut through four characters around 32%.
            guard occupancy[seam] * 100 < inner * 15 else { break }
            result.replaceSubrange(i...i, with: [(bandStart, seam - 1), (seam + 1, bandEnd)])
        }
        return result
    }

    private static func tallestBand(_ bands: [(start: Int, end: Int)]) -> Int? {
        guard !bands.isEmpty else { return nil }
        var best = 0
        for (i, b) in bands.enumerated() where b.end - b.start > bands[best].end - bands[best].start { best = i }
        return best
    }

    /// Copies one source rect into a 64x64 cell, scaled and centred. The rect
    /// comes from the detected grid, so each pose keeps its position and size
    /// relative to the others.
    private static func sampleCell(_ src: Bitmap, x: Int, y: Int, w: Int, h: Int, scale: Double) -> Bitmap {
        var cell = Bitmap(w: f, h: f)
        let dw = Double(w) * scale, dh = Double(h) * scale
        let offX = (Double(f) - dw) / 2, offY = (Double(f) - dh) / 2
        for dy in 0..<f {
            let sy = Int(((Double(dy) + 0.5 - offY) / scale).rounded(.down))
            guard sy >= 0, sy < h else { continue }
            for dx in 0..<f {
                let sx = Int(((Double(dx) + 0.5 - offX) / scale).rounded(.down))
                guard sx >= 0, sx < w else { continue }
                let s = src.idx(x + sx, y + sy), d = cell.idx(dx, dy)
                guard src.px[s + 3] > 0 else { continue }
                cell.px[d] = src.px[s]
                cell.px[d + 1] = src.px[s + 1]
                cell.px[d + 2] = src.px[s + 2]
                cell.px[d + 3] = src.px[s + 3]
            }
        }
        return cell
    }

    // MARK: - Load / save

    private static func load(_ url: URL) throws -> Bitmap {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImportError.unreadable
        }
        var bmp = Bitmap(w: cg.width, h: cg.height)
        let ok: Bool = bmp.px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard ok else { throw ImportError.unreadable }
        return bmp
    }

    private static func png(from bmp: Bitmap) throws -> Data {
        // Built straight from the buffer via a data provider rather than a
        // CGContext: providers read rows top-first, which is the order this
        // code works in. Going through a context would flip the sheet and with
        // it the row-per-state order.
        guard let provider = CGDataProvider(data: Data(bmp.px) as CFData),
              let cg = CGImage(
                width: bmp.w, height: bmp.h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bmp.w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ImportError.unreadable
        }
        return data
    }

    // MARK: - Pixel passes (mirrors remove_magenta.py)

    /// Chroma key: #FF00FF-ish (R>150, G<100, B>150) becomes transparent,
    /// everything else becomes fully opaque.
    private static func keyOutMagenta(_ bmp: inout Bitmap) {
        for y in 0..<bmp.h {
            for x in 0..<bmp.w {
                let i = bmp.idx(x, y)
                if bmp.px[i + 3] < 30 { bmp.clear(x, y); continue }
                if bmp.px[i] > 150, bmp.px[i + 1] < 100, bmp.px[i + 2] > 150 {
                    bmp.clear(x, y)
                } else {
                    bmp.px[i + 3] = 255
                }
            }
        }
    }

    /// Scrubs the magenta-tinted halo the key leaves behind: a pinkish pixel
    /// with 2+ transparent neighbours was background bleed, not art.
    private static func cleanMagentaFringe(_ bmp: inout Bitmap) {
        let snapshot = bmp
        for y in 0..<bmp.h {
            for x in 0..<bmp.w {
                let i = snapshot.idx(x, y)
                if snapshot.px[i + 3] < 200 { continue }
                let r = Float(snapshot.px[i]), g = Float(snapshot.px[i + 1]), b = Float(snapshot.px[i + 2])
                guard r > 100, b > 100, g / max(r + b, 1) < 0.4 else { continue }
                var transparentNeighbours = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < snapshot.w, ny >= 0, ny < snapshot.h else { continue }
                        if snapshot.alpha(nx, ny) < 30 { transparentNeighbours += 1 }
                    }
                }
                if transparentNeighbours >= 2 { bmp.clear(x, y) }
            }
        }
    }

    /// No partial alpha in the final sheet -- a semi-transparent pixel either
    /// touches solid art (snap opaque) or is leftover fringe (snap clear).
    private static func hardenEdges(_ bmp: inout Bitmap) {
        let snapshot = bmp
        for y in 0..<bmp.h {
            for x in 0..<bmp.w {
                let a = snapshot.alpha(x, y)
                guard a > 0, a < 200 else { continue }
                var touchesSolid = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < snapshot.w, ny >= 0, ny < snapshot.h else { continue }
                        if snapshot.alpha(nx, ny) > 200 { touchesSolid = true }
                    }
                }
                if touchesSolid { bmp.px[bmp.idx(x, y) + 3] = 255 } else { bmp.clear(x, y) }
            }
        }
    }

    /// 1px white halo -- what keeps the avatar readable over any wallpaper.
    private static func addOutline(_ cell: inout Bitmap) {
        let snapshot = cell
        for y in 0..<cell.h {
            for x in 0..<cell.w where snapshot.alpha(x, y) <= 100 {
                var nearArt = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < snapshot.w, ny >= 0, ny < snapshot.h else { continue }
                        if snapshot.alpha(nx, ny) > 100 { nearArt = true }
                    }
                }
                guard nearArt else { continue }
                let i = cell.idx(x, y)
                cell.px[i] = 255; cell.px[i + 1] = 255; cell.px[i + 2] = 255; cell.px[i + 3] = 255
            }
        }
    }

    /// Source-over paste, skipping fully transparent source pixels.
    private static func blit(_ src: Bitmap, into dst: inout Bitmap, atX x0: Int, y y0: Int) {
        for y in 0..<src.h {
            for x in 0..<src.w {
                let dx = x0 + x, dy = y0 + y
                guard dx >= 0, dx < dst.w, dy >= 0, dy < dst.h else { continue }
                let s = src.idx(x, y)
                guard src.px[s + 3] > 0 else { continue }
                let d = dst.idx(dx, dy)
                dst.px[d] = src.px[s]
                dst.px[d + 1] = src.px[s + 1]
                dst.px[d + 2] = src.px[s + 2]
                dst.px[d + 3] = src.px[s + 3]
            }
        }
    }
}
