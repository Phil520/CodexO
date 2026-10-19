import Foundation

/// 单个用量窗口（5 小时窗口或每周窗口）
struct UsageWindow {
    let remaining: Double      // 剩余百分比 0...100
    let used: Double           // 已用百分比
    let resetAt: Date?         // 下一次重置时间
    let windowMinutes: Int     // 窗口长度（分钟）
    let expired: Bool          // 窗口是否已过期
}

/// 一次读取的完整结果
struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let sourceFile: String?
    let recordTime: Date?
    let loadedAt: Date
    let error: String?

    var hasData: Bool { fiveHour != nil || weekly != nil }

    /// 无数据时的说明文字
    var unavailableReason: String {
        if let error { return error }
        return "尚未读取到用量数据"
    }
}

/// 从 ~/.codex/sessions 读取本地会话日志并解析额度
///
/// 取数口径与 VS Code 扩展 jefersoonaf.codex-usage-remaining 一致：
///   · 只读最近 7 天内修改过的 .jsonl 会话文件
///   · 在 token_count 事件里读 payload.rate_limits
///   · primary → 5 小时窗口；secondary → 每周窗口
///   · 剩余百分比 = 100 − used_percent；若窗口已过期则视为 100%
///
/// 性能上有两条硬约束（会话日志会持续膨胀，必须扛得住）：
///   1. **只读文件尾部**。日志单个文件可达上百 MB，整读会卡死主线程（实测 276 MB 时耗时 8 秒）。
///      这里按 1 MB → 8 MB → 64 MB 逐级放大，命中即停，正常情况只读 1 MB。
///   2. **扫描方向从新到旧**，遇到第一条可用读数就返回，不遍历全文件。
///
/// 额度耗尽时 Codex 会写入 primary / secondary 为 null 的事件，故两个窗口**各自回溯**到
/// 最近一条有真实数值的事件，互不影响。
enum UsageReader {

    /// 会话日志根目录。默认是 Codex 的标准位置。
    /// 做成可写是为了让测试能指向一份人造日志目录，复现那些真实环境里偶发、
    /// 但代价很大的边界场景（例如「旧文件被重新追加写入」）。
    static var sessionRoot = ("~/.codex/sessions" as NSString).expandingTildeInPath

    /// 最多扫描多少个会话文件（按修改时间倒序）
    private static let maxFilesToScan = 20

    /// 尾部读取的逐级放大预算（字节）
    private static let tailBudgets = [1 << 20, 8 << 20, 64 << 20]

    /// 结果缓存：文件规模未变化时直接复用，避免每次开菜单都重扫
    private static var cache: (key: String, snapshot: UsageSnapshot)?

    /// 丢掉缓存，强制下一次 `load()` 真的重扫文件。
    ///
    /// 手动「立即刷新」必须走这条路。
    ///
    /// 踩过的坑：缓存 key 只看「mtime 最新那个文件」的时间。
    /// 2026-10-19 上午实测——用户新建了一个 Codex 会话，然后立刻点「立即刷新」，
    /// 结果看到的还是两天前的读数。原因不是没刷新，而是：
    /// 那个新会话文件当时**还没有写出第一条带 `rate_limits` 的事件**
    /// （会话刚创建，额度事件要等第一次请求后才落盘），
    /// 它的 mtime 虽在动但 key 恰好与上次相同 → 缓存命中 → 直接返回旧结果。
    ///
    /// 也就是说「用户主动点了刷新」这个动作被缓存吞掉了 ——
    /// 从用户视角看就是「我明明点了，它就是不动」。
    ///
    /// **凡是有"缓存"的地方，就必须有一条能让用户主动绕过它的路径。**
    /// 自动刷新时可以信任缓存（省掉重扫），但手动刷新是用户在说
    /// 「我怀疑你错了，去看看」——此时再拿缓存糊弄他，就是把用户的质疑当噪声。
    static func invalidateCache() {
        cache = nil
    }

    /// 时间戳格式化器建一次即可（热点路径上每次新建属于无谓的分配）
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 对外入口。整段包在自动释放池里：这是一个每分钟被调用一次、
    /// 且会产出大量临时字符串（尾部读出的成千上万行）的函数，
    /// 显式收池能保证这些临时对象立刻归还，不在长驻进程里堆积。
    static func load() -> UsageSnapshot {
        autoreleasepool { performLoad() }
    }

    private static func performLoad() -> UsageSnapshot {
        let now = Date()
        let fm = FileManager.default

        guard fm.fileExists(atPath: sessionRoot) else {
            return blank(at: now, error: "没有找到 Codex 会话目录 ~/.codex/sessions")
        }

        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: sessionRoot),
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return blank(at: now, error: "无法读取 Codex 会话目录")
        }

        // 1. 收集最近 7 天内动过的会话文件
        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) <= 7 * 86_400 {
                files.append((url, mtime))
            }
        }

        guard !files.isEmpty else {
            return blank(at: now, error: "最近 7 天没有 Codex 会话记录")
        }

        // mtime 相同时再按路径排：`sort` 的比较器在相等时结果未定义，
        // 而 `files[0]` 参与结果缓存的 key —— 若每次枚举出来的顺序不同，
        // key 就会来回抖动、缓存反复失效，白白重扫（最坏情况每次都是冷读）。
        files.sort { ($0.mtime, $0.url.path) > ($1.mtime, $1.url.path) }

        // 2. 缓存命中判断：文件个数与最新文件的路径/时间都没变，说明日志没写过新东西
        let key = "\(sessionRoot)|\(files.count)|\(files[0].url.path)|\(files[0].mtime.timeIntervalSince1970)"
        if let cached = cache, cached.key == key {
            return refreshClock(cached.snapshot, at: now)
        }

        // 3. 只读尾部，逐文件取「尾部最新的一条读数」，再按**事件时间戳**取全局最新
        //
        // 这里不能用「文件修改时间」当作数据新鲜度的依据。
        // 踩过的坑：10/09 的会话文件在今天 16:04 被重新追加写入，于是它的 mtime 成了最新的；
        // 但它尾部能扫到的最新 token_count 事件还是 10-10 的。
        // 旧写法在「凑齐两个窗口」后立刻 break，于是拿三天前的读数当成了当前值 ——
        // 5 小时窗口因为旧读数已过期被判成 100%，每周窗口显示成 33%，两个数都是错的。
        //
        // 正确做法：以事件自带的 timestamp 为准跨文件比较，取真正最新的那条。
        var primaryReading: (limit: [String: Any], time: Date, file: String)?
        var secondaryReading: (limit: [String: Any], time: Date, file: String)?

        let newestFile = files[0].url.lastPathComponent

        scan: for entry in files.prefix(maxFilesToScan) {
            // 停止条件：当已取得两个窗口的读数，且本文件（以及后面 mtime 更小的文件）
            // 的修改时间都不晚于已取得的时间戳时，就不可能再有更新的读数了 ——
            // 因为一条事件的 timestamp 不可能晚于它所在文件的 mtime。
            if let primary = primaryReading, let secondary = secondaryReading {
                let cutoff = min(primary.time, secondary.time)
                if entry.mtime <= cutoff { break scan }
            }

            let name = entry.url.lastPathComponent
            var filePrimary: (limit: [String: Any], time: Date)?
            var fileSecondary: (limit: [String: Any], time: Date)?

            for budget in tailBudgets {
                guard let lines = tailLines(of: entry.url, maxBytes: budget) else { break }

                for line in lines.reversed() {
                    // 快速预筛，避免对每一行都做 JSON 解析
                    guard line.contains("\"rate_limits\"") else { continue }
                    guard let data = line.data(using: .utf8),
                          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let payload = root["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count",
                          let limits = payload["rate_limits"] as? [String: Any] else { continue }

                    let stamp = (root["timestamp"] as? String)
                        .flatMap { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) } ?? entry.mtime

                    // 日志是追加写的，倒序扫描时先遇到的就是该文件里最新的一条
                    if filePrimary == nil,
                       usable(limits["primary"]),
                       let value = limits["primary"] as? [String: Any] {
                        filePrimary = (value, stamp)
                    }

                    if fileSecondary == nil,
                       usable(limits["secondary"]),
                       let value = limits["secondary"] as? [String: Any] {
                        fileSecondary = (value, stamp)
                    }

                    if filePrimary != nil && fileSecondary != nil { break }
                }

                if filePrimary != nil && fileSecondary != nil { break }
            }

            // 跨文件只认时间戳更新的那条
            if let candidate = filePrimary,
               candidate.time > (primaryReading?.time ?? .distantPast) {
                primaryReading = (candidate.limit, candidate.time, name)
            }
            if let candidate = fileSecondary,
               candidate.time > (secondaryReading?.time ?? .distantPast) {
                secondaryReading = (candidate.limit, candidate.time, name)
            }
        }

        guard primaryReading != nil || secondaryReading != nil else {
            let empty = UsageSnapshot(fiveHour: nil, weekly: nil,
                                      sourceFile: newestFile,
                                      recordTime: nil,
                                      loadedAt: now,
                                      error: "日志里还没有可用的额度记录，先跑一次 Codex 就会有了")
            cache = (key, empty)
            return empty
        }

        // 两个窗口各自用自己那条读数的记录时间，算重置时间时才对得上
        let primaryTime = primaryReading?.time ?? .distantPast
        let secondaryTime = secondaryReading?.time ?? .distantPast
        let recordTime = max(primaryTime, secondaryTime)

        let snapshot = UsageSnapshot(fiveHour: primaryReading.flatMap { window($0.limit, recordedAt: $0.time) },
                                     weekly: secondaryReading.flatMap { window($0.limit, recordedAt: $0.time) },
                                     sourceFile: (primaryTime >= secondaryTime
                                                  ? primaryReading?.file
                                                  : secondaryReading?.file) ?? newestFile,
                                     recordTime: recordTime == .distantPast ? nil : recordTime,
                                     loadedAt: now,
                                     error: nil)

        cache = (key, snapshot)
        return snapshot
    }

    // MARK: - 读取文件尾部

    /// 读取文件最后 maxBytes 字节并按行切分；开头那半行（被截断的）会被丢弃
    private static func tailLines(of url: URL, maxBytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let start: UInt64 = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0

        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // 切行必须在**字节层面**做，绝不能先整段解码、再去字符串里找第一个换行。
        //
        // 踩过的坑（代价很大，必须留着）：起点是「文件尾 − 预算」的字节偏移，
        // 它完全可能落在某个多字节字符（日志里满是中文）的中间。
        // 一旦如此，整段 bytes 就不是合法 UTF-8，String(data:encoding:.utf8) 会**直接返回 nil**；
        // 上游拿到 nil 就跳出放大预算的循环，于是**最新的那份会话文件被整份静默跳过**，
        // 界面上显示的是上一个文件的旧读数。
        //
        // 这个坑只在单个会话文件长过 1 MB 之后才触发（小于 1 MB 时起点为 0，永远不会切坏），
        // 所以症状是「用着用着数字就不动了」，而不是一开始就错 —— 最容易让人怀疑是显示问题。
        let payload: Data
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            payload = data[data.index(after: newline)...]
        } else {
            payload = data
        }

        // 再有损解码兜底：万一日志正写到一半（尾部留下半个字符），也只是那一行 JSON
        // 解析失败被跳过，不会把整份文件丢掉。
        let text = String(decoding: payload, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - 缓存刷新

    /// 缓存复用时不能直接返回旧值：窗口可能刚好重置，剩余量要按当前时间重算
    private static func refreshClock(_ snapshot: UsageSnapshot, at now: Date) -> UsageSnapshot {
        func recompute(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            let expired = window.resetAt.map { $0 <= now } ?? false
            return UsageWindow(remaining: expired ? 100 : min(100, max(0, 100 - window.used)),
                               used: window.used,
                               resetAt: window.resetAt,
                               windowMinutes: window.windowMinutes,
                               expired: expired)
        }
        return UsageSnapshot(fiveHour: recompute(snapshot.fiveHour),
                             weekly: recompute(snapshot.weekly),
                             sourceFile: snapshot.sourceFile,
                             recordTime: snapshot.recordTime,
                             loadedAt: now,
                             error: snapshot.error)
    }

    // MARK: - 解析

    private static func blank(at date: Date, error: String) -> UsageSnapshot {
        UsageSnapshot(fiveHour: nil, weekly: nil, sourceFile: nil,
                      recordTime: nil, loadedAt: date, error: error)
    }

    /// 该窗口是否带真实数值（额度耗尽时 Codex 会写 null）
    private static func usable(_ raw: Any?) -> Bool {
        guard let dict = raw as? [String: Any] else { return false }
        return number(dict["used_percent"]) != nil
    }

    private static func window(_ raw: Any?, recordedAt: Date) -> UsageWindow? {
        guard let dict = raw as? [String: Any], let used = number(dict["used_percent"]) else { return nil }

        let minutes = Int(number(dict["window_minutes"]) ?? 0)

        var reset: Date?
        if let epoch = number(dict["resets_at"]), epoch > 0 {
            reset = Date(timeIntervalSince1970: epoch)
        } else if minutes > 0 {
            reset = recordedAt.addingTimeInterval(Double(minutes) * 60)
        }

        let expired = reset.map { $0 <= Date() } ?? false
        let remaining = expired ? 100.0 : min(100, max(0, 100 - used))

        return UsageWindow(remaining: remaining,
                           used: used,
                           resetAt: reset,
                           windowMinutes: minutes,
                           expired: expired)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
