import Cocoa

// 冒烟测试：验证取数逻辑与菜单栏图标渲染
// 编译运行：
//   swiftc -swift-version 5 -framework Cocoa \
//     -o /tmp/reader_test src/UsageReader.swift src/MenuBarUI.swift tests/main.swift
//   /tmp/reader_test

func line(_ title: String) {
    print("\n=== \(title) ===")
}

line("读取结果")
let snapshot = UsageReader.load()

if let error = snapshot.error {
    print("错误：\(error)")
}
print("会话目录：\(UsageReader.sessionRoot)")
print("来源文件：\(snapshot.sourceFile ?? "—")")

let stamp = DateFormatter()
stamp.locale = Locale(identifier: "zh_CN")
stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
print("记录时间：\(snapshot.recordTime.map { stamp.string(from: $0) } ?? "—")")
print("读取时间：\(stamp.string(from: snapshot.loadedAt))")

line("窗口明细")
func dump(_ name: String, _ window: UsageWindow?) {
    guard let window else {
        print("\(name)：无数据")
        return
    }
    let reset = window.resetAt.map { stamp.string(from: $0) } ?? "—"
    print("""
    \(name)
      剩余      \(Format.percent(window.remaining))
      已用      \(Format.percent(window.used))
      窗口长度  \(window.windowMinutes) 分钟
      重置时间  \(reset)
      已过期    \(window.expired)
      告警状态  \(Palette.label(forRemaining: window.remaining))
      说明      \(Format.resetLine(window, name: name))
    """)
}
dump("5 小时窗口", snapshot.fiveHour)
dump("每周窗口", snapshot.weekly)

line("状态栏标题预览")
if let five = snapshot.fiveHour {
    print("菜单栏显示：环形图标 + \(Format.percent(five.remaining))")
    print("悬浮提示：")
    print("  " + (snapshot.error ?? "ok"))
} else {
    print("菜单栏显示：环形图标 + --")
}

line("内圈月相换算")
print("档位 → 代表余量 → 月相名 → 亮度比例 → 明暗界线系数")
for level in 1...Palette.moonLevelCount {
    let value = Palette.moonLevelValues[level - 1]
    let phase = Palette.moonPhase(forRemaining: value)
    let ratio = Palette.moonTerminatorRatio(forPhase: phase)
    print(String(format: "  档 %d  代表 %5.1f%%  %@  亮度 %.2f  界线 %+.3f",
                 level, value, Palette.moonName(forRemaining: value),
                 phase, Double(ratio)))
}

print("分界点（余量 → 档位，验证七档互不重叠且覆盖 0–100）")
let boundaries: [Double] = [0, 19.9, 20, 34.9, 35, 44.9, 45, 54.9, 55, 69.9, 70, 89.9, 90, 100]
for remaining in boundaries {
    print(String(format: "  %6.1f%%  →  档 %d  %@",
                 remaining,
                 Palette.moonLevel(forRemaining: remaining),
                 Palette.moonName(forRemaining: remaining)))
}

line("图标渲染")
let previewDir = "/tmp/codex-menuicon-preview"
try? FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)

let iconSize: CGFloat = 32
let drawScale: CGFloat = 2

func makeIcon(fiveHour: Double, weekly: Double?) -> NSImage {
    IconFactory.icon(fiveHour: fiveHour / 100,
                     fiveHourColor: Palette.color(forRemaining: fiveHour),
                     moonPhase: weekly.map { Palette.moonPhase(forRemaining: $0) },
                     size: iconSize, scale: drawScale)
}

/// 把一批图标按网格铺到指定底色上，便于肉眼核对透明度差异
func compose(_ grid: [[NSImage]],
             background: NSColor,
             gap: CGFloat = 8,
             pad: CGFloat = 8) -> NSImage {
    let rows = grid.count
    let cols = grid.map { $0.count }.max() ?? 0
    guard rows > 0, cols > 0 else { return NSImage(size: .zero) }

    let cell = iconSize + gap
    let pointSize = NSSize(width: pad * 2 + cell * CGFloat(cols),
                           height: pad * 2 + cell * CGFloat(rows))
    let pixelW = Int(pointSize.width * drawScale)
    let pixelH = Int(pointSize.height * drawScale)

    guard let ctx = CGContext(data: nil,
                              width: pixelW,
                              height: pixelH,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return NSImage(size: pointSize)
    }

    ctx.scaleBy(x: drawScale, y: drawScale)
    let bg = (background.usingColorSpace(.deviceRGB) ?? background).cgColor
    ctx.setFillColor(bg)
    ctx.fill(CGRect(origin: .zero, size: pointSize))

    for (rowIndex, row) in grid.enumerated() {
        for (colIndex, icon) in row.enumerated() {
            guard let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let x = pad + CGFloat(colIndex) * cell + gap / 2
            let y = pointSize.height - pad - CGFloat(rowIndex + 1) * cell + gap / 2
            ctx.draw(cg, in: CGRect(x: x, y: y, width: iconSize, height: iconSize))
        }
    }

    guard let image = ctx.makeImage() else { return NSImage(size: pointSize) }
    return NSImage(cgImage: image, size: pointSize)
}

func save(_ image: NSImage, _ name: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("\(name)：渲染失败")
        return
    }
    let path = "\(previewDir)/\(name).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("  \(name) → \(path)")
}

let lightBG = NSColor(calibratedWhite: 0.94, alpha: 1)
let darkBG = NSColor(calibratedWhite: 0.16, alpha: 1)

// 条图一：固定外圈（5H 剩余 70%），内圈从第 1 档排到第 7 档。
// 月相配色深浅通用，所以不再按外观出两张 —— 一张就够。
func phaseStrip() -> [NSImage] {
    Palette.moonLevelValues.map { value in makeIcon(fiveHour: 70, weekly: value) }
}
print("七档月相条图（外圈固定 5H=70%，内圈第 1→7 档）：")
save(compose([phaseStrip()], background: lightBG), "moon_levels_light")

// 条图二：5H × 周用量组合矩阵，核对两者叠加效果
let fiveHourCases: [Double] = [100, 60, 25, 5]
let weeklyCases: [Double] = [100, 60, 30, 10]
func matrix() -> [[NSImage]] {
    fiveHourCases.map { five in
        weeklyCases.map { week in makeIcon(fiveHour: five, weekly: week) }
    }
}
print("组合矩阵（行=5H 剩余 \(fiveHourCases.map { Int($0) })，列=周剩余 \(weeklyCases.map { Int($0) })）：")
save(compose(matrix(), background: lightBG), "combined_light")

// 边界情形：周余量无数据 / 恰好归零 / 两端极值
let edge: [[NSImage]] = [[
    makeIcon(fiveHour: 80, weekly: nil),
    makeIcon(fiveHour: 80, weekly: 0),
    makeIcon(fiveHour: 0, weekly: 0),
    makeIcon(fiveHour: 0, weekly: 100)
]]
print("边界情形（外圈 80/80/0/0，内圈 无数据/0/0/100）：")
save(compose(edge, background: lightBG), "edge_light")

print("\n完成。")

// MARK: - 取数边界回归
//
// 场景（真实踩过）：某个旧日期的会话文件后来被重新追加写入，
// 于是它的「文件修改时间」成了全目录最新，但它尾部能扫到的最新
// token_count 事件却很旧。取数必须以**事件时间戳**为准，而不是文件 mtime。

line("回归：旧文件被重新追加时，不能拿它的旧读数当当前值")

let fixtureRoot = "/tmp/codex-usage-fixture"
try? FileManager.default.removeItem(atPath: fixtureRoot)

func writeSessionAt(_ root: String,
                    _ relativePath: String,
                    used: Double,
                    resetsIn: TimeInterval,
                    eventAt: Date) throws {
    let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let reset = Int(Date().addingTimeInterval(resetsIn).timeIntervalSince1970)
    let line = """
    {"timestamp":"\(stamp.string(from: eventAt))","payload":{"type":"token_count","rate_limits":\
    {"primary":{"used_percent":\(used),"window_minutes":300,"resets_at":\(reset)},\
    "secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":\(reset + 600_000)}}}}
    """
    try line.write(to: url, atomically: true, encoding: .utf8)
    // 把文件的修改时间对齐到事件时间之后，模拟「内容写进去的那一刻」
    try FileManager.default.setAttributes([.modificationDate: eventAt], ofItemAtPath: url.path)
}

func writeSession(_ relativePath: String, used: Double, resetsIn: TimeInterval, eventAt: Date) throws {
    try writeSessionAt(fixtureRoot, relativePath, used: used, resetsIn: resetsIn, eventAt: eventAt)
}

do {
    // 先写「新」文件（含今天的读数），再写「旧」文件（含三天前的读数）。
    // 后写的那个 mtime 更新 —— 旧实现正是被这一点骗到。
    let recent = Date().addingTimeInterval(-600)
    let stale = Date().addingTimeInterval(-3 * 86_400)

    try writeSession("2026/10/13/new-session.jsonl", used: 26, resetsIn: 3 * 3_600, eventAt: recent)
    try writeSession("2026/10/09/old-session.jsonl", used: 85, resetsIn: 3 * 3_600, eventAt: stale)

    let files = FileManager.default.subpaths(atPath: fixtureRoot) ?? []
    let expectedNewestByMtime = files.contains { $0.hasSuffix("old-session.jsonl") }
    print("目录内文件：\(files.sorted())")
    print("mtime 最新的文件是 old-session.jsonl（旧读数）→ \(expectedNewestByMtime)")

    UsageReader.sessionRoot = fixtureRoot
    let fixture = UsageReader.load()

    let remaining = fixture.fiveHour?.remaining ?? -1
    let record = fixture.recordTime.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
    print("取数结果：5H 剩余 \(Format.percent(remaining))　记录时间 \(record)")
    print("来源文件：\(fixture.sourceFile ?? "—")")

    let pickedNewestEvent = abs(remaining - 74) < 0.01
        && (fixture.sourceFile?.contains("new-session") ?? false)
    print(pickedNewestEvent
          ? "✅ 通过：按事件时间戳取了新文件的读数（旧实现会取到 100% / old-session）"
          : "❌ 失败：没有取到事件时间戳最新的读数")

    // 还原，避免影响后续手动调试
    UsageReader.sessionRoot = ("~/.codex/sessions" as NSString).expandingTildeInPath
}

// MARK: - 取数边界回归二
//
// 场景（真实踩过，比上一条更隐蔽）：会话文件长过 1 MB 之后，
// 尾部读取的起点 = 「文件尾 − 1 MB」，这个字节偏移完全可能落在某个
// **多字节汉字**的中间。此时整段 bytes 不是合法 UTF-8，
// `String(data:encoding:.utf8)` 直接返回 nil，上游跳出重试循环，
// 于是**最新的那份文件被整份静默跳过**，界面显示的是上一个文件的旧读数。
//
// 症状是「用着用着数字就不动了」——文件不到 1 MB 时起点为 0，永远切不坏。

line("回归：尾部起点切在多字节汉字中间时，最新文件不能被跳过")

let bigFixtureRoot = "/tmp/codex-usage-fixture-big"
try? FileManager.default.removeItem(atPath: bigFixtureRoot)

do {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let nowEvent = Date()
    let resetEpoch = Int(nowEvent.addingTimeInterval(3 * 3_600).timeIntervalSince1970)
    let jsonLine = "{\"timestamp\":\"\(iso.string(from: nowEvent))\","
        + "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{"
        + "\"primary\":{\"used_percent\":10.0,\"window_minutes\":300,\"resets_at\":\(resetEpoch)},"
        + "\"secondary\":{\"used_percent\":25.0,\"window_minutes\":10080,\"resets_at\":\(resetEpoch + 600_000)}}}}\n"

    // 用 3 字节汉字填充 1.5 MB，让「文件尾 − 1 MB」这个偏移落在填充区内部。
    // 注意：偏移要按**最终文件内容**算，别忘了 filler 与 JSON 行之间那个 1 字节的换行，
    // 漏掉它就会刚好差 1 字节、把边界挪到字符起始位置，测试也就抓不到这个 bug 了。
    let budget = 1 << 20
    var filler = String(repeating: "汉", count: 500_000)      // 恰好 1_500_000 字节
    func boundaryOffset(for filler: String) -> Int {
        (filler + "\n" + jsonLine).utf8.count - budget
    }
    var boundary = boundaryOffset(for: filler)
    if boundary % 3 == 0 {
        filler += "é"                                          // 补 2 字节，把边界挪进续字节区
        boundary = boundaryOffset(for: filler)
    }

    print("填充区 \(filler.utf8.count) 字节，尾部读取起点 = 偏移 \(boundary)"
          + "，该位置在汉字内的第 \(boundary % 3) 个字节（1/2 = 续字节 → 旧实现解码失败）")

    // 大文件：事件时间最新、读数 5H 已用 10%（剩余 90%）
    let bigURL = URL(fileURLWithPath: bigFixtureRoot)
        .appendingPathComponent("2026/10/14/big-session.jsonl")
    try FileManager.default.createDirectory(at: bigURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
    try (filler + "\n" + jsonLine).write(to: bigURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: nowEvent], ofItemAtPath: bigURL.path)

    // 对照文件：事件时间略早、读数不同（5H 已用 85%）
    let staleEvent = nowEvent.addingTimeInterval(-3_600)
    try writeSessionAt(bigFixtureRoot, "2026/10/14/small-session.jsonl",
                       used: 85, resetsIn: 3 * 3_600, eventAt: staleEvent)

    UsageReader.sessionRoot = bigFixtureRoot
    let fixture = UsageReader.load()

    let remaining = fixture.fiveHour?.remaining ?? -1
    print("取数结果：5H 剩余 \(Format.percent(remaining))")
    print("来源文件：\(fixture.sourceFile ?? "—")")

    let boundaryIsContinuation = (boundary % 3) != 0
    let pickedBigFile = abs(remaining - 90) < 0.01
        && (fixture.sourceFile?.contains("big-session") ?? false)
    print(boundaryIsContinuation && pickedBigFile
          ? "✅ 通过：尾部起点切在汉字中间，仍取到最新文件的 90%（旧实现会读成 small-session 的 15%）"
          : "❌ 失败：最新文件被跳过或取到了对照文件的读数")

    UsageReader.sessionRoot = ("~/.codex/sessions" as NSString).expandingTildeInPath
}

// MARK: - 回归三：手动刷新必须能绕过缓存

do {
    line("回归：手动刷新必须绕过缓存（2026-10-19 现场）")

    let root = "/tmp/codexo-manual-refresh-fixture"
    try? FileManager.default.removeItem(atPath: root)

    let nowEvent = Date()
    let twoDaysAgo = nowEvent.addingTimeInterval(-2 * 86_400)

    // 旧会话：两天前的读数，5H 已用 16% → 剩 84%
    try writeSessionAt(root, "2026/10/14/old-session.jsonl",
                       used: 16, resetsIn: 4 * 3_600, eventAt: twoDaysAgo)

    // 新会话：刚创建，**里面没有任何额度事件**
    // 复刻现场：新会话文件已存在、mtime 已是最新，但第一条带 rate_limits 的
    // 事件要等第一次请求之后才落盘。
    let newURL = URL(fileURLWithPath: root).appendingPathComponent("2026/10/19/new-session.jsonl")
    let newPath = newURL.path
    try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let bareLine = "{\"timestamp\":\"\(stamp.string(from: nowEvent))\","
                 + "\"payload\":{\"type\":\"token_count\","
                 + "\"info\":{\"total_token_usage\":{\"total_tokens\":35760}}}}\n"
    try bareLine.write(toFile: newPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: nowEvent], ofItemAtPath: newPath)

    UsageReader.sessionRoot = root
    UsageReader.invalidateCache()

    let first = UsageReader.load()
    print("① 新会话还没有额度事件时，5H 剩余 \(Format.percent(first.fiveHour?.remaining ?? -1))"
          + "（只能来自 old-session）")

    // 给新会话补上额度事件：5H 已用 3% → 剩 97%
    let resetEpoch = Int(nowEvent.addingTimeInterval(4 * 3_600).timeIntervalSince1970)
    let eventAt = nowEvent.addingTimeInterval(60)
    let stamped = ISO8601DateFormatter()
    stamped.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let withRate = bareLine
        + "{\"timestamp\":\"\(stamped.string(from: eventAt))\",\"payload\":{\"type\":\"token_count\","
        + "\"info\":{\"total_token_usage\":{\"total_tokens\":35760}},"
        + "\"rate_limits\":{\"primary\":{\"used_percent\":3.0,\"window_minutes\":300,"
        + "\"resets_at\":\(resetEpoch)},"
        + "\"secondary\":{\"used_percent\":2.0,\"window_minutes\":10000,"
        + "\"resets_at\":\(resetEpoch + 600_000)}}}}\n"
    try withRate.write(toFile: newPath, atomically: true, encoding: .utf8)

    // ⚠️ 把 mtime 强行改回原值 —— 模拟「缓存 key 没变」
    // 这一步是本测试能成立的全部前提：只要 mtime 变了，任何实现靠重扫就能过，
    // 根本测不出「缓存把用户的刷新吞了」这件事。
    try FileManager.default.setAttributes([.modificationDate: nowEvent], ofItemAtPath: newPath)
    print("② 已补上额度事件，并把 mtime 改回原值（缓存 key 不变）")

    // 模拟用户点「立即刷新」：现在 doRefresh() 会先 invalidateCache()
    UsageReader.invalidateCache()
    let second = UsageReader.load()

    let remaining = second.fiveHour?.remaining ?? -1
    let pickedNew = abs(remaining - 97) < 0.01
        && ((second.sourceFile?.contains("new-session")) ?? false)
    print("③ 手动刷新后 5H 剩余 \(Format.percent(remaining))，来源 \(second.sourceFile ?? "—")")

    print(pickedNew
          ? "✅ 通过：手动刷新绕过缓存，读到新会话的 97%（不刷新会一直停在 84%）"
          : "❌ 失败：手动刷新被缓存吞掉，仍返回两天前的读数")

    try? FileManager.default.removeItem(atPath: root)
    UsageReader.sessionRoot = ("~/.codex/sessions" as NSString).expandingTildeInPath
    UsageReader.invalidateCache()
}


// 回归四：单实例锁不能被「被拦下的副本」误删。
// 2026-10-19 11:31 实测出的真bug：副本被拦下后退出时，
// applicationWillTerminate 无条件删锁，把正式实例的锁一起删了，
// 于是第三个进程畅通无阻 —— 上一轮修掉的「两个图标」原样复发。
// ⚠️ 必须用 #if 把这段圈起来，不能只靠环境变量判空。
// `runSingleInstanceTest` 定义在 tests/single_instance.swift 里，
// 而那个文件只在跑单实例测试时才一起编译；不圈起来的话，
// 单独编译本文件（跑取数回归）会因为找不到符号而编译失败。
// 环境变量只决定"跑不跑"，#if 决定"这段代码存不存在"。
#if CODEXO_SINGLE_INSTANCE_TESTS
if ProcessInfo.processInfo.environment["CODEXO_BINARY"] != nil {
    runSingleInstanceTest()
    if failures > 0 {
        print("\n════ 单实例锁测试失败 \(failures) 项 ════")
    }
}
#endif
