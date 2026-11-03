#!/usr/bin/env swift
// Compare a replica screenshot against the reference screenshot it should match.
//
// Two metrics, because they answer different questions and fail in different ways:
//
//   strict  per-pixel difference. Catches colour, icon, border and shadow drift,
//           but also screams at every glyph because Arbor draws text with AppKit
//           metrics and the reference draws it with the JetBrains runtime. It is
//           a styling signal, not a structural one.
//
//   block   mean colour per N-point block. Text renders differently but a row of
//           text still averages to roughly the same block colour, so a block that
//           differs means something moved, resized, appeared or disappeared —
//           which is exactly the "the buttons do not line up" defect class.
//
// Blocks that differ are clustered into regions and reported as points and
// boxes, so a reviewer reads 3 rows instead of scanning 6.7 million pixels.
//
// usage: ui-parity-diff.swift --replica A.png --reference B.png --out DIR
//                             [--block 16] [--tolerance 26] [--label commit]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - arguments

struct Options {
    var replica: String
    var reference: String
    var outDir: String
    var block: Int = 16
    var tolerance: Double = 26
    var label: String = "surface"
}

func parseOptions() -> Options? {
    var values: [String: String] = [:]
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--"), index + 1 < args.count else { return nil }
        values[String(key.dropFirst(2))] = args[index + 1]
        index += 2
    }
    guard let replica = values["replica"],
          let reference = values["reference"],
          let outDir = values["out"] else {
        FileHandle.standardError.write(Data("""
        usage: ui-parity-diff.swift --replica A.png --reference B.png --out DIR \
        [--block 16] [--tolerance 26] [--label name]

        """.utf8))
        return nil
    }
    var options = Options(replica: replica, reference: reference, outDir: outDir)
    if let block = values["block"].flatMap(Int.init), block > 0 { options.block = block }
    if let tolerance = values["tolerance"].flatMap(Double.init) { options.tolerance = tolerance }
    if let label = values["label"] { options.label = label }
    return options
}

// MARK: - image loading

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // RGBA, 8 bits per component, premultiplied

    static func load(_ path: String) -> Bitmap? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            FileHandle.standardError.write(Data("cannot read image: \(path)\n".utf8))
            return nil
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    @inline(__always)
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let offset = (y * width + x) * 4
        return (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
    }
}

// MARK: - comparison

struct Region {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var blocks: Int
    var delta: Double

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

func compare(replica: Bitmap, reference: Bitmap, block: Int) -> (strict: Double, blocks: [[Double]], changed: [[Bool]]) {
    // Strict: share of pixels whose channel delta exceeds a text-antialiasing floor.
    var differing = 0
    for y in 0..<reference.height {
        for x in 0..<reference.width {
            let a = replica.rgb(x, y)
            let b = reference.rgb(x, y)
            let delta = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
            if delta > 32 { differing += 1 }
        }
    }
    let strict = Double(differing) / Double(reference.width * reference.height) * 100

    // Block: mean colour per block, so glyph shape stops mattering.
    let columns = (reference.width + block - 1) / block
    let rows = (reference.height + block - 1) / block
    var deltas = [[Double]](repeating: [Double](repeating: 0, count: columns), count: rows)
    var changed = [[Bool]](repeating: [Bool](repeating: false, count: columns), count: rows)
    for row in 0..<rows {
        for column in 0..<columns {
            var sumA = (0.0, 0.0, 0.0), sumB = (0.0, 0.0, 0.0)
            var count = 0.0
            let yStart = row * block
            let yEnd = min(yStart + block, reference.height)
            let xStart = column * block
            let xEnd = min(xStart + block, reference.width)
            for y in yStart..<yEnd {
                for x in xStart..<xEnd {
                    let a = replica.rgb(x, y)
                    let b = reference.rgb(x, y)
                    sumA.0 += a.0; sumA.1 += a.1; sumA.2 += a.2
                    sumB.0 += b.0; sumB.1 += b.1; sumB.2 += b.2
                    count += 1
                }
            }
            let delta = max(abs(sumA.0 - sumB.0), abs(sumA.1 - sumB.1), abs(sumA.2 - sumB.2)) / count
            deltas[row][column] = delta
            changed[row][column] = delta > 0  // threshold applied by caller
        }
    }
    return (strict, deltas, changed)
}

/// Mean perceptual luminance. Two captures taken in different macOS appearance
/// modes differ by far more than any layout change, so this is checked before the
/// pixel numbers are trusted: a dark-vs-light pair reports ~99% and would send a
/// reviewer hunting for a defect that is not there.
func meanLuminance(_ bitmap: Bitmap) -> Double {
    var total = 0.0
    var count = 0.0
    for y in stride(from: 0, to: bitmap.height, by: 4) {
        for x in stride(from: 0, to: bitmap.width, by: 4) {
            let (r, g, b) = bitmap.rgb(x, y)
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
        }
    }
    return count > 0 ? total / count : 0
}

func cluster(deltas: [[Double]], tolerance: Double) -> [Region] {
    let rows = deltas.count
    let columns = rows > 0 ? deltas[0].count : 0
    var visited = [[Bool]](repeating: [Bool](repeating: false, count: columns), count: rows)
    var regions: [Region] = []
    for row in 0..<rows {
        for column in 0..<columns where !visited[row][column] && deltas[row][column] > tolerance {
            // Breadth-first flood over 8-connected differing blocks.
            var queue = [(row, column)]
            visited[row][column] = true
            var region = Region(minX: column, minY: row, maxX: column, maxY: row, blocks: 0, delta: 0)
            var cursor = 0
            while cursor < queue.count {
                let (y, x) = queue[cursor]
                cursor += 1
                region.blocks += 1
                region.delta += deltas[y][x]
                region.minX = min(region.minX, x); region.maxX = max(region.maxX, x)
                region.minY = min(region.minY, y); region.maxY = max(region.maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let ny = y + dy, nx = x + dx
                        guard ny >= 0, ny < rows, nx >= 0, nx < columns else { continue }
                        guard !visited[ny][nx], deltas[ny][nx] > tolerance else { continue }
                        visited[ny][nx] = true
                        queue.append((ny, nx))
                    }
                }
            }
            region.delta /= Double(max(region.blocks, 1))
            regions.append(region)
        }
    }
    // Small dust is antialiasing; a real layout difference covers many blocks.
    return regions.filter { $0.blocks >= 4 }.sorted { $0.blocks > $1.blocks }
}

// MARK: - rendering

func writePNG(_ bitmap: Bitmap, to path: String) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    bitmap.pixels.withUnsafeBytes { buffer in
        guard let context = CGContext(data: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                                      width: bitmap.width,
                                      height: bitmap.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bitmap.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo),
              let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Reference image, dimmed, with every differing region boxed in red and filled
/// with a translucent wash so a difference cannot hide behind similar colours.
func renderHeatmap(reference: Bitmap, regions: [Region], block: Int) -> Bitmap {
    var pixels = reference.pixels
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            pixels[index + channel] = UInt8(Double(pixels[index + channel]) * 0.55)
        }
    }
    var result = Bitmap(width: reference.width, height: reference.height, pixels: pixels)

    for region in regions {
        let x0 = region.minX * block
        let y0 = region.minY * block
        let x1 = min((region.maxX + 1) * block, reference.width) - 1
        let y1 = min((region.maxY + 1) * block, reference.height) - 1
        for y in y0...y1 {
            for x in x0...x1 {
                let offset = (y * result.width + x) * 4
                let edge = x <= x0 + 1 || x >= x1 - 1 || y <= y0 + 1 || y >= y1 - 1
                if edge {
                    result.pixels[offset] = 255; result.pixels[offset + 1] = 60; result.pixels[offset + 2] = 60
                } else {
                    result.pixels[offset] = UInt8(min(255, Double(result.pixels[offset]) + 90))
                    result.pixels[offset + 1] = UInt8(Double(result.pixels[offset + 1]) * 0.7)
                    result.pixels[offset + 2] = UInt8(Double(result.pixels[offset + 2]) * 0.7)
                }
                result.pixels[offset + 3] = 255
            }
        }
    }
    return result
}

func pngBase64(_ path: String) -> String {
    (try? Data(contentsOf: URL(fileURLWithPath: path)))?.base64EncodedString() ?? ""
}

func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - main

guard let options = parseOptions() else { exit(2) }
guard let replica = Bitmap.load(options.replica) else { exit(1) }
guard let reference = Bitmap.load(options.reference) else { exit(1) }

let outDir = URL(fileURLWithPath: options.outDir)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard replica.width == reference.width, replica.height == reference.height else {
    FileHandle.standardError.write(Data("""
    size mismatch: replica \(replica.width)x\(replica.height) vs reference \
    \(reference.width)x\(reference.height). Capture both at the same window size.

    """.utf8))
    exit(1)
}

let (strict, deltas, _) = compare(replica: replica, reference: reference, block: options.block)
let regions = cluster(deltas: deltas, tolerance: options.tolerance)

// A dark capture compared against a light one is not a defect in the app, it is a
// defect in the comparison. Say so instead of reporting 99%.
let replicaLuma = meanLuminance(replica)
let referenceLuma = meanLuminance(reference)
let appearanceMismatch = abs(replicaLuma - referenceLuma) > 40
let warning = appearanceMismatch
    ? "两侧截图不在同一外观模式下采集（平均亮度 \(Int(replicaLuma)) vs \(Int(referenceLuma))）。"
      + "像素差异在这个前提下没有参考价值，请用 Control Center 统一浅色/深色后重拍。"
    : ""

let heatmapPath = outDir.appendingPathComponent("\(options.label)-diff.png").path
writePNG(renderHeatmap(reference: reference, regions: regions, block: options.block), to: heatmapPath)

// Points are the unit the app speaks in; the captures are always @2x.
let scale = 2.0

struct Report: Encodable {
    let label: String
    let replica: String
    let reference: String
    let widthPt: Double
    let heightPt: Double
    let strictPercent: Double
    let regionCount: Int
    let warning: String
    let regions: [Row]
    struct Row: Encodable {
        let x: Double, y: Double, w: Double, h: Double
        let blocks: Int, delta: Double
    }
}

let report = Report(
    label: options.label,
    replica: options.replica,
    reference: options.reference,
    widthPt: Double(replica.width) / scale,
    heightPt: Double(replica.height) / scale,
    strictPercent: (strict * 100).rounded() / 100,
    regionCount: regions.count,
    warning: warning,
    regions: regions.map {
        Report.Row(x: (Double($0.minX * options.block) / scale).rounded(),
                   y: (Double($0.minY * options.block) / scale).rounded(),
                   w: (Double($0.width * options.block) / scale).rounded(),
                   h: (Double($0.height * options.block) / scale).rounded(),
                   blocks: $0.blocks,
                   delta: ($0.delta * 10).rounded() / 10)
    }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: outDir.appendingPathComponent("\(options.label)-diff.json"))

let rowsHTML = report.regions.enumerated().map { index, row -> String in
    """
    <tr><td class="n">\(index + 1)</td><td>\(Int(row.x)), \(Int(row.y))</td>\
    <td>\(Int(row.w)) × \(Int(row.h))</td><td>\(row.blocks)</td><td>\(row.delta)</td></tr>
    """
}.joined()

let html = """
<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UI parity · \(options.label)</title>
<style>
  :root { color-scheme: light dark; --fg:#1c1c1e; --dim:#6b6b70; --line:#d8d8dc; --bg:#fff; --panel:#f5f5f7; --bad:#c0392b; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#f2f2f7; --dim:#9a9aa0; --line:#3a3a3e; --bg:#141416; --panel:#1e1e21; --bad:#ff6b5e; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px 20px 60px; background:var(--bg); color:var(--fg);
         font:15px/1.55 -apple-system, "SF Pro Text", "PingFang SC", system-ui, sans-serif; }
  h1 { font-size:19px; margin:0 0 4px; }
  .sub { color:var(--dim); font-size:13px; margin-bottom:20px; }
  .stats { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:22px; }
  .stat { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 14px; min-width:112px; }
  .stat b { display:block; font-size:20px; font-variant-numeric:tabular-nums; }
  .stat span { color:var(--dim); font-size:12px; }
  .stat.bad b { color:var(--bad); }
  h2 { font-size:15px; margin:26px 0 10px; padding-bottom:6px; border-bottom:1px solid var(--line); }
  .slider { position:relative; width:100%; overflow:hidden; border:1px solid var(--line);
            border-radius:10px; background:#000; line-height:0; }
  .slider img { display:block; width:100%; height:auto; }
  .slider .after { position:absolute; inset:0; width:var(--split,50%); overflow:hidden; }
  .slider .after img { width:auto; height:100%; max-width:none; }
  input[type=range] { width:100%; margin:12px 0 0; }
  .hint { color:var(--dim); font-size:12px; margin-top:6px; }
  img.full { display:block; width:100%; height:auto; border:1px solid var(--line); border-radius:10px; }
  table { width:100%; border-collapse:collapse; font-size:13px; font-variant-numeric:tabular-nums; }
  th, td { text-align:left; padding:7px 8px; border-bottom:1px solid var(--line); }
  th { color:var(--dim); font-weight:600; font-size:12px; }
  td.n { color:var(--dim); width:2.2em; }
  .scroll { overflow-x:auto; }
  code { background:var(--panel); padding:1px 5px; border-radius:4px; font-size:12px; }
  .warn { background:color-mix(in srgb, #c0392b 12%, transparent); border-left:3px solid #c0392b;
          padding:10px 14px; border-radius:8px; color:var(--fg); font-size:13.5px; margin:0 0 18px; }
</style></head><body>

<h1>UI parity：复刻品 vs 参考实现</h1>
<div class="sub">\(options.label) · 画布 \(Int(report.widthPt))×\(Int(report.heightPt)) pt · 块 \(options.block) pt · 容差 \(Int(options.tolerance))</div>
\(warning.isEmpty ? "" : "<p class='warn'>⚠️ \(htmlEscape(warning))</p>")

<div class="stats">
  <div class="stat"><b>\(report.regionCount)</b><span>差异区域</span></div>
  <div class="stat bad"><b>\(String(format: "%.2f", report.strictPercent))%</b><span>逐像素差异</span></div>
  <div class="stat"><b>\(Int(report.widthPt))×\(Int(report.heightPt))</b><span>画布尺寸 pt</span></div>
</div>

<h2>拖动对比</h2>
<div class="slider" id="slider">
  <img src="data:image/png;base64,\(pngBase64(options.reference))" alt="参考实现">
  <div class="after" id="after"><img src="data:image/png;base64,\(pngBase64(options.replica))" alt="复刻品"></div>
</div>
<input type="range" min="0" max="100" value="50" id="split">
<div class="hint">左＝参考实现，右＝复刻品。拖动滑块看同一块区域两边的差别。</div>

<h2>差异热图</h2>
<img class="full" src="data:image/png;base64,\(pngBase64(heatmapPath))" alt="差异热图">
<div class="hint">灰底＝参考实现，红框＝自动检测到的差异区域。逐像素差异会被字体渲染放大，看红框位置更可靠。</div>

<h2>区域清单</h2>
<div class="scroll"><table>
<thead><tr><th>#</th><th>位置 pt</th><th>尺寸 pt</th><th>块数</th><th>平均差</th></tr></thead>
<tbody>
\(rowsHTML.isEmpty ? "<tr><td colspan=5>没有超过容差的差异区域</td></tr>" : rowsHTML)
</tbody></table></div>
<div class="hint">按块数排序：块数越大越可能是布局/结构差异，块数少的多半是文字或图标的绘制差异。</div>

<script>
  const slider = document.getElementById('split');
  const apply = () => document.getElementById('after').style.setProperty('--split', slider.value + '%');
  slider.addEventListener('input', apply); apply();
</script>
</body></html>
"""

let htmlPath = outDir.appendingPathComponent("\(options.label)-diff.html")
try html.write(to: htmlPath, atomically: true, encoding: .utf8)

print("""
\(options.label): \(regions.count) region(s), strict \(String(format: "%.2f", strict))%
  report  \(htmlPath.path)
  heatmap \(heatmapPath)
""")
if appearanceMismatch {
    FileHandle.standardError.write(Data("异常：\(warning)\n".utf8))
}
