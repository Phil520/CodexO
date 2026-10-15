import Cocoa

/// 把菜单栏图标的真实落位情况写进日志，用于排查「进程在跑但看不到图标」
enum Diagnostics {

    static let logPath = ("~/Library/Logs/CodexUsageMenuBar.log" as NSString).expandingTildeInPath

    /// 日志超过这个大小就滚动一次，避免常年运行把日志撑到几十 MB
    private static let maxLogBytes: UInt64 = 512 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 把下拉菜单的实际结构写出来，用于确认「点开有没有内容」
    static func describe(menu: NSMenu?) -> [String] {
        guard let menu else { return ["菜单  : nil ← 异常"] }
        var lines: [String] = []
        lines.append("菜单项数: \(menu.numberOfItems)")
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                lines.append("  [\(index)] 分隔线")
                continue
            }
            let viewInfo: String
            if let view = item.view {
                viewInfo = "自定义视图 \(Int(view.frame.width))×\(Int(view.frame.height))，子视图 \(view.subviews.count) 个"
            } else {
                viewInfo = "系统默认"
            }
            lines.append("  [\(index)] 标题=「\(item.title)」 启用=\(item.isEnabled) \(viewInfo)")
        }
        return lines
    }

    /// 只记一行内存，用于长期观察「跑几天会不会涨」
    static func recordMemory(tag: String) {
        appendRaw("[\(stamp.string(from: Date()))] 内存 \(tag)：\(Memory.summary())\n")
    }

    // MARK: - 刷新循环自检

    // 背景：2026-10-15 出过一次「数字卡在三个小时前不动」的故障。
    // 当时的日志只在启动时记一次读数，**运行时到底刷新了没有完全看不出来**，
    // 于是排查时无法区分「算错了」和「根本没更新」——两种情况的界面表现一模一样。
    // 凡是界面上会变的数字，它的变化过程就必须留下痕迹。
    private static var lastFingerprint: String?
    private static var refreshCount = 0
    private static var lastBeatAt = Date.distantPast

    /// 供调用方在自检之外自己打异常行时对齐序号与时间戳，
    /// 免得出现「刷新 #41」之后又冒出「刷新 #40」这种看起来错乱的日志。
    static var refreshIndex: Int { refreshCount + 1 }
    static var logStamp: String { stamp.string(from: Date()) }

    /// 心跳间隔（秒）。读数没变时也定期记一行，用来证明循环还活着。
    private static let beatInterval: TimeInterval = 15 * 60

    /// 每次定时刷新记一行。读数变了就记；没变也每 15 分钟记一次心跳。
    ///
    /// `shown` 是**实际写到状态栏按钮上的文字**。记它是为了区分两个完全不同的故障：
    /// 取数算错了（`5H` 不对）与取数对了但没推到界面上（`shown` 不跟着变）——
    /// 这两者在屏幕上的表现一模一样，光看读数是分不出来的。
    static func recordRefresh(snapshot: UsageSnapshot, elapsed: TimeInterval, shown: String) {
        refreshCount += 1

        let five = snapshot.fiveHour.map { Int($0.remaining.rounded()) } ?? -1
        let week = snapshot.weekly.map { Int($0.remaining.rounded()) } ?? -1
        let record = snapshot.recordTime.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let fingerprint = "\(record)|\(snapshot.sourceFile ?? "-")|\(five)|\(week)|\(shown)"

        let now = Date()
        let changed = fingerprint != lastFingerprint
        guard changed || now.timeIntervalSince(lastBeatAt) >= beatInterval else { return }

        let recordText = snapshot.recordTime.map { stamp.string(from: $0) } ?? "—"
        let age = snapshot.recordTime.map { Format.duration(now.timeIntervalSince($0)) } ?? "—"
        let source = snapshot.sourceFile.map { String($0.prefix(26)) } ?? "—"

        appendRaw(String(format: "[%@] 刷新 #%d %@ 5H=%@ W=%@ 界面=%@ 读数=%@（%@前）取数=%.3fs 来源=%@\n",
                         stamp.string(from: now),
                         refreshCount,
                         changed ? "变化" : "心跳",
                         five < 0 ? "无" : "\(five)%",
                         week < 0 ? "无" : "\(week)%",
                         shown,
                         recordText,
                         age,
                         elapsed,
                         source))

        lastFingerprint = fingerprint
        lastBeatAt = now
    }

    static func record(statusItem: NSStatusItem?, snapshot: UsageSnapshot?, menu: NSMenu? = nil) {
        var lines: [String] = []

        lines.append("──── 诊断 \(stamp.string(from: Date())) ────")
        lines.append("app        : \(Bundle.main.bundlePath)")
        lines.append("pid        : \(ProcessInfo.processInfo.processIdentifier)")
        lines.append("策略       : \(NSApp.activationPolicy().rawValue)（0=regular, 1=accessory, 2=prohibited）")
        lines.append("菜单栏厚度 : \(NSStatusBar.system.thickness)")
        lines.append("内存       : \(Memory.summary())")
        lines.append("运行时长   : \(uptimeText())")
        // 内圈月相的实际生效配置 + 当前档位。
        // 配色不再随外观变化，但「当时是深是暗」仍要记 —— 用户反馈"看不清"时，
        // 不知道底色就没法判断是配色问题还是尺寸问题。
        lines.append("外观       : \(appearanceText(statusItem))")
        lines.append("内圈月相   : \(moonColorText())")

        if let item = statusItem {
            lines.append("statusItem : 已创建")
            lines.append("  条目长度   : \(item.length)（-1 表示自适应）")
            lines.append("  isVisible  : \(item.isVisible)")

            if let button = item.button {
                lines.append("  button     : 存在")
                lines.append("    title      : 「\(button.title)」")
                lines.append("    isHidden   : \(button.isHidden)")
                lines.append("    alpha      : \(button.alphaValue)")
                lines.append("    frame      : \(button.frame)")
                lines.append("    image      : \(button.image.map { "\($0.size)" } ?? "nil")")
                lines.append("    所在窗口   : \(button.window == nil ? "nil（未挂到菜单栏！）" : "存在")")
                if let window = button.window {
                    lines.append("    窗口可见   : \(window.isVisible)")
                    lines.append("    窗口层级   : \(window.level.rawValue)")
                    // window.frame 本身已是屏幕坐标，不要再 convertToScreen，否则会被重复位移
                    lines.append("    窗口 frame : \(window.frame)")
                    lines.append("    窗口所在屏 : \(window.screen.map { "\($0.frame)" } ?? "nil")")
                }
            } else {
                lines.append("  button     : nil ← 异常")
            }
        } else {
            lines.append("statusItem : nil ← 异常")
        }

        // 用系统窗口列表交叉验证：本进程的窗口到底有没有真的在屏幕上
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let mine = windowList.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
            }
            lines.append("系统窗口列表中的本进程窗口数: \(mine.count)")
            for entry in mine {
                let layer = entry[kCGWindowLayer as String] ?? "?"
                let bounds = entry[kCGWindowBounds as String] ?? "?"
                lines.append("    layer=\(layer) bounds=\(bounds)")
            }
        } else {
            lines.append("系统窗口列表: 读取失败")
        }

        if menu != nil {
            lines.append(contentsOf: describe(menu: menu))
        }

        lines.append("屏幕数     : \(NSScreen.screens.count)")
        for (index, screen) in NSScreen.screens.enumerated() {
            lines.append("  屏 \(index): frame=\(screen.frame)")
            lines.append("          visibleFrame=\(screen.visibleFrame)")
            lines.append("          safeAreaInsets=\(screen.safeAreaInsets)")
            lines.append("          本地化名称=\(screen.localizedName)")
        }

        if let snapshot {
            lines.append("数据       : 5H=\(snapshot.fiveHour.map { Format.percent($0.remaining) } ?? "无")  W=\(snapshot.weekly.map { Format.percent($0.remaining) } ?? "无")")
            if let week = snapshot.weekly {
                lines.append("当前月相   : \(Palette.moonDescription(forRemaining: week.remaining))")
            }
            lines.append("来源       : \(snapshot.sourceFile ?? "—")")
            if let error = snapshot.error { lines.append("取数错误   : \(error)") }
        }

        lines.append("")
        append(lines.joined(separator: "\n") + "\n")
    }

    private static func append(_ text: String) {
        rotateIfNeeded()
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 供压测等模块直接落盘用
    static func appendRaw(_ text: String) {
        append(text)
    }

    /// 超过上限就滚成 .1（覆盖上一份），保证日志不会无限长大
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: logPath),
              let size = attributes[.size] as? UInt64,
              size > maxLogBytes else { return }

        let backup = logPath + ".1"
        try? fm.removeItem(atPath: backup)
        try? fm.moveItem(atPath: logPath, toPath: backup)
    }

    /// 进程启动时刻。
    ///
    /// 这里必须是**显式赋值**（在 `applicationDidFinishLaunching` 开头调用 `markLaunch()`），
    /// 不能写成 `static let launchedAt = Date()` —— Swift 的静态属性是懒加载，
    /// 第一次被读到时才初始化，于是「运行时长」会从第一次读取那一刻开始算。
    /// 本项目就踩过这个坑：菜单里显示「运行 已重置」。
    private static var launchedAt = Date()

    static func markLaunch() {
        launchedAt = Date()
    }

    /// 进程已运行秒数
    static var uptime: TimeInterval {
        max(0, Date().timeIntervalSince(launchedAt))
    }

    /// 进程已运行多久
    private static func uptimeText() -> String {
        Format.duration(uptime)
    }

    /// 菜单栏按钮实际使用的明暗外观。同时列出 NSApp 与按钮两个来源。
    ///
    /// 注意比较的是**归类后的明/暗**，不是外观名的字符串 ——
    /// NSApp 通常报 `NSAppearanceNameAqua`，而按钮报 `NSAppearanceNameVibrantLight`，
    /// 名字不同但同属浅色。比字符串会天天误报"不一致"。
    private static func appearanceText(_ statusItem: NSStatusItem?) -> String {
        let appAppearance = NSApp.effectiveAppearance
        let appDark = Palette.isDark(appAppearance)

        guard let buttonAppearance = statusItem?.button?.effectiveAppearance else {
            return "\(describe(appDark)) · NSApp=\(appAppearance.name.rawValue) · button=nil"
        }

        let buttonDark = Palette.isDark(buttonAppearance)
        let consistent = buttonDark == appDark
        return "\(describe(appDark)) · NSApp=\(appAppearance.name.rawValue)"
            + " · button=\(buttonAppearance.name.rawValue)"
            + (consistent ? "" : " ← 两者明暗判定不一致")
    }

    private static func describe(_ isDark: Bool) -> String {
        isDark ? "深色（darkAqua）" : "浅色（aqua）"
    }

    /// 当前实际生效的内圈月相配置
    private static func moonColorText() -> String {
        guard let rgb = Palette.moonColor.usingColorSpace(.deviceRGB) else { return "解析失败" }
        let hex = String(format: "#%02X%02X%02X",
                         Int((rgb.redComponent * 255).rounded()),
                         Int((rgb.greenComponent * 255).rounded()),
                         Int((rgb.blueComponent * 255).rounded()))
        return "\(hex) 亮面 · 暗面中性灰 50% α38%（深浅外观通用）"
    }
}
