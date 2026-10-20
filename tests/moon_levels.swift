import Cocoa

// 月相档位的**设计判据**（不是渲染判据 —— 渲染由 tests/moon_geometry.swift 负责）。
//
// ⭐⭐ 为什么这个文件不再去数像素：
//
// 2026-10-20 踩了两个坑，两次都是"数字很有理有据，量的却不是想量的东西"：
//
//   ① 先写 moon_legibility.swift，按「RGB 距离判断每个像素更像亮还是暗」来数面积。
//      暗面是 alpha=0.38 的半透明灰，预乘后 RGB 被稀释到 (48,48,48)，
//      抗锯齿边缘的混合像素被随机判成暗 —— 边缘越长误判越多，
//      于是报出「偏差随余量单调放大、满月缺 9.45 个百分点」的**假警报**，
//      我据此以为渲染有 bug，改完反而把七档全画成了右半圆。
//
//   ② 第二个探针想绕开它，改成「暗面铺不透明纯黑，只量亮面 alpha」——
//      但纯黑 alpha=1 铺满整颗圆，数出来的是**暗面**的覆盖，
//      七档全是 101.3%，连档1「眉月」也是。
//
// 结论：**档位设计对不对，用数学算就够，不必过像素。**
// 档位 → phase → ratio → 亮面面积，这四步全是解析式，
// 直接算比数像素更准、更快，也不会被抗锯齿牵着走。
// 像素那一层留给 moon_geometry.swift 去验「画出来的是不是这个形状」。
//
// 这里要抓的是**设计层面**的两个真实问题（2026-10-20 实测发现）：
//   1. 最低档被clamp 夸大到 4.5 倍（天文2.45% 画成 11.00%）；
//   2. 最高两档几乎画成同一个形状（档6/档7 面积只差 9.55%，肉眼分不出）。

/// 相邻两档的最小面积差（百分点）。
///
/// ⚠️ 取 12 是**标定**出来的，不是拍的：
///   改动前的实现最小相邻差是 9.55（档6/档7），肉眼几乎分不出那两档；
///   改动后是 13.13。门槛卡在两者中间的 12 ——
///   低于它就抓不住"档6 档7 长一个样"这个问题，高于它新实现自己也会误伤。
///   **门槛必须先用修复前的实现跑一遍来定**，否则要么漏、
///   要么写出一个"怎么改都能过"的假判据。
private let minAreaGap: Double = 12

/// 最低档亮面面积的下限与上限。
///
/// 下限 3.5%：太细就看不见。18pt@2x 下整颗圆约 471 像素，
/// 3.5% 约 17 像素，是一根看得清粗细的月牙。
/// 上限 8%：这是「不能太胖」那一条的门槛。
///   改动前是 11.00% —— 天文该是 2.45% 的细月牙，被 clamp 夸大到 4.5 倍，
///   看着已经是小半个圆了，和档2（20.61%）的差距被压到 9.6%。
///   改动后是 5.00%，是个货真价实的眉月。
private let minAreaFloor: Double = 3.5
private let lowestAreaCeiling: Double = 8.0

/// 最高档必须是满月（100%）
private let fullMoonArea: Double = 100.0

print("=== 判据一：各档亮面面积必须单调递增 ===\n")
print("档  名称     phase   ratio     亮面面积%")
var areas: [Double] = []
var names: [String] = []
for level in 1...Palette.moonLevelCount {
    let phase = Palette.moonPhaseForLevel(level)
    let ratio = Double(Palette.moonTerminatorRatio(forPhase: phase))
    // ratio 是明暗界线的**弦长比**（横轴方向），
    // 圆被那条竖直弦切掉的面积占全圆的比例正好是 (1 - ratio)/2。
    let area = (1 - ratio) / 2 * 100
    areas.append(area)
    names.append(Palette.moonNameForLevel(level))
    print(String(format: "档%d  %@  %.2f  %+.3f   %6.2f%%",
                 level, names[level-1] as NSString, phase, ratio, area))
}
print()

var failures: [String] = []

var monotonic = true
for i in 1..<areas.count where areas[i] <= areas[i - 1] {
    monotonic = false
    failures.append("档\(i)（\(areas[i-1])%）与档\(i+1)（\(areas[i])%）面积未递增")
}
print(monotonic
      ? "✅ 单调递增：余量越高，月亮越圆"
      : "❌ 有档位面积未递增：\n   " + failures.joined(separator: "\n   "))

print("\n=== 判据二：相邻档面积差 ≥ \(minAreaGap) 个百分点 ===\n")
print("档→档    面积差     判定")
var minGap = Double.greatestFiniteMagnitude
for i in 1..<areas.count {
    let gap = areas[i] - areas[i - 1]
    minGap = min(minGap, gap)
    let ok = gap >= minAreaGap
    if !ok {
        failures.append("档\(i)→档\(i+1)（\(names[i-1])→\(names[i])）只差 \(String(format: "%.2f", gap)) 个百分点，肉眼分不开")
    }
    print(String(format: "档%d→档%d   %+.2f   %@",
                 i, i + 1, gap, (ok ? "✅" : "❌") as NSString))
}
print(String(format: "\n最小相邻差 %.2f 个百分点（门槛 %.0f）", minGap, minAreaGap))
if minGap >= minAreaGap {
    print("✅ 七档彼此可辨")
} else {
    print("❌ 有档位在菜单栏上会看成一个样")
}

print("\n=== 判据三：最低档不能太细（看不见），也不能太胖（跟次档混淆）===\n")
let lowest = areas[0]
print(String(format: "档1 %@ 亮面 %.2f%%（18pt@2x 约 %.0f 像素）",
             names[0] as NSString, lowest, 471 * lowest / 100))
if lowest < minAreaFloor {
    failures.append("档1 只有 \(String(format: "%.2f", lowest))%，在菜单栏上细到看不见")
    print("❌ 太细，看不见")
} else {
    print("✅ 细但可见")
}
if lowest > lowestAreaCeiling {
    failures.append("""
    档1 有 \(String(format: "%.2f", lowest))%，被 clamp 夸大得太多\
    （天文该是 2.45%），看着已经是小半个圆，跟档2 混淆
    """)
    print("❌ 太胖，不是眉月该有的样子")
} else {
    print("✅ 胖瘦得当")
}

print("\n=== 判据四：最高档必须是满月 ===\n")
let highest = areas[areas.count - 1]
print(String(format: "档%d %@ 亮面 %.2f%%", Palette.moonLevelCount,
             names[names.count-1] as NSString, highest))
if abs(highest - fullMoonArea) > 0.01 {
    failures.append("最高档只有 \(String(format: "%.2f", highest))%，不是满月")
    print("❌ 不是满月")
} else {
    print("✅ 满月")
}

print("\n=== 结论 ===")
if failures.isEmpty {
    print("✅ 四条判据全过 —— 七档月相在设计上站得住")
} else {
    print("❌ 有 \(failures.count) 处不达标：")
    for f in failures { print("   • \(f)") }
    print()
    print("→ 修法：调 moonLevelValues（各档代表值）与 moonTerminatorCeiling（最低档上限）。")
    print("   用 `bash build.sh` 跑本测试，或跑 probe_render_png.swift 出图肉眼核对。")
}