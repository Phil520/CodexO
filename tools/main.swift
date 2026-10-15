import Cocoa

// 图标预览生成器：把菜单栏图标在浅色 / 深色菜单栏下的实际观感画成 PNG
// 编译运行：
//   swiftc -swift-version 5 -framework Cocoa \
//     -o /tmp/icon_preview src/UsageReader.swift src/MenuBarUI.swift tools/main.swift
//   /tmp/icon_preview

let outDir = "/tmp/codex-menuicon-preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let scale: CGFloat = 3

let barLight = NSColor(calibratedWhite: 0.95, alpha: 1)
let barDark = NSColor(calibratedWhite: 0.14, alpha: 1)
let paper = NSColor(calibratedWhite: 1.0, alpha: 1)
let textOnLight = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
let textOnDark = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor
let textOnPaper = NSColor(calibratedWhite: 0.32, alpha: 1).cgColor

func makeIcon(fiveHour: Double, weekly: Double?, size: CGFloat = 18) -> NSImage {
    IconFactory.icon(fiveHour: fiveHour / 100,
                     fiveHourColor: Palette.color(forRemaining: fiveHour),
                     moonPhase: weekly.map { Palette.moonPhase(forRemaining: $0) },
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
    let width = textWidth(string, size: size)
    drawText(ctx, string, x: cx - width / 2, baseline: y, size: size, color: color)
}

func textWidth(_ string: String, size: CGFloat) -> CGFloat {
    guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return 0 }
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
    ])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
}

func save(_ ctx: CGContext, _ name: String) {
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let path = "\(outDir)/\(name).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("  \(path)")
}

// MARK: - 图一：七档月相（真实 18pt 尺寸 + 放大对照）

do {
    struct Row {
        let background: NSColor
        let text: CGColor
        let note: String
        let iconSize: CGFloat
    }

    let levelValues = Palette.moonLevelValues
    let cols = levelValues.count

    let rows: [Row] = [
        Row(background: barLight, text: textOnLight,
            note: "浅色菜单栏 · 真实 18pt", iconSize: 18),
        Row(background: barDark, text: textOnDark,
            note: "深色菜单栏 · 真实 18pt", iconSize: 18),
        Row(background: paper, text: textOnPaper,
            note: "放大 3× 对照（看清月相边界）", iconSize: 54)
    ]

    let leftMargin: CGFloat = 210
    // 单元格要放得下最大那颗图标，否则放大行会互相压在一起
    let cell: CGFloat = 66
    let width = leftMargin + cell * CGFloat(cols) + 16
    let headerHeight: CGFloat = 30
    let gap: CGFloat = 10
    let barHeight = rows[2].iconSize + 34
    let swatchHeight: CGFloat = 34
    let height = headerHeight + (barHeight + gap) * CGFloat(rows.count) + swatchHeight + 16

    guard let ctx = makeContext(width: width, height: height) else { exit(1) }

    ctx.setFillColor(paper.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    drawText(ctx, "内圈月相七档：外圈固定 5H=70%，月亮越圆 = 每周余量越多",
             x: 16, baseline: height - 20, size: 12, color: textOnPaper)

    for (index, row) in rows.enumerated() {
        let y = height - headerHeight - CGFloat(index + 1) * (barHeight + gap)

        ctx.setFillColor((row.background.usingColorSpace(.deviceRGB) ?? row.background).cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: width, height: barHeight))

        drawText(ctx, row.note, x: 16, baseline: y + barHeight / 2 - 4, size: 11, color: row.text)

        for (column, value) in levelValues.enumerated() {
            let cx = leftMargin + cell * (CGFloat(column) + 0.5)
            let icon = makeIcon(fiveHour: 70, weekly: value, size: row.iconSize)
            draw(ctx, icon, x: cx - row.iconSize / 2, y: y + 26, size: row.iconSize)
            drawText(ctx, "\(Int(value))%", centeredAtX: cx, baseline: y + 14, size: 10, color: row.text)
            drawText(ctx, "\(Palette.moonName(forRemaining: value))",
                     centeredAtX: cx, baseline: y + 3, size: 9, color: row.text)
        }
    }

    // 最下一行：菜单里那个 14pt 月相图例，走的是 MoonView 这条独立绘制路径，
    // 和菜单栏图标不是同一段代码，必须单独出图确认两者形状一致
    let swatchY: CGFloat = 6
    for (column, value) in levelValues.enumerated() {
        let cx = leftMargin + cell * (CGFloat(column) + 0.5)
        let view = MoonView(side: 14)
        view.phase = Palette.moonPhase(forRemaining: value)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { continue }
        ctx.draw(cg, in: CGRect(x: cx - 7, y: swatchY + 4, width: 14, height: 14))
    }
    drawText(ctx, "菜单里的月相图例（14pt，MoonView 独立绘制）",
             x: 16, baseline: swatchY + 7, size: 11, color: textOnPaper)

    save(ctx, "moon_phases")
}

// MARK: - 图二：菜单栏实况模拟

do {
    let snapshot = UsageReader.load()
    let five = snapshot.fiveHour?.remaining ?? 0
    let week = snapshot.weekly?.remaining

    let width: CGFloat = 470
    let menuBarHeight: CGFloat = 22
    let rowHeight = menuBarHeight + 26
    let zoom: CGFloat = 5
    let zoomSize = 18 * zoom
    let height = 20 + rowHeight * 2 + 24 + zoomSize + 20

    guard let ctx = makeContext(width: width, height: height) else { exit(1) }

    ctx.setFillColor(paper.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func bar(y: CGFloat, background: NSColor, text: CGColor, title: String) {
        ctx.setFillColor((background.usingColorSpace(.deviceRGB) ?? background).cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: width, height: menuBarHeight))

        let icon = makeIcon(fiveHour: five, weekly: week, size: 18)
        let iconX = width - 110
        draw(ctx, icon, x: iconX, y: y + (menuBarHeight - 18) / 2, size: 18)
        drawText(ctx, Format.percent(five),
                 centeredAtX: iconX + 18 + 24, baseline: y + 7, size: 13, color: text)

        ctx.setStrokeColor(text.copy(alpha: 0.25)!)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: width, y: y))
        ctx.strokePath()

        drawText(ctx, title, centeredAtX: width - 56, baseline: y - 14, size: 11, color: text)
    }

    bar(y: height - 20 - menuBarHeight, background: barLight, text: textOnLight, title: "浅色菜单栏")
    bar(y: height - 20 - rowHeight - menuBarHeight, background: barDark, text: textOnDark, title: "深色菜单栏")

    // 放大图（画在白底上，便于核对月相边界）
    draw(ctx, makeIcon(fiveHour: five, weekly: week, size: zoomSize), x: 24, y: 16, size: zoomSize)

    let phase = week.map { Palette.moonDescription(forRemaining: $0) } ?? "无数据"
    drawText(ctx, "当前 5H=\(Format.percent(five))　周=\(week.map { Format.percent($0) } ?? "—")　\(phase)",
             x: 24 + zoomSize + 20, baseline: 16 + zoomSize / 2, size: 13, color: textOnPaper)
    save(ctx, "menubar_sim")
}

print("预览已生成。")
