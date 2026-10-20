import Cocoa

// 直读当前生效的档位定义与上限，打印各档理论面积与相邻差。
// 用途：改完 moonLevelValues / moonTerminatorCeiling 后快速核对，
// 免得"改了但没生效"却看不出来 —— 那正是我这次差点交出去的错误。

print("moonLevelValues =", Palette.moonLevelValues)
print("moonTerminatorCeiling =", Palette.moonTerminatorCeiling)
print("moonThresholds =", [20.0, 35.0, 45.0, 55.0, 70.0, 90.0])
print()

print("档  名称phase   ratio    理论面积%")
var areas: [Double] = []
for i in 1...Palette.moonLevelCount {
    let p = Palette.moonPhaseForLevel(i)
    let rt = Palette.moonTerminatorRatio(forPhase: p)
    let a = (1 - Double(rt)) / 2 * 100
    areas.append(a)
    print(String(format: "档%d  %@  %.2f  %+.3f  %6.2f%%",
                 i, Palette.moonNameForLevel(i) as NSString, p, Double(rt), a))
}

print("\n相邻面积差（判据：每档都要 ≥ 6 个百分点，否则肉眼看不出区别）")
var minGap = Double.greatestFiniteMagnitude
for i in 1..<areas.count {
    let gap = areas[i] - areas[i - 1]
    minGap = min(minGap, gap)
    print(String(format: "  档%d → 档%d   %+.2f %@",
                 i, i + 1, gap, (gap >= 6 ? "✅" : "❌") as NSString))
}
print(String(format: "\n最小相邻差 %.2f 个百分点 %@", minGap,
             (minGap >= 6 ? "✅ 全部可辨" : "❌ 有档位分不开") as NSString))

print("\n18pt@2x（整圆约 471px）下各档亮面像素")
let circle = 471.0
for (i, a) in areas.enumerated() {
    print(String(format: "  档%d %@  %5.0f px", i + 1,
                 Palette.moonNameForLevel(i + 1) as NSString, circle * a / 100))
}