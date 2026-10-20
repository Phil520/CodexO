import Cocoa

// 最小复现：只画七档，什么额外逻辑都不加。
// 目的：排除 probe_render_png.swift 里那些与月相无关的代码
//（白底铺陈、Canvas 缓冲、CGImageDestination 写出）干扰判断。
//
// 起因很具体：改完 moonLevelValues 与 moonTerminatorCeiling 之后，
// 探针自报 phase/ratio 全都正确（0.10→1.00 / 0.90→-1.00），
// 但导出的 PNG 与改动前**逐字节相同**。
// 值对了而图没变，只有两种可能：要么渲染没读这个值，
// 要么图根本没被重写。这个文件只做前一件事，用最少的代码问最直接的问题。

let side = 120
let cell = side
let radius = CGFloat(side) * 0.36

func makeCanvas(_ n: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: n, height: n,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
    return ctx
}

let names = Palette.moonLevelCount
let sheet = makeCanvas(cell * names)
print("=== 最小复现：七档 → 一张图 ===")
for level in 1...names {
    let phase = Palette.moonPhaseForLevel(level)
    let ratio = Palette.moonTerminatorRatio(forPhase: phase)
    let c = CGPoint(x: CGFloat(cell * (level - 1)) + CGFloat(cell) / 2,
                     y: CGFloat(cell) / 2)
    MoonShape.draw(in: sheet, center: c, radius: radius, phase: phase)
    print(String(format: "  档%d %@ phase=%.2f ratio=%+.3f",
                 level, Palette.moonNameForLevel(level) as NSString,
                 phase, Double(ratio)))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
let path = "\(outDir)/moon_minimal.png"
if let img = sheet.makeImage(),
   let dest = CGImageDestinationCreateWithURL(
     URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("  → \(path)")
} else {
    print("  ✗ 导出失败")
}