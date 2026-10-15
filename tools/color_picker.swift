import Cocoa

// 配色候选对照页：同一个"内圈月相"设计，只换亮面颜色。
// 存在的意义：颜色这种事靠描述容易扯皮，把四支候选画在同一张图上、
// 深浅两种菜单栏底色各一条，一眼就能定。
// 编译运行：
//   swiftc -swift-version 5 -framework Cocoa \
//     -o /tmp/color_picker src/UsageReader.swift src/MenuBarUI.swift tools/color_picker.swift
//   /tmp/color_picker

let outDir = "/tmp/codex-menuicon-preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let scale: CGFloat = 3
let barLight = NSColor(calibratedWhite: 0.95, alpha: 1)
let barDark = NSColor(calibratedWhite: 0.14, alpha: 1)
let paper = NSColor(calibratedWhite: 1.0, alpha: 1)
let textOnLight = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
let textOnDark = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor
let textOnPaper = NSColor(calibratedWhite: 0.32, alpha: 1).cgColor

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

/// 候选亮面色。深浅两种底色下都要能看清，这是唯一的硬指标。
let candidates: [(name: String, hex: UInt32, note: String)] = [
    ("A 暖黄",   0xFFD24A, "当前实现。饱和度高，浅色底上不糊"),
    ("B 琥珀",   0xFFB020, "更深更暖，存在感最强"),
    ("C 淡金",   0xF7E7A6, "接近月色，浅色底上会偏弱"),
    ("D 月白",   0xDCE6F5, "冷白，最像月亮；浅色底上几乎看不见"),
]

func makeIcon(fiveHour: Double, weekly: Double?, lit: NSColor, size: CGFloat) -> NSImage {
    IconFactory.icon(fiveHour: fiveHour / 100,
                     fiveHourColor: Palette.color(forRemaining: fiveHour),
                     moonPhase: weekly.map { Palette.moonPhase(forRemaining: $0) },
                     moonColor: lit,
                     size: size, scale: scale)
}

func makeContext(width: CGFloat, height: CGFloat) -> CGContext? {
    guard let ctx = CGContext(data: nil,
                              width: Int(width * scale),
                              height: Int(height * scale),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.scaleBy(x: scale, y: scale)
    return ctx
}

func draw(_ ctx: CGContext, _ icon: NSImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    guard let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    ctx.draw(cg, in: CGRect(x: x, y: y, width: size, height: size))
}

func textWidth(_ string: String, size: CGFloat) -> CGFloat {
    guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return 0 }
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
    ])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
}

func drawText(_ ctx: CGContext, _ string: String, x: CGFloat, baseline y: CGFloat,
              size: CGFloat, color: CGColor) {
    guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return }
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func drawText(_ ctx: CGContext, _ string: String, centeredAtX cx: CGFloat, baseline y: CGFloat,
              size: CGFloat, color: CGColor) {
    drawText(ctx, string, x: cx - textWidth(string, size: size) / 2, baseline: y, size: size, color: color)
}

let levels = Palette.moonLevelValues
let cols = levels.count

struct Row {
    let background: NSColor
    let text: CGColor
    let note: String
    let iconSize: CGFloat
}

let rows = [
    Row(background: barLight, text: textOnLight, note: "浅色菜单栏 · 真实 18pt", iconSize: 18),
    Row(background: barDark, text: textOnDark, note: "深色菜单栏 · 真实 18pt", iconSize: 18)
]

let leftMargin: CGFloat = 190
let cell: CGFloat = 66
let width = leftMargin + cell * CGFloat(cols) + 20
let header: CGFloat = 34
let rowGap: CGFloat = 12
let barHeight: CGFloat = 52
let height = header + CGFloat(candidates.count) * (2 * barHeight + 34 + rowGap) + 10

guard let ctx = makeContext(width: width, height: height) else { exit(1) }
ctx.setFillColor(paper.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

drawText(ctx, "内圈亮面配色候选：同一套月相，只换亮面颜色。每支都在浅色 / 深色两种底色上各画一条",
         x: 16, baseline: height - 20, size: 12, color: textOnPaper)

var top = height - header
for candidate in candidates {
    let lit = rgb(candidate.hex)

    top -= 22
    let hexText = String(format: "#%06X", candidate.hex)
    ctx.setFillColor(lit.cgColor)
    ctx.fillEllipse(in: CGRect(x: 16, y: top - 5, width: 11, height: 11))
    drawText(ctx, "\(candidate.name)  \(hexText)　\(candidate.note)",
             x: 34, baseline: top, size: 12, color: textOnPaper)

    for row in rows {
        top -= barHeight
        ctx.setFillColor(row.background.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: width, height: barHeight))
        drawText(ctx, row.note, x: 16, baseline: top + barHeight / 2 - 4, size: 10, color: row.text)

        for (column, value) in levels.enumerated() {
            let cx = leftMargin + cell * (CGFloat(column) + 0.5)
            let icon = makeIcon(fiveHour: 70, weekly: value, lit: lit, size: row.iconSize)
            draw(ctx, icon, x: cx - row.iconSize / 2, y: top + 22, size: row.iconSize)
            drawText(ctx, "\(Int(value))%", centeredAtX: cx, baseline: top + 10,
                     size: 9, color: row.text)
        }
        top -= 4
    }
    top -= rowGap
}

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
if let png = rep.representation(using: .png, properties: [:]) {
    let path = "\(outDir)/moon_color_candidates.png"
    try? png.write(to: URL(fileURLWithPath: path))
    print(path)
}
