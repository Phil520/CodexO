import Cocoa

// App 图标生成器：把 1024×1024 的图标画成 iconset，交给 iconutil 合成 .icns。
//
// 为什么不直接放大菜单栏那张 18pt 图标：
// 菜单栏图标是**为 18pt 优化**的（环细、月相小、留白紧），
// 放大成 1024px 之后那些细节会显得又细又碎，在 Finder 里几乎看不清。
// 所以这里按大图标的尺度重新配比，但**沿用同一套画法**（MoonShape + 同一条环），
// 这样两处看起来是同一个东西。
//
// 入口用 `@main` 而不是顶层代码：Swift 只允许名为 `main.swift` 的文件写顶层语句，
// 而本文件叫 make_icon.swift。build.sh 把它和 src/*.swift 一起编译成一个独立可执行文件，
// 跑完即退，不进 App 本体。
//
// `static func main()` 可以标 `throws`，由运行时在顶层调用它 —— 所以
// 里面写 `try` 不用自己包一层 do/catch，错误照样能以非零退出码报出来。
//
// 编译运行：
//   swiftc -swift-version 5 -O -framework Cocoa \
//     -o /tmp/make_icon tools/make_icon.swift src/MenuBarUI.swift \
//     src/UsageReader.swift src/Diagnostics.swift src/Soak.swift
//   /tmp/make_icon /tmp/CodexO.iconset
//   iconutil -c icns /tmp/CodexO.iconset -o <目标>.icns

@main
struct MakeIcon {

    static func main() throws {
        let base: CGFloat = 1024
        let iconsetPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/tmp/CodexO.iconset"

        // 透明底：菜单栏 App 的图标不该有方形底板。
        var pixels = [UInt8](repeating: 0, count: Int(base * base * 4))
        var context: CGContext!
        pixels.withUnsafeMutableBytes { raw in
            context = CGContext(data: raw.baseAddress!,
                                width: Int(base), height: Int(base),
                                bitsPerComponent: 8, bytesPerRow: Int(base) * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }

        let center = CGPoint(x: base / 2, y: base / 2)
        let lineWidth: CGFloat = base * 0.085
        let radius: CGFloat = base / 2 - lineWidth / 2 - base * 0.045
        let discRadius: CGFloat = radius - lineWidth / 2 - base * 0.022

        // 内圈：满月。选满月是因为它最好认 —— 图标要的是「小而清楚」，
        // 不是「把七档都塞进去」（承担七档表达的是菜单栏图标）。
        MoonShape.draw(in: context, center: center, radius: discRadius, phase: 1.0,
                       light: Palette.moonColor,
                       dark: NSColor(calibratedWhite: 0.5, alpha: 0.22))

        // 外圈底环
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 0.28)
            .usingColorSpace(.deviceRGB)!.cgColor)
        context.addArc(center: center, radius: radius,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()

        // 外圈进度：画 7/10，一眼能看出「这是个进度环」
        let clamped = CGFloat(0.7)
        context.setStrokeColor(NSColor(srgbRed: 0.20, green: 0.72, blue: 0.32, alpha: 1)
            .usingColorSpace(.deviceRGB)!.cgColor)
        context.addArc(center: center, radius: radius,
                       startAngle: .pi / 2,
                       endAngle: .pi / 2 - 2 * .pi * clamped,
                       clockwise: true)
        context.strokePath()

        let rendered = NSImage(cgImage: context.makeImage()!,
                               size: NSSize(width: base, height: base))

        // 导出 iconset 所需的全部尺寸
        try? FileManager.default.removeItem(atPath: iconsetPath)
        try FileManager.default.createDirectory(atPath: iconsetPath,
                                                withIntermediateDirectories: true)

        let variants: [(px: Int, name: String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"),
            (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"),
            (256, "icon_256x256"), (512, "icon_256x256@2x"),
            (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]

        for variant in variants {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: variant.px, pixelsHigh: variant.px,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: variant.px, height: variant.px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            rendered.draw(in: NSRect(x: 0, y: 0,
                                     width: CGFloat(variant.px), height: CGFloat(variant.px)),
                          from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            let data = rep.representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(variant.name).png"))
        }

        print("iconset 已生成：\(iconsetPath)（\(variants.count) 个尺寸）")
    }
}
