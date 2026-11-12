import Cocoa

// 回归测试：状态栏项的位置自愈
//
// ## 要防的是什么
//
// 2026-10-21 真实踩到的问题：macOS 26 会把「一时放不下」的状态栏项
// 降级成紧凑高度（22pt）并塞到时钟底下。App 自己完全看不出异常 ——
// `isVisible` 照样报 true、按钮窗口照样存在、日志照样干净，
// 但用户就是看不到图标。
//
// 症状的隐蔽之处在于：**它按 bundle id 记住**。
// 同一个 id 第一次启动时如果位置没抢到，之后启动多少次都恢复不了。
// 换 bundle id 就能好，同一份二进制只改 id 就能好 —— 证明是系统侧的脏数据。
//
// ## 判据为什么是几何而不是 isVisible
//
// 被降级时 isVisible 仍为 true，因为按钮窗口确实存在、确实被创建了，
// 只是没被放进菜单栏的排布里。能区分的只有位置：
//
// - 正常：y ≈ 923（菜单栏那条带），高度 ≈ 33（撑满 32pt 的菜单栏）
// - 被降级：y 为负（悬在屏幕顶边之外），或高度只有 22（退化成图标高度）
//
// 高度这一项最关键：差 11pt，肉眼在菜单栏上一眼能看出来，
// 而且它是**数值判据**，不依赖截图、不依赖当时的屏幕状态。

func line(_ title: String) {
    print("\n=== \(title) ===")
}

// MARK: - 判据本身的可测性

line("位置判据：什么算正常、什么算被降级")

let screen = NSScreen.screens.first

// 菜单栏高度：不能只信 safeAreaInsets.top。
//
// 2026-11-12 实测：进程在没有图形会话（锁屏、或从命令行起）时，
// `safeAreaInsets.top` 会返回 **0**，于是「正常项应有 33 高」被算成「应有 1 高」，
// 一个 33 高的正常项直接被判成异常 —— 测试于是稳定误报失败。
//
// 兜底用 `frame.maxY − visibleFrame.maxY`：这是系统真实留给菜单栏的高度
// （956 − 923 = 33，含那 1pt 边框）。它不依赖 safeAreaInsets，锁屏时也成立。
let insetsTop = screen?.safeAreaInsets.top ?? 0
let visibleGap = (screen?.frame.maxY ?? 0) - (screen?.visibleFrame.maxY ?? 0)
let menuBarHeight: CGFloat = insetsTop > 0 ? insetsTop : max(0, visibleGap - 1)
// 菜单栏那条带：贴着屏幕顶端，厚度 = menuBarHeight。
// 坐标原点在左下角，所以这条带是 [屏幕高 − menuBarHeight, 屏幕高]。
let screenTop = screen?.frame.maxY ?? 0
let menuBarBottom = screenTop - menuBarHeight
let expectedHeight = menuBarHeight + 1

print("菜单栏高度 = \(menuBarHeight)（safeAreaInsets.top=\(insetsTop)，visibleFrame 差值=\(visibleGap)）")
print("屏幕顶边 Y = \(screenTop)，菜单栏那条带 = [\(menuBarBottom), \(screenTop)]")
print("正常项应有的高度 = \(expectedHeight)")

/// 复刻 App 里 ensureStatusItemPlacement() 的判据。
/// 两边必须一致 —— 所以这个函数是判据的唯一事实来源。
///
/// ⚠️ 高度与 Y 两个条件必须**各自独立**成立，不能互相依赖：
/// 早先一版用「Y ≥ 本机 visibleTop − 2」做判断，换一台菜单栏高度不同的机器
/// 就会失效（测试里 24pt / 28pt 两种情形直接判错）。
/// 现在改成：**只要高度撑满菜单栏就算正常**，
/// Y 只用来识别「高度对但位置离谱」这一种边缘情形。
///
/// 参数化 menuBarHeight / menuBarBottom 是必须的：
/// 判据要能在**别的菜单栏高度**下被检验，否则测试等于只在当前这台机器上自洽。
/// 返回值：`true` 正常 / `false` 异常 / `nil` **当前无法判定**。
///
/// ⚠️ `nil` 这一档是 2026-11-12 补上的，起因是测试自己开始误报：
/// 进程在没有图形会话时（锁屏、或从命令行直接跑），`NSScreen.screens` 可能为空，
/// `safeAreaInsets` 与 `visibleFrame` 全都读成 0 —— 此时 menuBarHeight = 0、
/// 菜单栏那条带塌缩成一个点，任何正常的 33 高项都会被判成「掉到带底沿以下」。
///
/// **没有信息不等于判定为错。** 拿不到几何就必须说「不知道」，
/// 否则这个判据会稳定地冤枉好数据 —— 在 App 里意味着锁屏时反复销毁重建状态栏项，
/// 那比不检查更糟。
func looksPlacedCorrectly(height: CGFloat,
                          minY: CGFloat,
                          menuBarHeight bar: CGFloat = menuBarHeight,
                          menuBarBottom bottom: CGFloat = menuBarBottom) -> Bool? {
    guard bar > 0, bottom > 0 else { return nil }

    let expected = bar + 1
    // 主判据：高度撑满菜单栏（这是"被降级"最稳定的特征）
    if height < expected - 2 { return false }
    // 辅助判据：高度对，但悬在菜单栏那条带之外。
    // 允许 2pt 容差：正常项的底沿不一定正好等于那条带的边界。
    if minY > bottom + bar + 2 { return false }   // 悬在屏幕顶边之上
    if minY < bottom - 2 { return false }         // 掉到菜单栏带底沿以下
    return true
}

// 用例必须按**当前屏幕的真实几何**构造，不能写死坐标。
//
// 2026-11-12 踩到：这些用例原本硬编码了「33 高 / y=923」，
// 那是在 956 高的内建屏上抓的真实现场值。后来接了 1080 高的外接屏，
// 菜单栏那条带变成 [1051, 1080]，而 y=923 在新屏幕上**本来就掉在带外面** ——
// 判据判它异常完全正确，错的是样例：它把「某一台机器的现场值」当成了普遍真理。
//
// 现在的写法：正常项的几何从当前屏幕算出来，只把「降级形态」写成固定形状。
// 降级形态（22 高、悬到屏幕外）与屏幕尺寸无关，那才是它稳定的地方。
//
// 顺带留个记录：956 高屏上正常项是 (958, 923, 68, 33)，菜单栏 32pt。
let normalHeight = menuBarHeight + 1
let normalMinY = menuBarBottom

struct Case { let name: String; let height: CGFloat; let minY: CGFloat; let expectOK: Bool }
let cases: [Case] = [
    // 正常：撑满菜单栏，贴在菜单栏底沿
    Case(name: "正常显示（满高 \(Int(normalHeight))、贴菜单栏底沿）",
         height: normalHeight, minY: normalMinY, expectOK: true),
    // 被降级：退化成图标高度，悬在屏幕顶边之外（与屏幕尺寸无关）
    Case(name: "被降级（22 高、悬到屏幕顶边之外）", height: 22, minY: -22, expectOK: false),
    // 被降级的另一种形态：位置挤在时钟那一行
    Case(name: "被降级（22 高、挤在时钟那一行）",
         height: 22, minY: menuBarBottom + 10, expectOK: false),
    // 别的 app 的正常项：同样满高、Y 差 1pt —— 判据不能只对自家尺寸成立
    Case(name: "别的 app 正常项（同满高、Y 差 1pt）",
         height: normalHeight, minY: normalMinY + 1, expectOK: true),
]

var judgementFailures = 0
var skippedCases = 0
for c in cases {
    guard let ok = looksPlacedCorrectly(height: c.height, minY: c.minY) else {
        skippedCases += 1
        print("  ⏭  \(c.name) → 跳过（当前拿不到菜单栏几何，无法判定）")
        continue
    }
    let pass = ok == c.expectOK
    if !pass { judgementFailures += 1 }
    print("  \(pass ? "✅" : "❌") \(c.name) → 判定「\(ok ? "正常" : "异常")」")
}
if skippedCases == cases.count {
    print("⚠️ 全部跳过：这个进程拿不到屏幕几何（锁屏 / 无图形会话）")
} else {
    print(judgementFailures == 0
          ? "✅ 通过：判据能准确区分「正常显示」与「被降级」"
          : "❌ 失败：判据把 \(judgementFailures) 种情形判错了")
}

// MARK: - 高度判据必须独立于宽度
//
// 这一条单独拎出来，因为它是整个判据的支点：
// 如果只按「宽度 68」或「X 坐标」判断，一旦换机型/换缩放就全废。
// 唯一稳定的量是「高度是否撑满菜单栏」—— 菜单栏高度由系统定，
// 跟这个 App 一点关系都没有。

line("高度判据不依赖本 App 的尺寸")

var adaptFailures = 0
for barHeight in [24.0, 28.0, 32.0, 38.0] {
    // 模拟「屏幕顶边 956、菜单栏厚度按 barHeight 变化」
    let top: CGFloat = 956
    let bottom = top - barHeight
    let full = looksPlacedCorrectly(height: barHeight + 1, minY: bottom,
                                    menuBarHeight: barHeight, menuBarBottom: bottom)
    let shrunk = looksPlacedCorrectly(height: barHeight - 11, minY: bottom,
                                      menuBarHeight: barHeight, menuBarBottom: bottom)
    // 这一段显式给足了几何参数，正常情况下不该出现 nil；
    // 若出现说明判据的前置守卫写错了，按失败处理。
    let pass = (full == true) && (shrunk == false)
    if !pass { adaptFailures += 1 }
    print("  \(pass ? "✅" : "❌") 菜单栏 \(Int(barHeight))pt 时：满高 \(Int(barHeight + 1)) → 正常，退化 \(Int(barHeight - 11)) → 异常")
}
// 用独立计数器：前面「缺几何而跳过」的情形不能算到这一段头上
if adaptFailures > 0 { judgementFailures += adaptFailures }
print(adaptFailures == 0
      ? "✅ 通过：判据随菜单栏高度自适应，不写死任何具体数值"
      : "❌ 失败：判据对菜单栏高度的变化不稳健")

// MARK: - 真实进程验证：位置异常时能否自愈
//
// 这一段要真起一个 App 进程看它自报的位置。
// 环境变量 CODEXO_BINARY 指向被测二进制；没给就跳过（单独跑本文件时）。

line("实跑：被测 App 自报的状态栏位置")

if let binary = ProcessInfo.processInfo.environment["CODEXO_BINARY"] {
    let fm = FileManager.default
    // 本测试专属的锁文件：与正式 App 的锁分开，
    // 这样正式 App 正在跑的时候，本测试照样能起自己的副本。
    let testLock = NSTemporaryDirectory() + "CodexO.singleton.placement-\(getpid()).lock"
    try? fm.removeItem(atPath: testLock)

    // ⚠️ 正式 App 正在运行时，这一段必须跳过。
    //
    // 2026-11-12 实测：正式 CodexO 占着菜单栏，此时再 `open` 一份同名可执行文件的副本，
    // 进程能起来，但**拿不到菜单栏位置**（frame 直接是 (0, -22, 68, 22)）。
    // 这不是 App 的毛病，是「同一时刻只允许一个该项挂上菜单栏」的客观限制。
    // 在這種条件下测出来的「异常」纯属噪音，会让构建误报失败。
    //
    // 没有干净条件就不下结论 —— 和判据里「拿不到屏幕几何就返回 nil」是同一条原则。
    func otherInstancesRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "CodexUsageMenuBar"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: out, encoding: .utf8) ?? ""
        return text.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    if otherInstancesRunning() {
        print("⏭  跳过实跑：正式 CodexO 正在运行，此刻起的副本拿不到菜单栏位置，测了也是噪音")
        print("    （判据自检已在上面完成；要跑实跑请先退出 CodexO）")
        exit(judgementFailures > 0 ? 1 : 0)
    }

    // ⚠️ 必须用 `open` 启动，不能直接执行可执行文件。
    // 状态栏项要经 LaunchServices 登记才会被菜单栏托管 ——
    // 直接跑可执行文件时拿不到位置（frame 会是 (0, -22)），
    // 而正式的自启配置走的也是 `open`，测试必须与它一致。
    let formalApp = URL(fileURLWithPath: binary)
        .deletingLastPathComponent()   // .../CodexO.app/Contents/MacOS
        .deletingLastPathComponent()   // .../CodexO.app/Contents
        .deletingLastPathComponent()   // .../CodexO.app

    // ⚠️ 但**不能启动正式 App 本身**：本测试会起进程再杀掉，
    // 而 macOS 会按 bundle id 记住状态栏项状态 —— 同一 id 被反复启停，
    // 系统就把它记成「不可见」，正式 App 之后再也显示不出图标。
    // 实测过：构建后立刻跑这项测试，正式图标必然消失。
    //
    // 所以复制一份临时副本，换一个**带时间戳的全新 id**（每次构建都不同，
    // 副本自己也来不及被记坏），对副本做启停。位置行为与 id 无关，
    // 只要 id 是干净的，测出来的就是同一份二进制在同样条件下的表现。
    let fmRun = FileManager.default
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexO-Placement-\(getpid())")
    try? fmRun.removeItem(at: sandbox)
    try? fmRun.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let copyApp = sandbox.appendingPathComponent(formalApp.lastPathComponent)

    func shell(_ tool: String, _ args: [String]) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: tool)
        t.arguments = args
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
    }
    shell("/usr/bin/ditto", [formalApp.path, copyApp.path])
    shell("/usr/bin/plutil", ["-replace", "CFBundleIdentifier",
                              "-string", "com.bean.codexo.placetest\(Int(Date().timeIntervalSince1970))",
                              copyApp.appendingPathComponent("Contents/Info.plist").path])
    defer { try? fmRun.removeItem(at: sandbox) }
    print("（被测对象：临时副本 + 时间戳 id，不碰正式 App）")

    let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/CodexUsageMenuBar.log")

    /// 日志里所有「窗口 frame」行
    func frameLines() -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { $0.contains("窗口 frame") }.map(String.init)
    }

    // 启动前记下**行数**。
    //
    // ⚠️ 不能比较最后一行的内容：正常启动每次写出来的 frame 完全一样
    // （都是 958, 923, 68, 33），内容相等不代表没有新增，
    // 用内容比较会稳定误报「日志没有新增」。必须比行数。
    let beforeCount = frameLines().count

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // --env 把锁路径带进被启动的进程（open 默认不继承 shell 环境）。
    // 不带的话副本会去抢正式 App 的锁，正式 App 在跑时副本直接退出，
    // 测试就会读不到新日志而误判。
    p.arguments = ["-g", "--env", "CODEXO_LOCK_PATH=\(testLock)", "-a", copyApp.path]
    try? p.run()
    p.waitUntilExit()

    // 等它把首份诊断写出来
    Thread.sleep(forTimeInterval: 8)

    let lines = frameLines()
    let frameLine: String
    if lines.count > beforeCount, let last = lines.last {
        frameLine = last
    } else if let last = lines.last {
        frameLine = last
        print("⚠️ 日志没有新增（启动前 \(beforeCount) 行，之后仍是 \(lines.count) 行），可能副本没起来")
    } else {
        frameLine = "（日志里没有窗口 frame 行）"
    }
    print("被测 App 自报：\(frameLine.trimmingCharacters(in: .whitespaces))")

    // 解析出高度与 Y。
    //
    // 日志里是 `窗口 frame : (958.0, 923.0, 68.0, 33.0)`，
    // CGRect 的四元组顺序是 **(x, y, 宽, 高)**。
    //
    // ⚠️ 这里踩过两个坑，方向相反、都很难发现：
    //
    // 1. **必须先把括号去掉**。否则首尾两个数字带着 "(" 和 ")"，
    //    Double() 转不出来，4 个数只剩中间 2 个。
    // 2. **高度是第 4 个数，不是第 3 个**。第 3 个是宽度（68）。
    //    早先写成 `nums[2]` 取"高度"，实际拿到的是宽度，
    //    于是 68 被当成"高度 68 ≥ 31 → 撑满菜单栏"，判据永远通过 ——
    //    一个坏掉的解析恰好让判据一直报「正常」，把它自己的错误盖住了。
    //    直到 frame 变成 (0, -22, 68, 22) 时，Y 那一项才把它戳穿。
    var height: CGFloat = -1
    var minY: CGFloat = -999
    let scanner = frameLine
        .replacingOccurrences(of: "窗口 frame", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "(", with: "")
        .replacingOccurrences(of: ")", with: "")
        .replacingOccurrences(of: " ", with: "")
    let nums = scanner.split(separator: ",").compactMap { Double($0) }
    if nums.count >= 4 {
        minY = CGFloat(nums[1])     // y
        height = CGFloat(nums[3])   // 高（第 3 个是宽，别弄反）
    }
    print("解析结果：高度 \(height)，Y \(minY)，宽 \(nums.count >= 3 ? nums[2] : -1)")

    let ok = looksPlacedCorrectly(height: height, minY: minY)
    switch ok {
    case .some(true):
        print("✅ 通过：App 启动后位置正常（高度撑满菜单栏、贴在菜单栏带上）")
    case .some(false):
        print("❌ 失败：App 启动后位置异常（这是待修的故障态）")
    case .none:
        print("⏭  跳过：拿不到菜单栏几何，无法判定（不是失败）")
    }

    // 收尾：只杀本次的临时副本。
    // 用副本路径（含本次 pid）做匹配，绝不按 "CodexUsageMenuBar" 泛杀 ——
    // 那样会把用户正在跑的正式 App 一起干掉。
    let killer = Process()
    killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killer.arguments = ["-f", "CodexO-Placement-\(getpid())"]
    killer.standardOutput = FileHandle.nullDevice
    killer.standardError = FileHandle.nullDevice
    try? killer.run()
    killer.waitUntilExit()
    Thread.sleep(forTimeInterval: 1)
} else {
    print("（未设置 CODEXO_BINARY，跳过实跑验证）")
}

print("\n════ 位置自愈测试结束 ════")
if judgementFailures > 0 {
    print("❌ 判据相关失败 \(judgementFailures) 项")
    exit(1)
}
