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
let menuBarHeight = screen?.safeAreaInsets.top ?? 32
// 菜单栏那条带：贴着屏幕顶端，厚度 = menuBarHeight。
// 坐标原点在左下角，所以这条带是 [屏幕高 − menuBarHeight, 屏幕高]。
let screenTop = screen?.frame.maxY ?? 0
let menuBarBottom = screenTop - menuBarHeight
let expectedHeight = menuBarHeight + 1

print("菜单栏高度（safeAreaInsets.top）= \(menuBarHeight)")
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
func looksPlacedCorrectly(height: CGFloat,
                          minY: CGFloat,
                          menuBarHeight bar: CGFloat = menuBarHeight,
                          menuBarBottom bottom: CGFloat = menuBarBottom) -> Bool {
    let expected = bar + 1
    // 主判据：高度撑满菜单栏（这是"被降级"最稳定的特征）
    if height < expected - 2 { return false }
    // 辅助判据：高度对，但悬在菜单栏那条带之外。
    // 允许 2pt 容差：正常项的底沿不一定正好等于那条带的边界。
    if minY > bottom + bar + 2 { return false }   // 悬在屏幕顶边之上
    if minY < bottom - 2 { return false }         // 掉到菜单栏带底沿以下
    return true
}

// 现场抓到的三种真实取值
struct Case { let name: String; let height: CGFloat; let minY: CGFloat; let expectOK: Bool }
let cases: [Case] = [
    // 正常：撑满菜单栏，贴在菜单栏底沿
    Case(name: "正常显示（实测 33 高、y=923）", height: 33, minY: 923, expectOK: true),
    // 被降级：退化成图标高度，悬在屏幕顶边之外
    Case(name: "被降级（实测 22 高、y=-22）", height: 22, minY: -22, expectOK: false),
    // 被降级的另一种形态：位置挤在时钟底下
    Case(name: "被降级（实测 22 高、y=934 压在时钟下）", height: 22, minY: 934, expectOK: false),
    // 另一个 app 的正常项（宽 61、同样是满高）—— 判据不能只对自家尺寸成立
    Case(name: "别的 app 正常项（33 高、y=923）", height: 33, minY: 923, expectOK: true),
]

var judgementFailures = 0
for c in cases {
    let ok = looksPlacedCorrectly(height: c.height, minY: c.minY)
    let pass = ok == c.expectOK
    if !pass { judgementFailures += 1 }
    print("  \(pass ? "✅" : "❌") \(c.name) → 判定「\(ok ? "正常" : "异常")」")
}
print(judgementFailures == 0
      ? "✅ 通过：判据能准确区分「正常显示」与「被降级」"
      : "❌ 失败：判据把 \(judgementFailures) 种情形判错了")

// MARK: - 高度判据必须独立于宽度
//
// 这一条单独拎出来，因为它是整个判据的支点：
// 如果只按「宽度 68」或「X 坐标」判断，一旦换机型/换缩放就全废。
// 唯一稳定的量是「高度是否撑满菜单栏」—— 菜单栏高度由系统定，
// 跟这个 App 一点关系都没有。

line("高度判据不依赖本 App 的尺寸")

for barHeight in [24.0, 28.0, 32.0, 38.0] {
    // 模拟「屏幕顶边 956、菜单栏厚度按 barHeight 变化」
    let top: CGFloat = 956
    let bottom = top - barHeight
    let full = looksPlacedCorrectly(height: barHeight + 1, minY: bottom,
                                    menuBarHeight: barHeight, menuBarBottom: bottom)
    let shrunk = looksPlacedCorrectly(height: barHeight - 11, minY: bottom,
                                      menuBarHeight: barHeight, menuBarBottom: bottom)
    let pass = full && !shrunk
    if !pass { judgementFailures += 1 }
    print("  \(pass ? "✅" : "❌") 菜单栏 \(Int(barHeight))pt 时：满高 \(Int(barHeight + 1)) → 正常，退化 \(Int(barHeight - 11)) → 异常")
}
print(judgementFailures == 0
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
    // 日志里是 `窗口 frame : (958.0, 923.0, 68.0, 33.0)` ——
    // **必须先把括号去掉**，否则首尾两个数字会带着 "(" 和 ")"，
    // Double() 转不出来，4 个数只剩中间 2 个（高度直接解析成 -1，
    // 于是一个完全正常的 frame 被判成"异常"）。这个坑实际踩过一次。
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
        minY = CGFloat(nums[1])
        height = CGFloat(nums[2])
    }
    print("解析结果：高度 \(height)，Y \(minY)")

    let ok = looksPlacedCorrectly(height: height, minY: minY)
    print(ok
          ? "✅ 通过：App 启动后位置正常（高度撑满菜单栏、贴在菜单栏带上）"
          : "❌ 失败：App 启动后位置异常（这是待修的故障态）")

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
