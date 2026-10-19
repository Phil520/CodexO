import Cocoa

/// 开机自启动用的 LaunchAgent 标识
private let launchAgentLabel = "com.bean.codex-usage-menubar"

/// 自动刷新间隔（秒）。
/// 允许用环境变量覆盖，是为了把「跑几天」压缩成「跑几分钟」的真实进程压测：
/// `CODEX_USAGE_REFRESH=0.02` 即每 0.02 秒触发一次，2 分钟≈4 天的触发量。
private let refreshInterval: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_REFRESH"],
       let value = TimeInterval(raw), value > 0 {
        return value
    }
    return 60
}()

/// 内存自检写入间隔（秒）。同样允许环境变量覆盖，便于做加速验证。
private let memoryProbeInterval: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_MEMORY_INTERVAL"],
       let value = TimeInterval(raw), value > 0 {
        return value
    }
    return 1800
}()

/// 菜单里「更新于」用的时间格式
private let menuStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm:ss"
    return formatter
}()

/// 菜单里「读数」用的时间格式（只到分钟，够用且不占地方）
private let readingStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
}()

/// 单实例锁。文件本身当锁用：成功创建 → 是第一个；已存在 → 前面有人。
private let singleInstanceLockURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexO.singleton.lock")

/// 抢单实例锁。返回 false 表示已经有别的 CodexO 在跑。
///
/// 为什么用「创建文件」而不是文件锁（flock）：
/// flock 要先 open 再 flock，还得管 fd 生命周期；这里只需要
/// 「文件在 = 有人」，语义更直白，代价是**进程被强杀后锁文件会留下**。
/// 所以启动时顺手做一次陈旧性检查（下面 `reclaimIfStale`）。
private func acquireSingleInstanceLock() -> Bool {
    let fm = FileManager.default

    // 锁文件是本进程上次留下的 → 清掉重来。
    // 不清的话，用户强杀进程（干净退出走不到这里）之后就再也起不来了，
    // 那比"两个图标"更糟 —— 它会让 App 变成"装了但用不了"。
    if fm.fileExists(atPath: singleInstanceLockURL.path) {
        // 锁文件里写着 pid。进程还在就不是陈旧的，直接判定为"已有实例"。
        if let text = try? String(contentsOf: singleInstanceLockURL, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, kill(pid, 0) == 0 {
            return false
        }
        // pid 不在了（进程已死）→ 锁陈旧，删掉重来
        try? fm.removeItem(at: singleInstanceLockURL)
    }

    guard fm.createFile(atPath: singleInstanceLockURL.path,
                        contents: Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)) else {
        // 建不出来（权限等）就放行：宁可两个图标，也不要让 App 起不来
        return true
    }
    return true
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var snapshot: UsageSnapshot?
    private var timer: Timer?

    // 菜单项与其中的自定义视图只在启动时建一次，之后开菜单只改内容。
    // 原来每次开菜单都 removeAllItems() 再重建视图，等于每开一次就丢下一批
    // 带图层背衬的视图（320×62 在 Retina 下约 300 KB/个）交给系统回收，
    // 长期运行是内存单调上涨的主要嫌疑。
    private var fiveHourView: UsageItemView!
    private var weeklyView: UsageItemView!
    private var updatedNote: NSMenuItem!
    private var sourceNote: NSMenuItem!
    private var loginItem: NSMenuItem!

    /// 上一张图标的渲染输入签名，相同则复用，不重建位图
    private var lastIconSignature: String?
    /// 上一份悬浮提示，相同则不重复赋值
    private var lastTooltip: String?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.markLaunch()

        // 单实例保护：已经有别的 CodexO 在跑就直接退出。
        //
        // 2026-10-19 实测：发布验收时从 /tmp 启动了一个副本、忘了关，
        // 菜单栏于是出现**两个一模一样的图标**。更麻烦的是两个进程写同一份日志，
        // 行与行交错，下次排查时那份日志直接作废。
        //
        // 用户完全可以理解"多开一个"，所以不能指望人人都会先看菜单栏；
        // 也不能指望每个开发者/脚本作者都会记得关进程。
        // **单实例是这个 App 的产品要求，不是可选项** ——
        // 两个图标会让人以为软件不稳定，而两个进程混写日志会让排查失效。
        //
        // 用锁文件而不是 NSApplication 的 canBecomeActive：
        // 后者只在前台 App 之间生效，对 LSUIElement 这类后台 App 无效。
        if !acquireSingleInstanceLock() {
            Diagnostics.appendRaw("[\(Diagnostics.logStamp)] 检测到已有实例在跑，本次启动放弃\n")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 数值在左、图标在右。菜单栏控件从左往右排，靠右的位置更容易被别的图标挤掉，
            // 把读数放在最左侧可以保证它始终第一个被看到。
            button.imagePosition = .imageTrailing
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.setAccessibilityLabel("Codex 用量")
        }

        buildMenuOnce()
        reload()

        let ticker = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            // 显式收池：每分钟触发一次、且内部会产出大量临时对象
            autoreleasepool {
                self?.reload()
                if Soak.forceIconOnTick { Soak.forcedIconRender() }
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker

        // 低频内存自检：长期跑下来这份记录就是「有没有涨」的直接证据
        let memoryTimer = Timer(timeInterval: memoryProbeInterval, repeats: true) { _ in
            autoreleasepool { Diagnostics.recordMemory(tag: "定期") }
        }
        RunLoop.main.add(memoryTimer, forMode: .common)

        Diagnostics.recordMemory(tag: "启动")

        // 系统在浅色/深色之间切换时立刻重画图标。
        // 月相配色本身与外观无关（一支亮黄，深浅底上都清晰），但切换外观后
        // 菜单栏底色变了、图标却还是上一副模样，观感上会像是"没跟上"。
        // 重画成本极低，这里等 0.3 秒再画，避开外观还没落定的瞬间。
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.reload(forceIcon: true)
            }
        }

        // 内存压测（仅当设置了 CODEX_USAGE_SOAK 时执行）
        if Soak.isRequested {
            Soak.run(timerCycle: { [weak self] in self?.reload() },
                     iconCycle: { Soak.forcedIconRender() },
                     menuCycle: { [weak self] in
                         guard let self else { return }
                         autoreleasepool { self.refreshMenuContents() }
                     },
                     legacyCycle: { Soak.legacyMenuRebuild() })
        }

        // 启动后写两份诊断快照，用于确认图标是否真的落到了菜单栏上；
        // 期间走一遍真实的菜单更新路径，便于确认「点开有没有内容」
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.menuNeedsUpdate(self.menu)
                Diagnostics.record(statusItem: self.statusItem, snapshot: self.snapshot, menu: self.menu)
            }
        }
    }

    // MARK: - 取数并更新状态栏

    private func reload(forceIcon: Bool = false) {
        autoreleasepool { performReload(forceIcon: forceIcon) }
    }

    /// 菜单栏当前的外观。按钮取不到时退回 NSApp 的外观，避免出现"判定为浅色但其实是深色"。
    private var menuBarAppearance: NSAppearance? {
        statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
    }

    private func performReload(forceIcon: Bool) {
        let started = Date()
        let current = UsageReader.load()
        let elapsed = Date().timeIntervalSince(started)
        snapshot = current

        guard let button = statusItem.button else {
            // 按钮都没了，还谈什么刷新。单独记一行，别混进正常的刷新日志里，
            // 否则看日志的人会以为"循环在跑，只是读数没变"。
            Diagnostics.appendRaw("[\(Diagnostics.logStamp)] 刷新 #\(Diagnostics.refreshIndex) 异常：statusItem.button 为 nil，本次数值未上界面\n")
            return
        }

        // 图标只在「渲染输入确实变了」时重建。数值持平时（例如 Codex 没在跑）
        // 复用上一张图，省掉每次新建 CGContext + 位图 + NSImage 的分配。
        let appearance = menuBarAppearance
        let signature = current.fiveHour.map { five in
            "\(Palette.isDark(appearance) ? "D" : "L")|\(Int(five.remaining.rounded()))"
                + "|\(current.weekly.map { Int($0.remaining.rounded()) } ?? -1)"
        } ?? "none"

        if forceIcon { lastIconSignature = nil }

        if signature != lastIconSignature {
            if let five = current.fiveHour {
                let remaining = five.remaining
                button.image = IconFactory.icon(fiveHour: remaining / 100,
                                                fiveHourColor: Palette.color(forRemaining: remaining),
                                                moonPhase: current.weekly.map {
                                                    Palette.moonPhase(forRemaining: $0.remaining)
                                                })
                button.title = Format.percent(remaining) + " "
            } else {
                button.image = IconFactory.ring(progress: 0, color: .tertiaryLabelColor)
                button.title = "-- "
            }
            lastIconSignature = signature
        }

        // 关键：自检必须放在**真的写完 button.title 之后**。
        // 记的是界面上实际显示的那串字，而不是内部算出来的数——
        // 「算对了但没推到界面上」和「算错了」在屏幕上的表现完全一样，
        // 只有把界面值一起记下来，日志才能把这两种故障分开。
        Diagnostics.recordRefresh(snapshot: current, elapsed: elapsed, shown: button.title)

        let tip = tooltip(for: current)
        if tip != lastTooltip {
            button.toolTip = tip
            button.setAccessibilityHelp(tip)
            lastTooltip = tip
        }
    }

    private func tooltip(for current: UsageSnapshot) -> String {
        guard current.hasData else { return "Codex 用量\n\(current.unavailableReason)" }

        var lines: [String] = []
        if let five = current.fiveHour {
            lines.append("5 小时窗口：剩 \(Format.percent(five.remaining))（已用 \(Format.percent(five.used))）")
            lines.append("　\(Format.resetLine(five, name: "5 小时窗口"))")
        }
        if let week = current.weekly {
            lines.append("每周窗口：剩 \(Format.percent(week.remaining))（已用 \(Format.percent(week.used))）")
            lines.append("　\(Format.resetLine(week, name: "每周窗口"))")
            lines.append("　内圈月相：\(Palette.moonDescription(forRemaining: week.remaining))，月亮越圆余量越多")
        }
        if let file = current.sourceFile {
            lines.append("来源：\(file)")
        }
        if let record = current.recordTime {
            lines.append("数据记录于：\(readingStamp.string(from: record))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 下拉菜单

    /// 菜单只在启动时建一次，之后靠 `refreshMenuContents()` 原地更新
    private func buildMenuOnce() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Codex 用量余量", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        fiveHourView = UsageItemView(title: "5 小时窗口", window: nil, emptyText: "—")
        menu.addItem(viewItem(fiveHourView))

        weeklyView = UsageItemView(title: "每周窗口", window: nil, emptyText: "—", swatch: true)
        menu.addItem(viewItem(weeklyView))

        menu.addItem(.separator())

        updatedNote = makeNote()
        menu.addItem(updatedNote)
        sourceNote = makeNote()
        menu.addItem(sourceNote)

        menu.addItem(.separator())

        menu.addItem(actionItem("立即刷新", #selector(doRefresh)))
        menu.addItem(actionItem("打开 Codex 会话目录", #selector(openSessions)))
        menu.addItem(actionItem("写入诊断日志", #selector(writeDiagnostics)))

        loginItem = actionItem("开机自动启动", #selector(toggleLogin))
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(actionItem("退出", #selector(quit)))

        statusItem.menu = menu
        self.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        autoreleasepool {
            reload()
            refreshMenuContents()
        }
    }

    /// 只更新内容，不动结构
    private func refreshMenuContents() {
        guard let fiveHourView, let weeklyView else { return }

        let current = snapshot
        let empty = current?.unavailableReason ?? "暂无数据"

        fiveHourView.update(window: current?.fiveHour, emptyText: empty)
        weeklyView.update(window: current?.weekly, emptyText: empty)

        if let current {
            let updated = "更新于 \(menuStamp.string(from: current.loadedAt))"
                + " · 内存 \(Memory.human(Memory.footprint()))"
                + " · 运行 \(Format.duration(Diagnostics.uptime))"
            setNote(updatedNote, updated)

            // 读数时间单独显示：它才是「这个数有多新」的答案。
            // 显示的是日志里那条记录自身的时间，不是我们读它的时间；
            // 后面再补一个相对时间，一眼能判断是「数据陈旧」还是「工具算错」——
            // 这两种情况在界面上长得一模一样，只有时间能区分。
            let reading = current.recordTime.map { readingStamp.string(from: $0) } ?? "—"
            let age = current.recordTime.map { Format.duration(Date().timeIntervalSince($0)) }
            let ageText = age.map { "（\($0)前）" } ?? ""
            let source = current.sourceFile.map { String($0.prefix(22)) } ?? "—"
            setNote(sourceNote, "读数 \(reading)\(ageText) · 来自 \(source)")
        } else {
            setNote(updatedNote, "更新于 —")
            setNote(sourceNote, "读数 —")
        }

        loginItem.state = isLoginEnabled ? .on : .off
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func makeNote() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func setNote(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 菜单动作

    @objc private func doRefresh() {
        // 必须先丢缓存再取数。缓存 key 只看「mtime 最新那个文件」，
        // 而 Codex 刚新建会话时那个文件还没写出第一条额度数据，
        // key 与上次相同 → 缓存命中 → 拿两天前的读数糊弄用户。
        // 手动点刷新是用户在说「我怀疑你错了，去看看」，不能被缓存拦下。
        UsageReader.invalidateCache()
        reload()
        // 点完之后菜单是收起的，用户看不到界面变了，得在日志里明确留痕。
        // 不留痕的话，用户只会盯着那个"没动"的数字，以为他点的刷新没用。
        Diagnostics.appendRaw("[\(Diagnostics.logStamp)] 手动刷新已执行（已清缓存）\n")
    }

    @objc private func openSessions() {
        let url = URL(fileURLWithPath: UsageReader.sessionRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func writeDiagnostics() {
        Diagnostics.record(statusItem: statusItem, snapshot: snapshot, menu: menu)
        NSWorkspace.shared.selectFile(Diagnostics.logPath,
                                      inFileViewerRootedAtPath: (Diagnostics.logPath as NSString).deletingLastPathComponent)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// 正常退出时清掉单实例锁。
    /// 强杀（pkill / 崩溃）走不到这里，但 `acquireSingleInstanceLock()`
    /// 里那条「锁文件里的 pid 还活着吗」能兜住那种情况，不会把 App 卡死。
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: singleInstanceLockURL)
    }

    // MARK: - 开机自启动

    private var launchAgentPath: String {
        ("~/Library/LaunchAgents/\(launchAgentLabel).plist" as NSString).expandingTildeInPath
    }

    private var isLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func toggleLogin() {
        if isLoginEnabled {
            runLaunchctl(["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            guard let executable = Bundle.main.executablePath else { return }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>\(launchAgentLabel)</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(executable)</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
              <key>ProcessType</key>
              <string>Interactive</string>
            </dict>
            </plist>
            """
            let directory = (launchAgentPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            do {
                try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
                runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentPath])
            } catch {
                NSLog("写入 LaunchAgent 失败：\(error)")
            }
        }
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
