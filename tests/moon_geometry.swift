import Cocoa

// 月相几何的像素级验证。
//
// 目的：确认「档位 → 月相」这条链路真的成立，且没有把月画画歪。
// 肉眼判断在小尺寸下不可靠 —— 18pt 图标里的月牙只有几个像素，
// 稍微偏一点，肉眼完全看不出来，但用户看到的就是偏的那一版。
//
// 这里量两件事：
//   1. 每档实际渲染出来的**亮面面积占比**；
//   2. 该档余量的**理论面积占比**。
//
// 面积才是月相该被检验的量：月相本来就是「被照亮了多少」。

let side = 240                    // 放大到 240pt 再量，避开小尺寸抗锯齿误差
let px = side                     // 1x 就够，240px 已经很密

/// 自管位图缓冲：直接把 CGContext 画进我们自己的内存，
/// 画完就地读像素。不走 makeImage/dataProvider 那条路 ——
/// 那条路依赖 CGDataProvider 的惰性存储，在独立命令行程序里容易出意外。
final class Canvas {
    let bytesPerRow: Int
    /// 自己管一块内存交给 CGContext，画完直接读它。
    /// 用 [UInt8] 而不是 NSMutableData：后者的 mutableBytes 是可空，
    /// 强拆会多出一串噪音。
    var pixels: [UInt8]
    let context: CGContext

    init() {
        let stride = px * 4
        pixels = [UInt8](repeating: 0, count: stride * px)
        bytesPerRow = stride

        // 局部变量先建好再赋给属性：
        // 在 withUnsafeMutableBytes 闭包里直接给 let 属性赋值是不允许的。
        var made: CGContext? = nil
        pixels.withUnsafeMutableBytes { raw in
            made = CGContext(data: raw.baseAddress!,
                             width: px, height: px,
                             bitsPerComponent: 8,
                             bytesPerRow: stride,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        context = made!

        // 纯黑底。暗面也设成可区分的灰。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: px, height: px))
    }

    func channel(_ x: Int, _ y: Int, _ c: Int) -> Double {
        Double(pixels[y * bytesPerRow + x * 4 + c])
    }
}

func measure(phase: Double) -> Double {
    let c = Canvas()
    // 亮面纯白，暗面 0.25 灰 → 阈值 160 能干净分开
    MoonShape.draw(in: c.context,
                   center: CGPoint(x: Double(px) / 2, y: Double(px) / 2),
                   radius: Double(px) / 2,
                   phase: phase,
                   light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                   dark: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1))

    let cx = Double(px) / 2
    let r = Double(px) / 2
    var lit = 0, total = 0
    for y in 0..<px {
        for x in 0..<px {
            let dx = Double(x) + 0.5 - cx
            let dy = Double(y) + 0.5 - cx
            guard dx * dx + dy * dy <= r * r * 0.999 else { continue }
            let b = (c.channel(x, y, 0) + c.channel(x, y, 1) + c.channel(x, y, 2)) / 3
            total += 1
            if b > 160 { lit += 1 }
        }
    }
    return Double(lit) / Double(max(1, total))
}

print("=== 月相几何 · 像素级实测（\(px)×\(px) 实际渲染后数像素）===")
print("档  余量    名称     亮度  界线系数   实测亮面   理论亮面    偏差")

var results: [(level: Int, remaining: Double, name: String, phase: Double,
               ratio: Double, measured: Double, theoretical: Double)] = []

for level in 1...Palette.moonLevelCount {
    let remaining = Palette.moonLevelValues[level - 1]
    let phase = Palette.moonPhase(forRemaining: remaining)
    let ratio = Double(Palette.moonTerminatorRatio(forPhase: phase))
    let name = Palette.moonName(forRemaining: remaining)
    let m = measure(phase: phase)
    // 理论亮面**面积**不是 phase 本身。
    // phase 是喂给 cos 的「亮度参数」，几何上对应的是明暗界线的弦长比 ratio，
    // 圆被一条竖直弦切掉的面积占全圆的比例正好是 (1 - ratio)/2。
    // （我第一版误把 phase 当面积，判据自己就错了 —— 那种错会掩盖真 bug，
    //   因为「七档全是 50%」在错误判据下看着还挺像那么回事。）
    let theory = (1 - ratio) / 2
    results.append((level, remaining, name, phase, ratio, m, theory))

    print(String(format: "%2d %6.0f%%  %@  %.2f   %+.3f    %6.2f%%   %6.2f%%   %+.2f%%",
                 level, remaining, name, phase, ratio,
                 m * 100, theory * 100, (m - theory) * 100))
}

print("\n=== 判据 1：实测亮面 ≈ 理论亮面（容差 4 个百分点）===")
var allPass = true
for r in results {
    let ok = abs(r.measured - r.theoretical) <= 0.04
    if !ok { allPass = false }
    print(String(format: "档 %d %@：实测 %6.2f%% vs 理论 %6.2f%% → %@",
                 r.level, r.name, r.measured * 100, r.theoretical * 100, ok ? "✅" : "❌"))
}
print(allPass ? "→ 七档全部吻合" : "→ 存在偏差过大的档位")

print("\n=== 判据 2：余量↑ 必须 亮面↑（单调）===")
var mono = true
for i in 1..<results.count {
    let grew = results[i].measured > results[i - 1].measured
    if !grew { mono = false }
    print(String(format: "档%d(余%.0f%%) → 档%d(余%.0f%%)：%6.2f%% → %6.2f%%  %@",
                 results[i - 1].level, results[i - 1].remaining,
                 results[i].level, results[i].remaining,
                 results[i - 1].measured * 100, results[i].measured * 100,
                 grew ? "✅" : "❌ 反而变暗"))
}
print(mono ? "→ 亮面随余量严格递增" : "→ 亮面与余量不是单调递增")

print("\n=== 判据 3：七档在面积上是否真的分得开（相邻档差 ≥ 2 个百分点）===")
var separable = true
for i in 1..<results.count {
    let gap = (results[i].measured - results[i - 1].measured) * 100
    let ok = gap >= 2
    if !ok { separable = false }
    print(String(format: "档%d → 档%d 面积差 %.2f%% %@",
                 results[i - 1].level, results[i].level, gap, ok ? "✅" : "❌ 区分不开"))
}
print(separable ? "→ 七档彼此可辨" : "→ 有相邻两档在面积上几乎重合")
