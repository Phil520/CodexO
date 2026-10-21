// 回归测试：单实例锁不能被「被拦下的副本」误删。
//
// 背景（2026-10-19 11:31 实测）：
//   副本启动 → acquireSingleInstanceLock() 返回 false → NSApp.terminate
//   → applicationWillTerminate 无条件删锁文件
//   → **把正式实例持有的锁一起删了**
//   → 第三个进程畅通无阻，菜单栏再次出现两个图标
//
// 这类 bug 只在「两个不同路径的副本 + 进程真跑起来」时才暴露，
// 光看单进程启动测不出来，所以本测试直接起真实子进程。
//
// ⚠️ 必须先用修复前的实现跑一遍，确认它会失败 —— 否则测试本身可能测不出东西。

import Foundation

var failures = 0

func check(_ condition: Bool, _ pass: String, _ fail: String) {
    print(condition ? "✅ 通过：\(pass)" : "❌ 失败：\(fail)")
    if !condition { failures += 1 }
}

/// 被测二进制所在的隔离副本 App 路径（测试收尾时删掉）
var isolatedAppRoot: URL?

/// 本测试专用的锁文件。
///
/// 正式 App 的锁在 $TMPDIR/CodexO.singleton.lock，是用户级共享位置。
/// 测试用自己的锁，就能和「用户正在跑的正式 App」同时存在，
/// 不必再把人家杀掉。App 侧通过 `CODEXO_LOCK_PATH` 支持这个覆盖。
let testLockPath = NSTemporaryDirectory() + "CodexO.singleton.test-\(getpid()).lock"

private var cachedBinary: URL?

/// 被测二进制：**独立 bundle id 的临时副本**，不是正式 App。
///
/// ## 为什么必须隔离（2026-10-21 踩出来的）
///
/// 本测试要连开 A/B/C 三个实例、再把它们全部杀掉。而 macOS 会按 bundle id
/// 记住状态栏项的状态：同一个 id 在几秒内被反复启停，位置分配还没稳定就被打断，
/// 系统会把这个 id 记成「不可见」。之后正式 App 再启动，进程活着、日志正常、
/// isVisible 报 true，但菜单栏上就是没有图标 —— 实测复现过多次。
///
/// 之前这里直接测正式 App，等于**每构建一次就把正式 App 的图标弄丢一次**，
/// 是「怎么改都看不见图标」的真正原因。
///
/// 结果缓存一次：这函数内部要复制整个 App，不能每次访问都重做。
var appBinary: URL {
    if let cachedBinary { return cachedBinary }

    let env = ProcessInfo.processInfo.environment["CODEXO_BINARY"]
    guard let path = env, !path.isEmpty else {
        print("❌ 缺少环境变量 CODEXO_BINARY")
        exit(2)
    }
    let formal = URL(fileURLWithPath: path)

    // .../X.app/Contents/MacOS/CodexUsageMenuBar → .../X.app
    let appRoot = formal.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    guard appRoot.pathExtension == "app" else {
        // 拿到的不是 App 里的二进制，没法隔离，只能原地测（并告知风险）
        print("⚠️ 被测路径不在 .app 内，跳过隔离，直接测原二进制")
        cachedBinary = formal
        return formal
    }

    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexO-SingleInstanceTest-\(getpid())")
    try? FileManager.default.removeItem(at: sandbox)
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

    let copy = sandbox.appendingPathComponent(appRoot.lastPathComponent)
    run("/usr/bin/ditto", [appRoot.path, copy.path])

    // 换一个专供本测试使用的 id，与正式 App 完全隔离。
    // 带上时间戳：每次构建都是全新 id，避免副本自己也被记成「不可见」。
    let stamp = Int(Date().timeIntervalSince1970)
    let plist = copy.appendingPathComponent("Contents/Info.plist")
    run("/usr/bin/plutil", ["-replace", "CFBundleIdentifier",
                            "-string", "com.bean.codexo.sitest\(stamp)", plist.path])

    isolatedAppRoot = sandbox
    let copyBinary = copy.appendingPathComponent("Contents/MacOS/CodexUsageMenuBar")
    print("⚠️ 已隔离：测试跑临时副本（独立 id + 独立锁），不碰正式 App")
    cachedBinary = copyBinary
    return copyBinary
}

/// 同步执行一个命令，静默处理输出
func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

/// 启动一个 App 实例，返回进程句柄（后台跑）
///
/// 锁路径指向本测试专属文件，这样正式 App 在跑也不影响本测试，
/// 本测试也不会动到正式 App 的锁。
func launch(_ binary: URL) throws -> Process {
    let p = Process()
    p.executableURL = binary
    var env = ProcessInfo.processInfo.environment
    env["CODEXO_LOCK_PATH"] = testLockPath
    p.environment = env
    try p.run()
    return p
}

/// 当前存活的**本测试副本**进程数。
///
/// 只数临时副本，不数正式 App：正式 App 是用户正在用的，
/// 它在跑不代表测试失败，更不该被这里杀掉。
func aliveCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "CodexO-SingleInstanceTest-\(getpid())"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
}

func runSingleInstanceTest() {
    print("\n════ 单实例锁回归测试 ════")
    let binary = appBinary
    print("被测二进制：\(binary.path)")

    let lockPath = testLockPath
    // 清掉可能存在的历史锁（只在本测试明确知道没有别的实例在跑时做）
    let baseline = aliveCount()
    print("测试前存活的副本进程数：\(baseline)")
    if baseline > 0 {
        print("⚠️ 已有测试副本在跑，本次测试作废——先把残留副本退干净再跑")
        return
    }
    try? FileManager.default.removeItem(atPath: lockPath)

    // ① 启动实例 A
    guard let a = try? launch(binary) else {
        print("❌ 失败：实例 A 起不来")
        failures += 1
        return
    }
    Thread.sleep(forTimeInterval: 4)
    let afterA = aliveCount()
    check(afterA == 1, "实例 A 起来了，进程数 1", "实例 A 没起来，进程数 \(afterA)")

    // A 应该写下了锁
    let lockExists = FileManager.default.fileExists(atPath: lockPath)
    check(lockExists, "实例 A 写下了锁文件", "实例 A 没写锁文件")

    // ② 启动副本 B —— 应被拦下并退出
    guard let b = try? launch(binary) else {
        print("❌ 失败：副本 B 起不来")
        failures += 1
        a.terminate()
        return
    }
    Thread.sleep(forTimeInterval: 4)

    let afterB = aliveCount()
    check(afterB == 1,
          "副本 B 被拦下，进程数仍是 1",
          "副本 B 没被拦下，进程数 \(afterB)")

    // ③ 关键判据：副本 B 退出后，A 的锁必须还在
    //    这是本测试的核心。旧实现（无条件删锁）在这里必然失败。
    let lockStillThere = FileManager.default.fileExists(atPath: lockPath)
    var lockOwner = "（读不到）"
    if lockStillThere,
       let text = try? String(contentsOfFile: lockPath, encoding: .utf8) {
        lockOwner = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    check(lockStillThere,
          "副本 B 退出后，A 的锁还在（锁中 pid=\(lockOwner)，A=\(a.processIdentifier)）",
          "副本 B 把 A 的锁误删了 —— 这正是「两个图标」复发的原因")

    // ④ 锁若还在且 pid 是 A，那第三个副本也必须被拦下
    if lockStillThere {
        guard let c = try? launch(binary) else {
            print("❌ 失败：副本 C 起不来")
            failures += 1
            a.terminate()
            return
        }
        Thread.sleep(forTimeInterval: 4)
        let afterC = aliveCount()
        check(afterC == 1,
              "副本 C 也被拦下，进程数仍是 1",
              "副本 C 畅通无阻，进程数 \(afterC)—— 两个图标会再次出现")
        c.terminate()
    }

    // 收尾：先杀进程，确认干净，再谈别的
    a.terminate()
    Thread.sleep(forTimeInterval: 2)
    if a.isRunning { kill(a.processIdentifier, SIGKILL) }
    b.terminate()
    Thread.sleep(forTimeInterval: 1)
    if b.isRunning { kill(b.processIdentifier, SIGKILL) }
    Thread.sleep(forTimeInterval: 1)

    let final = aliveCount()
    check(final == 0, "测试收尾后进程已清干净", "测试收尾后还有 \(final) 个残留进程")

    // 删掉隔离副本，不在临时目录留垃圾
    if let root = isolatedAppRoot {
        try? FileManager.default.removeItem(at: root)
    }
}