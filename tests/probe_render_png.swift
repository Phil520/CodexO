import Cocoa

// 把七档月相渲染成 PNG，用眼睛看。
//
// 走到这一步的原因：像素统计连着骗了我两次 ——
//   ① moon_legibility 用「RGB 距离猜亮/暗」，被半透明暗面带偏，
//      报出「满月缺 9.45 个百分点」的假警报；
//   ② 第二个探针想量亮面，却忘了暗面铺的是不透明纯黑、alpha 铺满整颗圆，
//      于是数出来的其实是暗面的覆盖（七档全是 101.3%，连档1"眉月"都是）。
// 两次都是"数字看起来很有理有据，量的却不是想量的东西"。
//
// 数字判据可以用来**防回归**，但不能用来**发现**问题。
// 「七档形状对不对」这种问题，看一眼图比数一千个像素更快也更可靠。
//
// ⚠️ 这份文件只渲染当前的 MoonShape 实现，不做任何断言 ——
// 它是**目视工具**，不是测试。判断交给眼睛。

final class Canvas {
    let px: Int
    let ctx: CGContext
    private var buf: [UInt8]
    private let rowBytes: Int

    init(side: Int) {
        let rb = side * 4
        var b = [UInt8](repeating: 0, count: rb * side)
        var made: CGContext? = nil
        b.withUnsafeMutableBytes { r in
            made = CGContext(data: r.baseAddress!, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: rb,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        px = side; rowBytes = rb; buf = b; ctx = made!
    }

    /// 先垫一层白底再导出。
    ///
    /// ⚠️ 为什么不能"画完月相再铺白底"：premultipliedLast 下后画的会盖住先画的，
    /// 白底会把月相整个盖掉，导出一张全白的图（踩过一次）。
    /// 所以顺序必须是：**先铺白底 → 再画月相 → 导出**。
    /// 调用方负责在画月相之前先调一次 `prepareBackground()`。
    func prepareBackground(color: NSColor = .white) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    }

    func writePNG(to path: String) {
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
            print("✗ 写图失败：\(path)")
            return
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
let scale = 6
let names = ["1-眉月", "2-蛾眉月", "3-渐盈月", "4-上弦月", "5-渐凸月", "6-盈凸月", "7-满月"]

print("=== 七档月相 → PNG（放大 \(scale) 倍，用眼睛看形状）===")
for spec in [(label: "18pt", pt: 18.0), (label: "22pt", pt: 22.0)] {
    let side = Int(spec.pt * CGFloat(scale))
    let radius = spec.pt * 0.34 * CGFloat(scale)
    let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
    for level in 1...7 {
        let canvas = Canvas(side: side)
        canvas.prepareBackground()          // ← 白底先铺
        MoonShape.draw(in: canvas.ctx,      // ← 月相后画
                       center: center,
                       radius: radius,
                       phase: Palette.moonPhaseForLevel(level))
        let path = "\(outDir)/moon_\(spec.label)_\(names[level-1]).png"
        canvas.writePNG(to: path)
        print("  \(spec.label) 档\(level) \(names[level-1])  → \(path)")
    }
}

// 七档并排，一眼看全
print("\n=== 七档并排对照图 ===")
let cell = 130
let sheet = Canvas(side: cell * 7)
sheet.prepareBackground()
for level in 1...7 {
    let c = CGPoint(x: CGFloat(cell * (level - 1)) + CGFloat(cell) / 2,
                     y: CGFloat(cell) / 2)
    let phase = Palette.moonPhaseForLevel(level)
    let ratio = Palette.moonTerminatorRatio(forPhase: phase)
    // ⚠️ 把每档实际用到的 phase 与 ratio 打出来。
    // 这一行是专门加的：改完 moonLevelValues 之后图却毫无变化，
    // 光看图无法判断是"没生效"还是"我看错了"。
    // 数字对得上而图不变 → 问题在渲染；数字没变→ 问题在取值。
    print("  档\(level) \(Palette.moonNameForLevel(level)) phase=\(phase) ratio=\(String(format: "%.3f", Double(ratio)))")
    MoonShape.draw(in: sheet.ctx, center: c,
                   radius: CGFloat(cell) * 0.36,
                   phase: phase)
}
sheet.writePNG(to: "\(outDir)/moon_all7.png")
print("  → \(outDir)/moon_all7.png")