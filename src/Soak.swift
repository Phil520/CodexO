import Cocoa

// MARK: - 进程内存探针

/// 读取当前进程的真实内存占用。
///
/// 两个口径都给：`footprint` 是「活动监视器」内存列显示的值（含压缩后的页），
/// `resident` 是 RSS。长期驻留类应用关心的是这两个数会不会**随时间单调上升**。
enum Memory {

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func resident() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func human(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        if mb >= 10 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f MB", mb)
    }

    /// 一行摘要，用于菜单与诊断日志
    static func summary() -> String {
        "物理 \(human(footprint())) · 常驻 \(human(resident()))"
    }
}

// MARK: - 内存压测

/// 把「定时刷新」和「构建菜单」这两条真实路径跑成千上万遍，每若干遍采一次内存。
///
/// 用途：常驻类应用最怕「跑几天内存涨上去」，但不可能真的等几天。
/// 把一次刷新／一次开菜单压成一次循环后，几十秒就能跑完相当于几个月的调用量，
/// 内存曲线是否单调上升一眼可见。
///
/// 打开方式（环境变量）：
///   CODEX_USAGE_SOAK=3000              迭代次数，不设则不跑压测
///   CODEX_USAGE_SOAK_MODE=timer|icon|menu|menu-rebuild|all
///   CODEX_USAGE_SOAK_POOL=0            关闭「每轮一个自动释放池」，用于区分
///                                      「真泄漏」与「自动释放对象没被回收」
///
/// `menu-rebuild` 复刻的是**改造前**的写法（每次 removeAllItems 再重建自定义视图），
/// 保留它是为了拿它和改造后的 `menu` 做对照 —— 增长量差多少，一眼可见。
enum Soak {

    private static let sampleEvery = 250
    private static let warmup = 200

    /// 每轮循环是否包在自动释放池里。默认开启：真实 App 跑在主 RunLoop 上，
    /// 每次定时器触发、每次菜单更新都由系统在事件循环里收池，这才是对得上的模型。
    private static var pooled: Bool {
        ProcessInfo.processInfo.environment["CODEX_USAGE_SOAK_POOL"] != "0"
    }

    private static var requestedIterations: Int {
        guard let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_SOAK"] else { return 0 }
        return Int(raw) ?? 0
    }

    private static var requestedModes: [String] {
        let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_SOAK_MODE"] ?? "all"
        if raw == "all" { return ["timer", "icon", "menu", "menu-rebuild"] }
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static var isRequested: Bool { requestedIterations > 0 }

    /// - Parameters:
    ///   - timerCycle: 模拟一次定时刷新（取数 + 更新图标）
    ///   - iconCycle: 模拟一次「数值变化导致图标必须重画」（最坏情况）
    ///   - menuCycle: 模拟一次「打开菜单」（走当前实现）
    ///   - legacyCycle: 模拟一次「打开菜单」（走改造前的重建写法，仅用于对照）
    static func run(timerCycle: @escaping () -> Void,
                    iconCycle: @escaping () -> Void,
                    menuCycle: @escaping () -> Void,
                    legacyCycle: @escaping () -> Void) {
        guard isRequested else { return }

        let iterations = requestedIterations
        let modes = requestedModes

        var report: [String] = []
        report.append("════ 内存压测 ════")
        report.append("迭代 \(iterations) 次／模式 \(modes.joined(separator: ", "))／预热 \(warmup) 次")
        report.append("每轮循环\(pooled ? "包在自动释放池内（与真实 App 一致）" : "不收池（用于分离自动释放对象的影响）")")

        func step(_ body: () -> Void) {
            if pooled { autoreleasepool { body() } } else { body() }
        }

        for mode in modes {
            let cycle: () -> Void
            switch mode {
            case "timer":        cycle = timerCycle
            case "icon":         cycle = iconCycle
            case "menu":         cycle = menuCycle
            case "menu-rebuild": cycle = legacyCycle
            default:             continue
            }

            for _ in 0..<warmup { step(cycle) }

            let startFootprint = Memory.footprint()
            let startResident = Memory.resident()
            report.append("")
            report.append("— 模式 \(mode) —")
            report.append("  预热后基线：物理 \(Memory.human(startFootprint)) · 常驻 \(Memory.human(startResident))")

            var samples: [(Int, UInt64, UInt64)] = []
            for index in 1...iterations {
                step(cycle)
                if index % sampleEvery == 0 {
                    let footprint = Memory.footprint()
                    let resident = Memory.resident()
                    samples.append((index, footprint, resident))
                    report.append("  \(String(format: "%6d", index)) 次：物理 \(Memory.human(footprint)) · 常驻 \(Memory.human(resident))")
                }
            }

            guard let last = samples.last else { continue }
            let deltaFootprint = Int64(last.1) - Int64(startFootprint)
            let deltaResident = Int64(last.2) - Int64(startResident)
            report.append("  净变化：物理 \(signed(deltaFootprint)) · 常驻 \(signed(deltaResident))")

            // 按「每 60 秒触发一次」外推成每天的增长量
            if deltaFootprint <= 0 {
                report.append("  外推：无增长（无泄漏迹象）")
            } else {
                let perCycle = Double(deltaFootprint) / Double(iterations)
                let perDay = perCycle * Double(86_400 / 60)
                report.append("  外推：\(String(format: "%.1f", perCycle)) 字节/次 → "
                              + "\(Memory.human(UInt64(perDay)))／天 → "
                              + "\(Memory.human(UInt64(perDay * 30)))／30 天")
            }
        }

        report.append("")
        report.append("════ 压测结束 ════")

        let text = report.joined(separator: "\n")
        print(text)
        Diagnostics.appendRaw(text + "\n")

        // 便于脚本化调用：压测跑完直接退出，不用外部 kill
        if ProcessInfo.processInfo.environment["CODEX_USAGE_SOAK_EXIT"] != nil {
            exit(0)
        }
    }

    private static func signed(_ value: Int64) -> String {
        let magnitude = Memory.human(UInt64(abs(value)))
        if value > 0 { return "+\(magnitude)" }
        if value < 0 { return "-\(magnitude)" }
        return "±0 B"
    }

    // MARK: - 改造前写法的复刻（仅用于对照）

    /// 每次「开菜单」都 `removeAllItems()` 再重建两个自定义视图 —— 即改造前的写法。
    /// 用一个独立的临时菜单，避免污染真实菜单。
    private static let legacyMenu = NSMenu()

    static func legacyMenuRebuild() {
        legacyMenu.removeAllItems()

        let first = NSMenuItem()
        first.view = UsageItemView(title: "5 小时窗口", window: nil, emptyText: "—")
        legacyMenu.addItem(first)

        let second = NSMenuItem()
        second.view = UsageItemView(title: "每周窗口", window: nil, emptyText: "—", swatch: true)
        legacyMenu.addItem(second)
    }

    // MARK: - 强制重画图标

    /// 便捷开关：让每次定时回调都强制重画一次图标，
    /// 用于「真实 RunLoop 下加速跑」的场景（配合 CODEX_USAGE_REFRESH）
    static var forceIconOnTick: Bool {
        ProcessInfo.processInfo.environment["CODEX_USAGE_SOAK_FORCE_ICON"] != nil
    }

    /// 最坏情况：数值每次都在变，图标必须重新出图。
    /// 用来确认「每 60 秒重建一次 NSImage」本身不会累积。
    private static var iconTick = 0

    static func forcedIconRender() {
        iconTick = (iconTick + 7) % 100
        let remaining = Double(iconTick)
        _ = IconFactory.icon(fiveHour: remaining / 100,
                             fiveHourColor: Palette.color(forRemaining: remaining),
                             moonPhase: Palette.moonPhase(forRemaining: Double((iconTick * 3) % 100)))
    }
}
