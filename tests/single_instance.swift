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

var appBinary: URL {
    // 由 run_single_instance.sh 传进来
    let env = ProcessInfo.processInfo.environment["CODEXO_BINARY"]
    guard let path = env, !path.isEmpty else {
        print("❌ 缺少环境变量 CODEXO_BINARY")
        exit(2)
    }
    return URL(fileURLWithPath: path)
}

/// 启动一个 App 实例，返回进程句柄（后台跑）
func launch(_ binary: URL) throws -> Process {
    let p = Process()
    p.executableURL = binary
    try p.run()
    return p
}

/// 当前存活的 CodexO 进程数
func aliveCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "CodexUsageMenuBar"]
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

    let lockPath = NSTemporaryDirectory() + "CodexO.singleton.lock"
    // 清掉可能存在的历史锁（只在本测试明确知道没有别的实例在跑时做）
    let baseline = aliveCount()
    print("测试前存活的 CodexO 进程数：\(baseline)")
    if baseline > 0 {
        print("⚠️ 已有实例在跑，本次测试作废——先把所有 CodexO 退干净再跑")
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
       let text = try? String(contentsOfFile: lockPath) {
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
}