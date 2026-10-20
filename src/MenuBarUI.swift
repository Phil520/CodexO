import Cocoa

// MARK: - 阈值与配色

enum Palette {
    /// 剩余量低于此值开始告警
    static let warningThreshold: Double = 30
    /// 剩余量低于此值进入紧张状态
    static let criticalThreshold: Double = 10

    static func color(forRemaining remaining: Double) -> NSColor {
        if remaining <= criticalThreshold { return .systemRed }
        if remaining <= warningThreshold { return .systemOrange }
        return .systemGreen
    }

    /// 供无障碍描述使用
    static func label(forRemaining remaining: Double) -> String {
        if remaining <= criticalThreshold { return "额度紧张" }
        if remaining <= warningThreshold { return "余量偏低" }
        return "余量充足"
    }

    // MARK: - 内圈月相（每周窗口）
    //
    // 内圈用「月亮的阴晴圆缺」编码每周余量：满月 = 余量充足，弯月 = 快用完了。
    // 换掉原来那套透明度编码有两个实际好处：
    //   1. **不再依赖底色明暗**。透明度编码只在浅色底上成立（越实越显眼），
    //      放到深色菜单栏上方向会反过来，所以过去不得不维护两支深浅不同的紫色。
    //      月相靠形状表达，亮面用一支高饱和度的亮黄，深浅底上都清晰，一支颜色就够。
    //   2. **轮廓恒定**。原来的实心圆越用越淡，最高档和「几乎归零」在缩小后很像；
    //      月相始终是同一颗圆，只是被照亮的部分多寡不同。

    /// 亮面（被照亮的部分）：琥珀 #FFB020。
    /// 在四支候选（暖黄 / 琥珀 / 淡金 / 月白）里选中这一支 —— 深浅两种菜单栏底色下
    /// 都够醒目，橙调比奶白更"有光"，又不像月白那样在浅色底上消失。
    /// 对照图见 `output/preview/moon_color_candidates.png`。
    static let moonColor = NSColor(srgbRed: 1.0, green: 176.0 / 255.0, blue: 32.0 / 255.0, alpha: 1)

    /// 暗面（未被照亮的部分）：中性半透明灰，与外圈底环同一支色。
    /// 留着它，最细的月牙也还挂在一颗完整的圆上，不会变成一根看不出所以然的细线；
    /// 而且这支灰在深浅两种底色下都能看出「这里有个圆」。
    static let moonDarkColor = NSColor(calibratedWhite: 0.5, alpha: 0.38)

    /// 七个可辨识档位对应的余量代表值（%），从新月到满月递增
    ///
    /// ⚠️ 这些数字不是"余量"，而是**月相亮面的目标形状**。
    /// 用户看到的余量数值在图标左侧单独显示，这里的值只决定月亮长什么样。
    /// 所以它们的含义是「phase」，不是「百分比余量」——
    /// 但为了直观沿用 0...100 的写法，与 phase 等价。
    ///
    /// 2026-10-20 调整 [10,30,40,50,60,80,100] → [10,28,40,50,62,76,100]：
    /// 原序列最刺眼的问题是**档6 与档7 几乎画成同一个形状**
    /// （面积 90.45% vs 100%，只差 9.55%），肉眼看不出区别，
    /// 于是"余量 90%" 和 "余量 100%" 在图标上是同一个月亮。
    /// 新序列把最小相邻面积差拉到 13 个百分点。
    static let moonLevelValues: [Double] = [10, 28, 40, 50, 62, 76, 100]

    /// 相邻档位的分界，取中点：20 / 35 / 45 / 55 / 70 / 90
    private static let moonThresholds: [Double] = [20, 35, 45, 55, 70, 90]

    static var moonLevelCount: Int { moonLevelValues.count }

    /// 七档的月相名，与「亮面被照亮的比例」一一对应。
    /// 全部取**上弦（盈）方向**的称谓：亮面在右侧、逐渐变胖，
    /// 与图标里"月亮从右边开始被点亮"的画法一致（北方上弦月正是右边亮）。
    static let moonNames = ["眉月", "蛾眉月", "渐盈月", "上弦月", "渐凸月", "盈凸月", "满月"]

    /// 每周余量 → 1...7 档。余量 0 落在最低档（最细的月牙），而不是不画。
    static func moonLevel(forRemaining remaining: Double) -> Int {
        for (index, threshold) in moonThresholds.enumerated() where remaining < threshold {
            return index + 1
        }
        return moonLevelValues.count
    }

    /// 每周余量 → 月相亮度比例 0...1（0 = 新月全暗，1 = 满月全亮）
    static func moonPhase(forRemaining remaining: Double) -> Double {
        moonLevelValues[moonLevel(forRemaining: remaining) - 1] / 100
    }

    static func moonName(forRemaining remaining: Double) -> String {
        moonNames[moonLevel(forRemaining: remaining) - 1]
    }

    // MARK: - 按档位取值的入口（1...7）
    //
    // 为什么把这两个单独开出来，而不是让调用方自己写
    // `moonLevelValues[level - 1] / 100`：
    // 「档位 → 代表值」这个映射规则只该有一处定义。
    // 测试与目视工具若自己重算一遍，就等于用副本验证副本 ——
    // 一旦两边一起错，判据照样全绿。
    //
    // （2026-10-20 加。起因是排查"月相不准"时需要按档逐个渲染，
    //  结果发现测试里根本没有"按档取值"的入口可用。）

    /// 第几档（1...7）对应的月相亮度比例
    static func moonPhaseForLevel(_ level: Int) -> Double {
        guard level >= 1, level <= moonLevelValues.count else { return 0 }
        return moonLevelValues[level - 1] / 100
    }

    /// 第几档（1...7）对应的月相名
    static func moonNameForLevel(_ level: Int) -> String {
        guard level >= 1, level <= moonNames.count else { return moonNames[0] }
        return moonNames[level - 1]
    }

    /// 第几档（1...7）覆盖的余量区间，用于菜单里说明档位含义。
    /// 返回 (下界, 上界)，上界 100 表示无上界。
    static func moonRangeForLevel(_ level: Int) -> (Double, Double) {
        guard level >= 1, level <= moonLevelValues.count else { return (0, 0) }
        let low = level == 1 ? 0 : moonThresholds[level - 2]
        let high = level < moonThresholds.count ? moonThresholds[level - 1] : 100
        return (low, high)
    }

    /// 明暗交界线的横向半径系数（单位为月相圆半径 r）。
    ///
    /// 天文上准确的算法是 r·cos(π·phase)：满月时交界线退到左边缘（整颗圆都亮），
    /// 半弦月时正好过圆心（一条直线），新月时贴回右边缘（整颗圆都暗）。
    ///
    /// 但物理准确 ≠ 图标可读：phase = 0.1 时天文亮面面积只有 2.45%，
    /// 在 18pt 的菜单栏图标上约等于一根看不见的头发丝。所以给系数加一个上限，
    /// 让最低档也保有一道看得见的月牙 —— 读数工具的第一职责是「能读出来」，
    /// 不是「还原天象」。
    ///
    /// ⚠️ 2026-10-20 从 0.78 放宽到 0.90。
    /// 原来 0.78 是拍脑袋定的，副作用是**最低档被夸大到 4.5 倍**：
    /// 天文该是 2.45% 的细月牙，实际画成 11.00%（面积），
    /// 跟档2（20.61%）的差距被压到 9.6%，两档看着差不多。
    /// 0.90 对应面积 5.00%：18pt@2x 下约 24 像素，仍是清晰的月牙，
    /// 而与档2 的差距拉到 13 个百分点，档位重新分得开。
    ///
    /// 这个上限只影响最低那一档 —— 档2 起cos(π·phase) 都 ≤ 0.588，
    /// 远低于任何合理上限。
    static let moonTerminatorCeiling: Double = 0.90

    static func moonTerminatorRatio(forPhase phase: Double) -> CGFloat {
        let clamped = max(0, min(1, phase))
        let exact = Foundation.cos(.pi * clamped)
        return CGFloat(max(-1, min(moonTerminatorCeiling, exact)))
    }

    /// 一行说明，用于悬浮提示与诊断日志
    static func moonDescription(forRemaining remaining: Double) -> String {
        "\(moonLevel(forRemaining: remaining))/\(moonLevelCount) 档 · \(moonName(forRemaining: remaining))"
    }

    /// 该外观是否属于深色。`NSAppearance` 可能带 VibrantDark / 高对比度等修饰，
    /// 所以用 `bestMatch` 归到 aqua / darkAqua 两支里判断，而不是比字符串。
    ///
    /// 月相配色本身与外观无关，但诊断日志仍要报告当前明暗 ——
    /// 「在浅色底上看不清」这类反馈，只有知道当时是深是暗才查得下去。
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        guard let appearance else { return false }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - 月相绘制

/// 把一档月相画成图形。菜单栏图标内圈与菜单里的图例共用这一份实现，
/// 保证「图上看到的」和「菜单里解释的」永远是同一个形状。
///
/// 画法：一颗完整的暗面圆 + 一块被照亮的区域。亮面由两条边界围成 ——
/// 右半圆（亮的永远是右边，符合「月亮从右边开始被点亮」的直觉）
/// 和一段椭圆弧（明暗交界线）。
enum MoonShape {

    /// phase：0 = 新月（全暗），1 = 满月（全亮）
    static func draw(in context: CGContext,
                     center: CGPoint,
                     radius: CGFloat,
                     phase: Double,
                     light: NSColor = Palette.moonColor,
                     dark: NSColor = Palette.moonDarkColor) {
        guard radius > 0.3 else { return }

        // 暗面：整颗圆
        context.setFillColor(deviceRGB(dark).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))

        guard phase > 0.02 else { return }

        let ratio = Palette.moonTerminatorRatio(forPhase: phase)

        // 整条路径先在 CGMutablePath 上拼好，再一次性交给 context。
        // 这样椭圆弧那段可以用 CGMutablePath.addPath(_:transform:) 压形，
        // 不必依赖「变换时机」这类隐晦行为。
        let lit = CGMutablePath()
        // 亮面外缘：右半圆，上 → 右 → 下
        lit.addArc(center: center, radius: radius,
                   startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)

        if abs(ratio) < 0.005 {
            // 弦月：明暗界线正好穿过圆心，就是一条直线
            lit.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        } else {
            // 明暗界线是一段椭圆弧。CGPath 只能加圆弧、没有椭圆弧，
            // 办法是先在单位圆上造出下半段，再用变换压成 (ratio·r, r) 的椭圆。
            //
            // ⚠️ 顺序必须是「先平移到圆心、再缩放」，不能反过来。
            // CGAffineTransform 的这些方法都是**左乘**：t = t.scaledBy(…) 实际是 t ← t·S，
            // 后面再 t.translatedBy(dx,dy) 得到 (t·S)·T —— 那个平移量会被前面的 S 一起缩放，
            // 于是「平移到 center」变成了「平移到 ratio·r · center」。
            // ratio=0.78、r=100 时，圆心平移量 100 被算成 0.78×100=78、y 方向更被叠成 7800，
            // 整段弧被甩到画布外，closeSubpath 之后形状塌回右半圆 ——
            // **七档画出来全是右半圆，亮面恒为 50%，月相当场失效**。
            //
            // 这个坑的特征是「不报错、只是画错」：半圆本身是合法图形，
            // 不去数像素就发现不了；而肉眼正好最容易漏掉这种「七档一模一样」的情况。
            let unit = CGMutablePath()
            unit.addArc(center: .zero, radius: 1,
                        startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.scaledBy(x: ratio * radius, y: radius)
            lit.addPath(unit, transform: transform)
        }
        lit.closeSubpath()

        context.addPath(lit)
        context.setFillColor(deviceRGB(light).cgColor)
        context.fillPath()
    }

    private static func deviceRGB(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? color
    }
}

// MARK: - 数值格式化

enum Format {

    /// 日期格式化器建一次就够了：DateFormatter 初始化要读 locale/calendar，
    /// 属于重对象，热点路径上每次新建会平白增加分配压力
    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func humanize(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "已重置" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    /// 时长描述，用于「已运行多久」。与 `humanize` 分开：
    /// 后者服务于「距离重置还有多久」，间隔为 0 时会返回「已重置」，
    /// 拿它来描述运行时长就会出现「运行了 0 秒 → 已重置」这种荒唐结果。
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "不到 1 分钟"
    }

    static func resetLine(_ window: UsageWindow, name: String) -> String {
        guard let reset = window.resetAt else {
            return "已用 \(percent(window.used)) · 重置时间未知"
        }
        if window.expired {
            return "窗口已重置 · 待下次消耗后更新"
        }
        if Calendar.current.isDateInToday(reset) {
            return "已用 \(percent(window.used)) · 今日 \(timeOnly.string(from: reset)) 重置，还有 \(humanize(reset.timeIntervalSinceNow))"
        }
        return "已用 \(percent(window.used)) · \(dateTime.string(from: reset)) 重置，还有 \(humanize(reset.timeIntervalSinceNow))"
    }
}

// MARK: - 环形图标

enum IconFactory {

    /// 菜单栏小图标。
    ///
    /// 外圈：5 小时窗口剩余量的进度环，颜色按阈值取绿/橙/红。
    /// 内圈：每周窗口剩余量的月相 —— 满月表示余量充足，弯月表示快用完了。
    ///       调用方把余量按 `Palette.moonPhase(forRemaining:)` 换算成 0...1 的
    ///       亮度比例再传进来，绘制这边保持成一个纯函数（配色规则集中在 Palette）。
    ///
    /// 用 CGContext 直绘并在像素空间里按 scale 放大，避免
    /// NSGraphicsContext(bitmapImageRep:) 自带的点→像素映射造成二次缩放。
    ///
    /// `moonColor` 默认取 `Palette.moonColor`；留这个口子是为了配色候选对照页
    /// 能在同一张图上并排画出四支候选色，平时调用不用传。
    static func icon(fiveHour: Double,
                     fiveHourColor: NSColor,
                     moonPhase: Double?,
                     moonColor: NSColor = Palette.moonColor,
                     size: CGFloat = 18,
                     scale: CGFloat = 2) -> NSImage {

        let pixels = Int(size * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(data: nil,
                                      width: pixels,
                                      height: pixels,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)

        let lineWidth: CGFloat = 2.8
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2 - 0.5

        let clamped = max(0, min(1, fiveHour))

        // 内圈：每周窗口余量，月相
        if let moonPhase {
            let discRadius = radius - lineWidth / 2 - moonGap
            MoonShape.draw(in: context, center: center,
                           radius: discRadius, phase: moonPhase, light: moonColor)
        }

        // 底环：平时用中性灰（明暗菜单栏下都可见）；
        // 剩余归零时环内没有填充，纯灰看着像「没数据」，故整圈染成警示色
        let trackColor = clamped <= 0.002
            ? fiveHourColor.withAlphaComponent(0.55)
            : NSColor(calibratedWhite: 0.5, alpha: 0.4)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(resolved(trackColor))
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()

        // 进度弧：自 12 点方向顺时针填充
        if clamped > 0.002 {
            context.setStrokeColor(resolved(fiveHourColor))
            context.addArc(center: center,
                           radius: radius,
                           startAngle: .pi / 2,
                           endAngle: .pi / 2 - 2 * .pi * clamped,
                           clockwise: true)
            context.strokePath()
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        // size 用点为单位，像素是它的 scale 倍 → Retina 自动按 2x 呈现
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        image.isTemplate = false
        return image
    }

    /// 月相与进度环之间留出的缝隙。太大会让月亮相单薄，太小会跟环糊在一起。
    private static let moonGap: CGFloat = 1.0

    /// 只画外圈（保留给测试与图标预览使用）
    static func ring(progress: Double, color: NSColor, size: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
        icon(fiveHour: progress, fiveHourColor: color, moonPhase: nil, size: size, scale: scale)
    }

    private static func resolved(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.deviceRGB) ?? color).cgColor
    }
}

// MARK: - 进度条

final class BarView: NSView {

    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let height: CGFloat = 7
        let radius = height / 2
        let track = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(1, fraction))
        guard clamped > 0.002 else { return }

        let width = max(height, track.width * clamped)
        let fill = NSRect(x: 0, y: track.minY, width: min(width, track.width), height: height)
        barColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - 下拉菜单里的单个窗口详情块

/// 图例：直接画出当前周余量对应的那一档月相，与菜单栏图标内圈完全一致。
/// 不用 CALayer 画圆 —— 月相是「圆被一条椭圆弧切开」，图层做不了这种路径。
final class MoonView: NSView {

    /// 0 = 新月（全暗），1 = 满月（全亮）
    var phase: Double = 0 { didSet { needsDisplay = true } }

    init(side: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        MoonShape.draw(in: context,
                       center: CGPoint(x: bounds.midX, y: bounds.midY),
                       radius: side / 2,
                       phase: phase)
    }
}

final class UsageItemView: NSView {

    static let width: CGFloat = 320
    private static let height: CGFloat = 62
    private static let padding: CGFloat = 14
    /// 标题左侧给月相图例让出的宽度（图例 14pt + 6pt 间距）
    private static let swatchWidth: CGFloat = 20

    private let title: String
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let bar: BarView
    private let subtitle: NSTextField
    private let moon: MoonView?

    init(title: String, window: UsageWindow?, emptyText: String, swatch: Bool = false) {
        self.title = title

        let contentWidth = Self.width - Self.padding * 2
        var titleWidth = contentWidth - 130

        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: "—")
        bar = BarView(frame: .zero)
        subtitle = NSTextField(labelWithString: emptyText)

        let swatchSide: CGFloat = 14
        let swatchView = swatch ? MoonView(side: swatchSide) : nil
        self.moon = swatchView

        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true

        // 有月相图例时，标题右移让位
        var titleX = Self.padding
        if swatch {
            titleWidth -= Self.swatchWidth
            titleX += Self.swatchWidth
            swatchView?.frame.origin = NSPoint(x: Self.padding,
                                                y: 11 + (16 - swatchSide) / 2)
            if let swatchView { addSubview(swatchView) }
        }

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: titleX, y: 10, width: titleWidth, height: 16)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: Self.width - Self.padding - 130, y: 9, width: 130, height: 17)

        bar.frame = NSRect(x: Self.padding, y: 31, width: contentWidth, height: 9)

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: Self.padding, y: 43, width: contentWidth, height: 14)

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(bar)
        addSubview(subtitle)

        update(window: window, emptyText: emptyText)
    }

    required init?(coder: NSCoder) { nil }

    /// 原地刷新内容。
    ///
    /// 菜单项与视图在启动时只建一次，之后开菜单只改这里的值 ——
    /// 原来每次开菜单都 `removeAllItems()` 再重建视图，会在系统侧留下
    /// 一份份带图层背衬的旧视图（320×62 的点阵在 Retina 下约 300 KB/个），
    /// 长期运行就是内存单调上涨的来源。
    func update(window: UsageWindow?, emptyText: String) {
        let color = window.map { Palette.color(forRemaining: $0.remaining) } ?? .tertiaryLabelColor

        valueLabel.stringValue = window.map { Format.percent($0.remaining) } ?? "—"
        valueLabel.textColor = color

        bar.fraction = CGFloat((window?.remaining ?? 0) / 100)
        bar.barColor = color

        // 无周数据时整颗月亮都不画，而不是只画暗面。
        // 只画暗面等于告诉用户"月亮还在、只是全黑了"，那是"额度用完"的意思，
        // 与"没读到数"是两回事 —— 这里要表达的恰恰是后者。
        if let window {
            moon?.phase = Palette.moonPhase(forRemaining: window.remaining)
            moon?.isHidden = false
        } else {
            moon?.isHidden = true
        }

        subtitle.stringValue = window.map { Format.resetLine($0, name: title) } ?? emptyText
    }
}
