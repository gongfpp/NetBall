// NetBall — 常驻置顶的实时流量悬浮球（macOS 原生，AppKit + nettop）
//
// 设计目标：低资源占用
//   · 按间隔运行 nettop 单发快照并差分，不保留长驻流式进程
//   · 无 CoreAnimation 图层；只在采样时重绘，弧线 0.4s 缓动期间跑 20fps，收敛即停
//   · 自报资源占用（自身 CPU / 内存直接显示在面板上）
//
// 用法：
//   NetBall                                  常驻悬浮球
//   NetBall --benchmark 20                   跑 20 秒后打印资源占用并退出
//   NetBall --snapshot out.png [--demo|--ball]  将界面渲染为 PNG（自检用）

import AppKit
import Darwin
import Foundation

// MARK: - 数值格式化

private enum Fmt {
    /// 速率：自适应 B/s → KB/s → MB/s → GB/s
    static func rate(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / 1048576) }
        return String(format: "%.2f GB/s", bps / 1073741824)
    }

    /// 悬浮球上的紧凑写法
    static func compact(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0fB", bps) }
        if bps < 1024 * 1024 { return String(format: "%.0fK", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1fM", bps / 1048576) }
        return String(format: "%.2fG", bps / 1073741824)
    }

    /// 菜单栏标题专用：**最多 5 个字符**（含单位），避免图标宽度随数字跳动、也避免被裁掉。
    /// 例如 0.0K / 15.5K / 155K / 999.9K→1000K / 1.2M / 155M
    static func tray(_ bps: Double) -> String {
        let v: Double
        let unit: String
        if bps >= 1073741824 { v = bps / 1073741824; unit = "G" }
        else if bps >= 1048576 { v = bps / 1048576; unit = "M" }
        else { v = bps / 1024; unit = "K" }
        let capped = min(v, 999.9)
        // 三位整数 + 小数点会变成 6 个字符，所以 ≥100 时去掉小数
        return capped < 100 ? String(format: "%.1f%@", capped, unit)
                            : String(format: "%.0f%@", capped, unit)
    }

    /// 拆成「数值 + 单位」，给大字号排版用
    static func split(_ bps: Double) -> (value: String, unit: String) {
        if bps >= 1073741824 { return (String(format: "%.2f", bps / 1073741824), "GB/s") }
        if bps >= 1048576 { return (String(format: "%.1f", bps / 1048576), "MB/s") }
        if bps >= 1024 { return (String(format: "%.0f", bps / 1024), "KB/s") }
        return (String(format: "%.0f", bps), "B/s")
    }

    /// 累计流量：自适应 B → KB → MB → GB → TB（不带 /s）
    static func bytes(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v >= 1099511627776 { return String(format: "%.2f TB", v / 1099511627776) }
        if v >= 1073741824 { return String(format: "%.2f GB", v / 1073741824) }
        if v >= 1048576 { return String(format: "%.1f MB", v / 1048576) }
        if v >= 1024 { return String(format: "%.1f KB", v / 1024) }
        return "\(bytes) B"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分\((s % 60))秒" }
        return "\(s)秒"
    }

    static func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1048576) }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }
}

// MARK: - 进程资源占用（proc_pid_rusage，单位换算用 mach timebase）

private let timebase: (numer: Double, denom: Double) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (Double(tb.numer), Double(tb.denom))
}()

private func rusageV6(_ pid: pid_t) -> rusage_info_v6? {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
            proc_pid_rusage(pid, RUSAGE_INFO_V6, rp)
        }
    }
    return rc == 0 ? info : nil
}

/// 进程累计 CPU 秒数
private func cpuSeconds(_ pid: pid_t) -> Double? {
    guard let i = rusageV6(pid) else { return nil }
    let ticks = Double(i.ri_user_time + i.ri_system_time)
    return ticks * timebase.numer / timebase.denom / 1e9
}

/// 进程物理内存占用（phys_footprint，比 RSS 更贴近真实开销）
private func footprintBytes(_ pid: pid_t) -> UInt64 {
    rusageV6(pid)?.ri_phys_footprint ?? 0
}

// MARK: - 采样器
//
// 为什么不用 `nettop -l 0` 长驻流式：实测它在两次采样之间忙等，持续吃掉 1.0~1.4 个核
// （见 tools/nettop-cost.swift）。单次快照 `nettop -l 1` 只要 ~0.018s CPU / ~0.14s wall，
// 所以这里改成"按间隔跑一次单发快照 + 与上一次做差分"，开销降到 ~1~2%。

final class Sampler {
    struct Row {
        let name: String
        let pid: Int
        let rx: Double  // bytes/s 下行
        let tx: Double  // bytes/s 上行
        /// 这条流量是经代理出去的（ProxyProbe 打标）
        var viaProxy = false
        var total: Double { rx + tx }
    }

    struct ProcessTotal {
        let name: String
        var rxBytes: UInt64
        var txBytes: UInt64
        var viaProxy: Bool
        var totalBytes: UInt64 { rxBytes &+ txBytes }
    }

    struct StatisticsSortState {
        enum Column: Equatable { case download, upload }
        private(set) var column: Column = .download
        private(set) var ascending = false

        mutating func click(_ newColumn: Column) {
            if column == newColumn {
                ascending.toggle()
            } else {
                column = newColumn
                ascending = false
            }
        }
    }

    struct PeriodStatistics {
        let since: Date
        let rxBytes: UInt64
        let txBytes: UInt64
        let processes: [ProcessTotal]

        func sortedProcesses(byUpload: Bool, ascending: Bool = false) -> [ProcessTotal] {
            processes.sorted { a, b in
                let primaryA = byUpload ? a.txBytes : a.rxBytes
                let primaryB = byUpload ? b.txBytes : b.rxBytes
                if primaryA != primaryB { return ascending ? primaryA < primaryB : primaryA > primaryB }
                let secondaryA = byUpload ? a.rxBytes : a.txBytes
                let secondaryB = byUpload ? b.rxBytes : b.txBytes
                if secondaryA != secondaryB { return secondaryA > secondaryB }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// 累计器按进程名汇总：同名的多个 PID（如 Chrome Helper）归并为一行
    struct PeriodAccumulator {
        private(set) var since = Date()
        private(set) var rxBytes: UInt64 = 0
        private(set) var txBytes: UInt64 = 0
        private var byName: [String: ProcessTotal] = [:]

        mutating func add(name: String, rx: UInt64, tx: UInt64, viaProxy: Bool) {
            rxBytes &+= rx
            txBytes &+= tx
            var p = byName[name] ?? ProcessTotal(name: name, rxBytes: 0, txBytes: 0, viaProxy: false)
            p.rxBytes &+= rx
            p.txBytes &+= tx
            p.viaProxy = p.viaProxy || viaProxy
            byName[name] = p
        }

        mutating func reset(at date: Date = Date()) {
            since = date
            rxBytes = 0
            txBytes = 0
            byName.removeAll(keepingCapacity: true)
        }

        func snapshot() -> PeriodStatistics {
            let rows = byName.values.sorted {
                $0.totalBytes == $1.totalBytes ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                               : $0.totalBytes > $1.totalBytes
            }
            return PeriodStatistics(since: since, rxBytes: rxBytes, txBytes: txBytes, processes: rows)
        }
    }

    /// 回调：实时排行 / 速率 / 进程数 + 自启动或重置以来的累计统计
    var onSnapshot: (([Row], Double, Double, Int, PeriodStatistics) -> Void)?
    var deliverQueue = DispatchQueue.main

    private(set) var paused = false
    /// 当前生效的采样间隔（展开面板时用更快的 activeInterval）
    private(set) var interval: Double = 2.0
    private var active = false
    /// 空闲（收起成球）时的间隔
    var idleInterval: Double = 2.0
    /// 展开面板时的间隔
    var activeInterval: Double = 1.0

    private let queue = DispatchQueue(label: "netball.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var prev: [String: (UInt64, UInt64)] = [:]
    private var lastTick = Date()
    private var inFlight = false
    private var periodAccumulator = PeriodAccumulator()

    /// 读取当前统计（与采样队列串行，避免跨线程读写竞态）
    func currentPeriodStatistics() -> PeriodStatistics {
        queue.sync { periodAccumulator.snapshot() }
    }

    /// 从此刻重新开始统计；清空基线，避免把重置前最后一个采样间隔算进来
    @discardableResult
    func resetPeriodStatistics() -> PeriodStatistics {
        queue.sync {
            periodAccumulator.reset()
            prev.removeAll(keepingCapacity: true)
            lastTick = Date()
            return periodAccumulator.snapshot()
        }
    }

    /// 代理穿透（剔除代理核心 + 给走代理的行打标）
    let proxy = ProxyProbe()
    /// 自检用：临时关掉代理核心剔除，做 A/B 对照
    var keepProxyCore = false
    /// 最近一次采样里"不剔除代理核心"的原始总量（同一份数据，可直接对比）
    private(set) var lastRawTotals: (rx: Double, tx: Double) = (0, 0)

    // 子进程开销统计（nettop 是一次性的短命进程）
    private var childCPUBase = 0.0
    private(set) var childCPUSeconds = 0.0
    private(set) var childPeakFootprint: UInt64 = 0
    private(set) var shots = 0

    func start() {
        paused = false
        schedule(immediate: true)
    }

    func stop() {
        paused = true
        timer?.cancel()
        timer = nil
    }

    func resume() { if paused { start() } }

    /// 面板展开/收起时切换采样频率
    func setActive(_ a: Bool) {
        active = a
        applyInterval(a ? activeInterval : idleInterval)
    }

    /// 调整空闲档频率（只有当前确实处于空闲档才立即生效）
    func setIdleInterval(_ v: Double) {
        idleInterval = v
        guard !active else { return }
        applyInterval(v)
    }

    /// 同时设定两档频率（基准测试用）
    func setIntervals(idle: Double, active activeV: Double) {
        idleInterval = idle
        activeInterval = activeV
        applyInterval(active ? activeV : idle)
    }

    private func applyInterval(_ target: Double) {
        guard abs(target - interval) > 0.001 else { return }
        interval = target
        if !paused { schedule(immediate: false) }
    }

    private func schedule(immediate: Bool) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // leeway 让系统把唤醒合并到其他定时器上，省电
        t.schedule(deadline: .now() + (immediate ? 0.3 : interval),
                   repeating: interval,
                   leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let cpuBefore = Self.reapedChildrenCPU()
        guard let text = shot() else { return }
        childCPUSeconds += max(0, Self.reapedChildrenCPU() - cpuBefore)
        shots += 1

        var cur: [String: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            if line.contains("bytes_in") { continue }
            guard let parsed = Sampler.parse(String(line)) else { continue }
            cur[parsed.key] = (parsed.rx, parsed.tx)
        }
        guard !cur.isEmpty else { return }

        let now = Date()
        guard !prev.isEmpty else {          // 第一次只做基线
            prev = cur
            lastTick = now
            return
        }
        let dt = max(0.2, now.timeIntervalSince(lastTick))
        lastTick = now

        var rows: [Row] = []
        var totRx = 0.0
        var totTx = 0.0
        var rawRx = 0.0
        var rawTx = 0.0

        // 代理穿透：先决定哪些是代理核心，再统计 —— 核心承载的是别人的流量，
        // 回环那一段还被重复记过，算进总量会让球/菜单栏的数字虚高 2~3 倍。
        proxy.refreshCoreIfNeeded()
        if active { proxy.refreshProxiedIfNeeded() }
        let core = proxy.corePIDs
        let proxied = proxy.proxiedPIDs
        var counted = 0

        for (key, v) in cur {
            guard let p = prev[key] else { continue }   // 新进程不上报第一秒的跳变
            let dRxBytes = v.0 >= p.0 ? v.0 - p.0 : 0
            let dTxBytes = v.1 >= p.1 ? v.1 - p.1 : 0
            guard dRxBytes > 0 || dTxBytes > 0 else { continue }
            guard let dot = key.lastIndex(of: "."), let pid = Int(key[key.index(after: dot)...]) else { continue }
            let name = String(key[..<dot])
            let dRx = Double(dRxBytes)
            let dTx = Double(dTxBytes)
            rawRx += dRx / dt                        // 不剔除的原始总量（自检对照用）
            rawTx += dTx / dt
            guard keepProxyCore || !core.contains(pid) else { continue }
            totRx += dRx / dt
            totTx += dTx / dt
            periodAccumulator.add(name: name, rx: dRxBytes, tx: dTxBytes, viaProxy: proxied.contains(pid))
            counted += 1
            rows.append(Row(name: name, pid: pid, rx: dRx / dt, tx: dTx / dt,
                            viaProxy: proxied.contains(pid)))
        }
        lastRawTotals = (rawRx, rawTx)
        prev = cur
        rows.sort { $0.total > $1.total }

        let r = rows, rx = totRx, tx = totTx, n = counted
        let period = periodAccumulator.snapshot()
        deliverQueue.async { [weak self] in
            guard let self else { return }
            // 和回调写在同一个队列上：自检里读它就一定是当前这一份，不会读到半新半旧
            self.lastRawTotals = (rawRx, rawTx)
            self.onSnapshot?(r, rx, tx, n, period)
        }
    }

    /// 跑一次单发快照；`nettop -l 1` 是"打印一份就退出"
    private func shot() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-n", "-l", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        // 趁它还活着记录内存占用：刚 spawn 完内核还没准备好 rusage，等 50ms 再读
        let pid = p.processIdentifier
        var foot: UInt64 = 0
        for attempt in 0..<4 {
            if attempt > 0 { usleep(20_000) }
            foot = footprintBytes(pid)
            if foot > 0 { break }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if foot > 0 { childPeakFootprint = max(childPeakFootprint, foot) }
        return String(data: data, encoding: .utf8)
    }

    /// 已回收子进程的累计 CPU 秒数（用于统计 nettop 的真实开销）
    private static func reapedChildrenCPU() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_CHILDREN, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
             + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    /// "Name with spaces.1234                                123  456"
    private static func parse(_ line: String) -> (key: String, rx: UInt64, tx: UInt64)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let tx = UInt64(parts[parts.count - 1]),
              let rx = UInt64(parts[parts.count - 2]) else { return nil }
        return (parts[0..<(parts.count - 2)].joined(separator: " "), rx, tx)
    }
}

// MARK: - 代理穿透（mihomo / Clash Verge）

/// 跑个短命子进程拿输出（nettop / lsof / curl 都走这里，不引入额外依赖）
private func runTool(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// 用了代理之后，nettop 里会出现一个虚高的代理核心，把真实应用全压下去。
/// 两个原因叠加：① TUN 模式下出站 socket 属于代理核心；② 混合端口的回环那一段
/// 应用和代理核心各持一端，nettop 两边都算 —— 同一个字节最多被记三次。
///
/// 但**归因本身是对的**：实测直连下载 6,160,348 字节（走 TUN），nettop 给 curl 记的是
/// 6,216,458；走混合端口下载 9,000,000 字节，nettop 给 curl 记 9,034,418。
/// 所以只要把代理核心从排行里剔掉，排行和总量就都恢复成真实值了，不需要"搬"流量。
///
/// 剩下的活是打标：问 mihomo 要连接表，把 sourcePort 用 lsof 映射回进程，
/// 就知道哪些应用是走代理出去的，给它们标个「代理」。
///
/// 代价：lsof 一次约 0.02s CPU，所以只在**面板展开时**跑，而且节流到 5s 一次；
/// 核心 PID 只在启动和每 60s 复核一次。
final class ProxyProbe {
    /// 代理核心进程 PID（从排行和总量里剔除）
    private(set) var corePIDs: Set<Int> = []
    /// 最近一次探测里"走了代理"的进程 PID（打标用）
    private(set) var proxiedPIDs: Set<Int> = []
    /// 命中过的控制器端点，nil = 这台机器上没有可识别的代理
    private(set) var endpointDesc: String?
    /// 面板没展开时也想知道总量是否被代理污染，所以核心探测与展开状态无关
    private(set) var lastCoreScan = Date.distantPast
    private var lastProxiedScan = Date.distantPast
    private var lastSuccess = Date.distantPast

    private var endpoint: (args: [String], base: String)?
    private var lastDiscoverAttempt = Date.distantPast

    /// 没找到控制器时的兜底：按进程名剔除已知的代理核心
    private static let coreNameHints = ["verge-mihomo", "mihomo", "clash-meta", "clash-meta-alpha",
                                        "sing-box", "xray", "v2ray", "hysteria", "tuic"]

    // MARK: 对外

    /// 剔除代理核心 + 打标；返回 (过滤后的行, 是否命中过代理)
    func apply(to rows: [Sampler.Row]) -> [Sampler.Row] {
        guard !corePIDs.isEmpty || !proxiedPIDs.isEmpty else { return rows }
        return rows.compactMap { r in
            if corePIDs.contains(r.pid) { return nil }
            var m = r
            m.viaProxy = proxiedPIDs.contains(r.pid)
            return m
        }
    }

    /// 核心 PID：启动时 + 每 60s 复核（一次 lsof，约 0.02s）
    func refreshCoreIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCoreScan) > 60 else { return }
        lastCoreScan = now
        if let found = scanCore() {
            corePIDs = found
            lastSuccess = now
        } else if now.timeIntervalSince(lastSuccess) > 30 {
            // 代理已经退出了：清掉，免得 PID 复用后误伤别的进程
            corePIDs = []
            proxiedPIDs = []
        }
    }

    /// 走了代理的进程：只在面板展开时跑，节流 5s
    func refreshProxiedIfNeeded(interval: TimeInterval = 5) {
        let now = Date()
        guard now.timeIntervalSince(lastProxiedScan) >= interval else { return }
        lastProxiedScan = now
        guard discoverEndpoint() != nil else { return }

        // 一次 lsof 同时拿到 端口→PID（ESTABLISHED）和 监听端口→PID（LISTEN）
        guard let lsof = runTool("/usr/sbin/lsof", ["-nP", "-iTCP"]) else { return }
        var portToPID: [String: Int] = [:]
        for line in lsof.split(separator: "\n") {
            guard let e = Self.parseLsof(String(line)), !e.listening else { continue }
            portToPID[e.port] = e.pid
        }

        guard let data = api("/connections"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conns = obj["connections"] as? [[String: Any]] else { return }

        var hit: Set<Int> = []
        for c in conns {
            let m = c["metadata"] as? [String: Any] ?? [:]
            // 优先用 mihomo 自己填的进程名（find-process-mode: always 时才有），
            // 但拿不到 PID，所以主要还是靠 sourcePort 反查
            if let port = m["sourcePort"] as? String, let pid = portToPID[port] {
                hit.insert(pid)
            }
        }
        proxiedPIDs = hit
        lastSuccess = Date()
    }

    // MARK: 内部

    /// 找到代理核心进程。
    /// 名字这条路是主力：Clash Verge 用 root 服务模式跑 mihomo，普通用户既看不到它的
    /// socket（lsof 无输出）、ps 也可能被限制，只有 pgrep 能稳定拿到 PID。
    /// 监听端口那条路是补充：代理以当前用户身份跑时才有效，能兜住名字不在清单里的核心。
    private func scanCore() -> Set<Int>? {
        var pids = scanCoreByName() ?? []
        if discoverEndpoint() != nil,
           let data = api("/configs"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ports = ["mixed-port", "port", "socks-port"]
                .compactMap { obj[$0] as? Int }
                .filter { $0 > 0 }
            if !ports.isEmpty,
               let lsof = runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]) {
                for line in lsof.split(separator: "\n") {
                    guard let e = Self.parseLsof(String(line)), e.listening,
                          ports.contains(Int(e.port) ?? -1) else { continue }
                    pids.insert(e.pid)
                }
            }
        }
        return pids.isEmpty ? nil : pids
    }

    /// 按名字找代理核心（pgrep -x 匹配的是 comm 的 basename）
    private func scanCoreByName() -> Set<Int>? {
        var pids: Set<Int> = []
        for name in Self.coreNameHints {
            guard let out = runTool("/usr/bin/pgrep", ["-x", name]) else { continue }
            for line in out.split(separator: "\n") {
                if let pid = Int(line.trimmingCharacters(in: .whitespaces)) { pids.insert(pid) }
            }
        }
        return pids.isEmpty ? nil : pids
    }

    /// 控制器端点：Clash Verge 服务模式是 unix socket，裸 mihomo 一般是 9090
    @discardableResult
    private func discoverEndpoint() -> (args: [String], base: String)? {
        if let e = endpoint { return e }
        // 没代理的机器上别每 5 秒白试一遍：失败也缓存 60 秒
        guard Date().timeIntervalSince(lastDiscoverAttempt) > 60 else { return nil }
        lastDiscoverAttempt = Date()
        let uid = getuid()
        var candidates: [(args: [String], base: String)] = [
            (["--unix-socket", "/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock"],
             "http://localhost"),
            (["--unix-socket", "/tmp/clash-verge-service/users/\(uid)/verge-mihomo.sock"],
             "http://localhost"),
            ([], "http://127.0.0.1:9090"),
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            candidates.insert((["--unix-socket",
                                "\(home)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock"],
                               "http://localhost"), at: 2)
        }
        for c in candidates {
            guard let out = runTool("/usr/bin/curl",
                                     c.args + ["-s", "--max-time", "2", c.base + "/version"]),
                  out.contains("version") else { continue }
            endpoint = c
            endpointDesc = c.args.isEmpty ? c.base : c.args.last!
            return c
        }
        return nil
    }

    private func api(_ path: String) -> Data? {
        guard let e = endpoint else { return nil }
        guard let out = runTool("/usr/bin/curl",
                                 e.args + ["-s", "--max-time", "3", e.base + path]) else { return nil }
        return out.data(using: .utf8)
    }

    /// lsof -nP -iTCP 的一行 → (pid, 本地端口, 是不是 LISTEN)
    /// 例：`verge-mih  1244 mass   22u  IPv4 ... TCP *:7897 (LISTEN)`
    ///     `Google     45565 mass  45u  IPv4 ... TCP 127.0.0.1:58705->127.0.0.1:7897 (ESTABLISHED)`
    static func parseLsof(_ line: String) -> (pid: Int, port: String, listening: Bool)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 9, let pid = Int(f[1]) else { return nil }
        guard let name = f.last(where: { $0.contains(":") && !$0.hasPrefix("(") }) else { return nil }
        let local = name.contains("->") ? String(name[..<name.range(of: "->")!.lowerBound]) : name
        guard let colon = local.lastIndex(of: ":") else { return nil }
        let port = String(local[local.index(after: colon)...])
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
        return (pid, port, line.contains("(LISTEN)"))
    }
}

// MARK: - 配色

private enum Palette {
    static let cyan = NSColor(srgbRed: 0.31, green: 0.76, blue: 0.97, alpha: 1)
    static let amber = NSColor(srgbRed: 1.00, green: 0.77, blue: 0.42, alpha: 1)
    static let text = NSColor(white: 0.96, alpha: 1)
    static let dim = NSColor(srgbRed: 0.58, green: 0.66, blue: 0.74, alpha: 1)
    static let panel = NSColor(srgbRed: 0.055, green: 0.078, blue: 0.106, alpha: 0.93)
    static let ball = NSColor(srgbRed: 0.13, green: 0.42, blue: 0.80, alpha: 0.95)
    static let ballHi = NSColor(srgbRed: 0.36, green: 0.68, blue: 0.98, alpha: 0.95)
    // 360 经典球的绿色球体（亮 → 中 → 暗）
    static let greenHi = NSColor(srgbRed: 0.72, green: 0.93, blue: 0.34, alpha: 1)
    static let greenMid = NSColor(srgbRed: 0.33, green: 0.72, blue: 0.13, alpha: 1)
    static let greenLo = NSColor(srgbRed: 0.08, green: 0.33, blue: 0.05, alpha: 1)
    static let glassBG = NSColor(srgbRed: 0.055, green: 0.078, blue: 0.106, alpha: 1)
    static let bezelTop = NSColor(white: 1.00, alpha: 1)
    static let bezelBottom = NSColor(white: 0.76, alpha: 1)
    static let iconColors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.80, blue: 0.44, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.65, alpha: 1),
    ]
}

private enum Metrics {
    static let ball: CGFloat = 140
    static let panelW: CGFloat = 368
    static let panelH: CGFloat = 436
    static let pad: CGFloat = 18
}

private enum Align { case left, center, right }

/// 稳定的名称哈希：进程颜色在每次启动间保持一致（Swift 的 hashValue 每次进程都会变）
private func stableHash(_ s: String) -> Int {
    var h = 5381
    for b in s.utf8 { h = (h &* 33) &+ Int(b) }
    return abs(h)
}

// MARK: - 悬浮球样式

enum BallStyle: String, CaseIterable {
    case glass   // 毛玻璃球
    case pill    // 曲线胶囊

    var label: String {
        switch self {
        case .glass: return "毛玻璃球"
        case .pill: return "曲线胶囊"
        }
    }

    /// 收起态窗口尺寸（含给阴影/发光留的边距）
    var collapsedSize: NSSize {
        switch self {
        case .glass: return NSSize(width: 140, height: 140)
        case .pill: return NSSize(width: 200, height: 72)
        }
    }

    static func load() -> BallStyle {
        if let s = UserDefaults.standard.string(forKey: "NetBall.ballStyle"),
           let v = BallStyle(rawValue: s) { return v }
        return .glass
    }
}

// MARK: - 菜单栏样式

enum TrayStyle: String, CaseIterable {
    case stackSmall   // 上下两行 · 小
    case stackLarge   // 上下两行 · 大（两行的极限字号）
    case rowMedium    // 横排一行 · 中
    case rowLarge     // 横排一行 · 大
    case downOnly     // 只看下行
    case upOnly       // 只看上行
    case totalOnly    // 只看总速率

    var stacked: Bool { self == .stackSmall || self == .stackLarge }

    var fontSize: CGFloat {
        switch self {
        case .stackSmall: return 8
        case .stackLarge: return 9.5
        case .rowMedium: return 10
        case .rowLarge, .downOnly, .upOnly, .totalOnly: return 12
        }
    }

    var label: String {
        switch self {
        case .stackSmall: return "上下两行 · 小"
        case .stackLarge: return "上下两行 · 大（推荐）"
        case .rowMedium: return "横排一行 · 中"
        case .rowLarge: return "横排一行 · 大"
        case .downOnly: return "只看下行 ↓"
        case .upOnly: return "只看上行 ↑"
        case .totalOnly: return "只看总速率 ↕"
        }
    }

    func lines(down: String, up: String, total: String) -> [String] {
        switch self {
        case .stackSmall, .stackLarge: return ["↓\(down)", "↑\(up)"]
        case .rowMedium, .rowLarge: return ["↓\(down) ↑\(up)"]
        case .downOnly: return ["↓\(down)"]
        case .upOnly: return ["↑\(up)"]
        case .totalOnly: return ["↕\(total)"]
        }
    }

    static func load() -> TrayStyle {
        if let s = UserDefaults.standard.string(forKey: "NetBall.trayStyle"),
           let v = TrayStyle(rawValue: s) { return v }
        return .stackLarge
    }
}

/// 菜单栏图标：按选定样式自绘。宽度用模板值算，数字变化时图标不会左右抖。
private func trayIconImage(style: TrayStyle, lines: [String],
                           color: NSColor = .black, template: Bool = true) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let strs = lines.map { NSAttributedString(string: $0, attributes: attrs) }

    // 数值永远是 5 个字符（如 1.2M），用模板值定宽，数字变化不会让图标左右抖
    let tpl = style.lines(down: "0.0M", up: "0.0M", total: "0.0M")
        .map { NSAttributedString(string: $0, attributes: attrs) }
    // 宽度 = max(模板宽度, 实际文本宽度)，即使格式意外变长也不会被裁掉
    let tplW = tpl.map { $0.size().width }.max() ?? 10
    let realW = strs.map { $0.size().width }.max() ?? 0
    let width = ceil(max(tplW, realW)) + 2
    let lineH = ceil(tpl[0].size().height)
    // 两行用比字体自带行距更紧的步进，总高压在 20pt 以内（菜单栏按钮约 22pt）
    let step = style.stacked ? round(style.fontSize * 1.08) : 0
    let height = style.stacked ? min(step + lineH, 20) : lineH

    let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
        for (i, str) in strs.enumerated() {
            str.draw(at: NSPoint(x: 1, y: style.stacked ? CGFloat(i) * step : 0))
        }
        return true
    }
    img.isTemplate = template
    return img
}

// MARK: - 显示模式

enum DisplayMode: String {
    case tray   // 只要菜单栏
    case ball   // 只要悬浮球
    case both   // 两个都要

    var showsTray: Bool { self != .ball }
    var showsBall: Bool { self != .tray }

    var label: String {
        switch self {
        case .tray: return "菜单栏（不显示悬浮球）"
        case .ball: return "悬浮球"
        case .both: return "菜单栏 + 悬浮球"
        }
    }

    static func load() -> DisplayMode {
        if let s = UserDefaults.standard.string(forKey: "NetBall.mode"),
           let m = DisplayMode(rawValue: s) { return m }
        return .tray
    }
}

// MARK: - 视图：球 / 面板 全部手绘

final class BallView: NSView {
    weak var controller: Controller?

    var expanded = false
    var rows: [Sampler.Row] = []
    var totalRx = 0.0
    var totalTx = 0.0
    var procCount = 0
    var history: [(rx: Double, tx: Double)] = []
    var showPeriodStatistics = false
    var periodStatistics = Sampler.PeriodStatistics(since: Date(), rxBytes: 0, txBytes: 0, processes: [])
    var statisticsScrollOffset = 0
    private var statisticsSort = Sampler.StatisticsSortState()
    var selfCPU = 0.0
    var selfMemMB = 0.0
    var nettopCPU = 0.0
    var ballStyle: BallStyle = .glass
    /// 背景不透明度：越高越实（0.6~1.0）
    var fillAlpha: CGFloat = 0.85

    // 弧线缓动与峰值
    /// 缓动时长：0.4s。按"经过时间"取进度，定时器抖动不会改变手感
    static let arcEaseSeconds: TimeInterval = 0.4
    private(set) var shownRxLevel: CGFloat = 0
    private(set) var shownTxLevel: CGFloat = 0
    private var targetRxLevel: CGFloat = 0
    private var targetTxLevel: CGFloat = 0
    private var easeFromRx: CGFloat = 0
    private var easeFromTx: CGFloat = 0
    private var easeStart = Date.distantPast
    private var easing = false
    /// 缓动取时间用的时钟。自检（--ease-test）时换成假时钟，才能跑出确定的帧序列
    var clock: () -> Date = Date.init
    private(set) var peakRxLevel: CGFloat = 0
    private(set) var peakTxLevel: CGFloat = 0
    var paused = false
    var intervalLabel = "1s"
    var snapshotBackdrop = false
    var snapshotWhite = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 绘制入口

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        if snapshotBackdrop { drawBackdrop() }
        if expanded { drawPanel() } else { drawBall() }
    }

    /// 实际发生的重绘次数（--benchmark 用来自证"20fps 重绘"真的跑了，而不是被系统跳过）
    private(set) var drawCount = 0

    private func drawBackdrop() {
        if snapshotWhite {
            NSColor(white: 0.96, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let g = NSGradient(colors: [
            NSColor(srgbRed: 0.09, green: 0.15, blue: 0.21, alpha: 1),
            NSColor(srgbRed: 0.04, green: 0.07, blue: 0.10, alpha: 1),
        ])
        g?.draw(in: bounds, angle: -60)
    }

    // MARK: 收起态：悬浮球

    private func drawBall() {
        switch ballStyle {
        case .glass:
            drawGlassBall(center: NSPoint(x: bounds.midX, y: bounds.midY),
                          r: min(bounds.width, bounds.height) / 2 - 8)
        case .pill:
            drawPillBall(rect: bounds.insetBy(dx: 8, dy: 8))
        }
    }

    /// 柔和光斑：多层同心椭圆叠加（比径向渐变稳，不会有奇点或硬边）
    private func softBlob(center: NSPoint, radius: CGFloat, aspect: CGFloat,
                          color: NSColor, steps: Int = 30, peak: CGFloat) {
        for i in stride(from: steps, through: 1, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            let a = peak * pow(1 - t, 2.0)
            if a < 0.004 { continue }
            let rr = radius * t
            color.withAlphaComponent(a).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - rr, y: center.y - rr * aspect,
                                        width: rr * 2, height: rr * 2 * aspect)).fill()
        }
    }

    /// 收到新速率：更新总量并设定弧线目标值（显示值由 0.4s 缓动逼近）
    func updateRates(rx: Double, tx: Double) {
        totalRx = rx
        totalTx = tx
        let nrx = paused ? 0 : arcLevel(rx)
        let ntx = paused ? 0 : arcLevel(tx)
        // 变化小到看不出来就别开动画，直接对齐
        guard abs(nrx - shownRxLevel) > 0.005 || abs(ntx - shownTxLevel) > 0.005 else {
            targetRxLevel = nrx
            targetTxLevel = ntx
            shownRxLevel = nrx
            shownTxLevel = ntx
            easing = false
            return
        }
        // 从"当前显示值"起步：上一段缓动没跑完又来新采样时，接上去而不是回跳
        easeFromRx = shownRxLevel
        easeFromTx = shownTxLevel
        easeStart = clock()
        targetRxLevel = nrx
        targetTxLevel = ntx
        easing = true
    }

    /// 峰值：最近 60 次采样里的最高档位
    func recomputePeaks() {
        peakRxLevel = history.map { arcLevel($0.rx) }.max() ?? 0
        peakTxLevel = history.map { arcLevel($0.tx) }.max() ?? 0
    }

    /// 有缓动在跑吗——控制器据此决定要不要开 20fps 定时器（收敛即停，不做无谓重绘）
    func needsAnimation() -> Bool { easing }

    /// 缓动一帧：ease-out cubic（快起缓收），进度只取决于经过时间；true = 已收敛可停表
    func stepAnimation() -> Bool {
        let elapsed = clock().timeIntervalSince(easeStart)
        let t = min(1, elapsed / BallView.arcEaseSeconds)
        let k = CGFloat(1 - pow(1 - t, 3))
        shownRxLevel = easeFromRx + (targetRxLevel - easeFromRx) * k
        shownTxLevel = easeFromTx + (targetTxLevel - easeFromTx) * k
        // 1µs 容差：Date 是 7.8e8 量级的浮点数，累加几次 50ms 就会差一丁点，
        // 否则"正好到点"的那一帧判定不成收敛，白跑一帧重绘
        guard elapsed >= BallView.arcEaseSeconds - 1e-6 else { return false }
        shownRxLevel = targetRxLevel
        shownTxLevel = targetTxLevel
        easing = false
        return true
    }

    /// 直接跳到目标值（自检出图 / 切换样式时用）
    func settleAnimation() {
        shownRxLevel = targetRxLevel
        shownTxLevel = targetTxLevel
        easing = false
    }

    /// 速率 → 弧长（对数映射：1KB/s≈0，1MB/s≈0.6，100MB/s≈1）
    private func arcLevel(_ bps: Double) -> CGFloat {
        guard bps > 1 else { return 0 }
        return CGFloat(min(1, max(0, (log10(bps) - 3) / 5)))
    }

    /// 弧形仪表：淡色轨道 + 按 level 伸缩的进度弧
    private func drawArcGauge(center c: NSPoint, radius: CGFloat, start: CGFloat, span: CGFloat,
                              width: CGFloat, level: CGFloat, peak: CGFloat, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: start, endAngle: start + span,
                        clockwise: false)
        track.lineWidth = width
        track.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.13).setStroke()
        track.stroke()

        let lv = min(max(level, 0), 1)
        if lv > 0.02 {
            let fill = NSBezierPath()
            fill.appendArc(withCenter: c, radius: radius, startAngle: start, endAngle: start + span * lv,
                           clockwise: false)
            fill.lineWidth = width
            fill.lineCapStyle = .round
            color.setStroke()
            fill.stroke()
        }

        // 峰值刻度：最近 60 次采样里的最高点。
        // 特意画在进度弧之外——当前值回落到 0 时也要留个痕，否则看不出"刚才飙到过多少"。
        let pk = min(max(peak, 0), 1)
        if pk > 0.02 {
            let a = (start + span * pk) * .pi / 180
            let p = NSPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
            NSColor(white: 1, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 4.2, y: p.y - 4.2, width: 8.4, height: 8.4)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)).fill()
        }
    }

    private var glassCache: NSImage?
    private var glassCacheKey = ""
    private var textCache: NSImage?
    private var textCacheKey = ""

    /// 毛玻璃球的静态部分（底色 + 白纱 + 磨砂颗粒 + 外圈）只画一次并缓存成位图，
    /// 动画每帧只重画两条弧和文字——否则 20fps 重画 300 个颗粒太贵。
    private func glassBackground(d: CGFloat, r: CGFloat) -> NSImage {
        let key = "\(Int(d))-\(Int(r))-\(Int(fillAlpha * 100))"
        if key == glassCacheKey, let img = glassCache { return img }

        let img = NSImage(size: NSSize(width: d, height: d), flipped: true) { _ in
            let c = NSPoint(x: d / 2, y: d / 2)

            Palette.glassBG.withAlphaComponent(self.fillAlpha).setFill()
            self.circlePath(c, r).fill()

            // 顶部白纱
            NSGraphicsContext.saveGraphicsState()
            self.circlePath(c, r).addClip()
            NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))?
                .draw(from: NSPoint(x: c.x, y: c.y - r), to: NSPoint(x: c.x, y: c.y + r * 0.2), options: [])
            NSGraphicsContext.restoreGraphicsState()

            // 磨砂颗粒（固定种子）
            NSGraphicsContext.saveGraphicsState()
            self.circlePath(c, r - 2).addClip()
            var seed: UInt64 = 20261013
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 1000) / 1000
            }
            for _ in 0..<300 {
                let a = rnd() * 2 * .pi
                let rr = pow(rnd(), 0.5) * (r - 4)
                NSColor(white: 1, alpha: 0.05 + rnd() * 0.07).setFill()
                NSRect(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr, width: 1.4, height: 1.4).fill()
            }
            NSGraphicsContext.restoreGraphicsState()

            // 外圈
            NSColor(white: 1, alpha: 0.38).setStroke()
            let edge = self.circlePath(c, r - 0.75)
            edge.lineWidth = 1.5
            edge.stroke()
            return true
        }
        img.cacheMode = .always          // 交给 AppKit 栅格化缓存，之后每帧只是一次位图绘制
        img.recache()
        glassCache = img
        glassCacheKey = key
        return img
    }

    /// 球心文字层：只在数值变化时重排一次，动画每帧直接贴图
    private func ballTextLayer(d: CGFloat, c: NSPoint) -> NSImage {
        let key = "\(Int(d))-\(paused)-\(Fmt.compact(totalRx + totalTx))-\(Fmt.compact(totalRx))-\(Fmt.compact(totalTx))"
        if key == textCacheKey, let img = textCache { return img }

        let img = NSImage(size: NSSize(width: d, height: d), flipped: true) { _ in
            let total = self.paused ? "--" : Fmt.compact(self.totalRx + self.totalTx)
            self.text(total, x: 0, y: c.y - 26,
                      font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold),
                      color: .white, align: .center, boxWidth: d)
            self.text(self.paused ? "" : "↓\(Fmt.compact(self.totalRx))   ↑\(Fmt.compact(self.totalTx))",
                      x: 0, y: c.y + 16,
                      font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                      color: NSColor(white: 1, alpha: 0.85), align: .center, boxWidth: d)
            return true
        }
        img.cacheMode = .always
        img.recache()
        textCache = img
        textCacheKey = key
        return img
    }

    private func circlePath(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: 毛玻璃球

    private func drawGlassBall(center c: NSPoint, r: CGFloat) {
        glassBackground(d: bounds.width, r: r).draw(in: bounds)

        // 上弧 = 下载量程，下弧 = 上传量程（带缓动与峰值刻度）
        drawArcGauge(center: c, radius: r - 8, start: 200, span: 140, width: 2.5,
                     level: shownRxLevel, peak: peakRxLevel, color: Palette.cyan)
        drawArcGauge(center: c, radius: r - 8, start: 30, span: 120, width: 2.5,
                     level: shownTxLevel, peak: peakTxLevel, color: Palette.amber)

        ballTextLayer(d: bounds.width, c: c).draw(in: bounds)
    }

    // MARK: 曲线胶囊

    private func drawPillBall(rect r: NSRect) {
        // 不画任何投影
        Palette.glassBG.withAlphaComponent(fillAlpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()

        NSColor(white: 1, alpha: 0.34).setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        edge.lineWidth = 1.5
        edge.stroke()

        let fVal = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        let fArrow = NSFont.systemFont(ofSize: 12, weight: .semibold)
        text("↓", x: r.minX + 14, y: r.minY + 9, font: fArrow, color: Palette.cyan)
        text(paused ? "--" : Fmt.compact(totalRx), x: r.minX + 27, y: r.minY + 9, font: fVal, color: .white)
        text("↑", x: r.minX + 14, y: r.minY + r.height - 25, font: fArrow, color: Palette.amber)
        text(paused ? "--" : Fmt.compact(totalTx), x: r.minX + 27, y: r.minY + r.height - 25,
             font: fVal, color: .white)

        // 面积曲线：最近若干次采样的下行速率（裁剪在药丸内，避免溢出）
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let chart = NSRect(x: r.minX + 84, y: r.minY + 10, width: r.width - 104, height: r.height - 20)
        let vals = history.suffix(12).map { $0.rx }
        guard vals.count > 1 else { return }
        let maxV = max(vals.max() ?? 1, 1024)
        let area = NSBezierPath()
        area.move(to: NSPoint(x: chart.minX, y: chart.maxY))
        for (i, v) in vals.enumerated() {
            area.line(to: NSPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1),
                                  y: chart.maxY - chart.height * CGFloat(min(v / maxV, 1))))
        }
        area.line(to: NSPoint(x: chart.maxX, y: chart.maxY))
        area.close()
        Palette.cyan.withAlphaComponent(0.35).setFill()
        area.fill()

        let line = NSBezierPath()
        for (i, v) in vals.enumerated() {
            let pt = NSPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1),
                             y: chart.maxY - chart.height * CGFloat(min(v / maxV, 1)))
            i == 0 ? line.move(to: pt) : line.line(to: pt)
        }
        line.lineWidth = 1.6
        line.lineCapStyle = .round
        NSColor(srgbRed: 0.48, green: 0.87, blue: 1.0, alpha: 1).setStroke()
        line.stroke()
    }

    // MARK: 展开态：面板（皮肤跟着悬浮球样式走）

    private struct PanelSkin {
        var fill: NSColor           // 面板底色
        var radius: CGFloat
        var rim: NSColor
        var rimWidth: CGFloat
        var sheen: Bool             // 顶部白纱
        var noise: Bool             // 磨砂颗粒
        var rowFill: [CGFloat]      // 每行底色 alpha（不足则视为 0）
        var rowRadius: CGFloat
        var areaFill: CGFloat       // 曲线下方填充 alpha
    }

    private func skin(for style: BallStyle) -> PanelSkin {
        switch style {
        case .glass:
            return PanelSkin(fill: Palette.glassBG.withAlphaComponent(fillAlpha), radius: 18,
                             rim: NSColor(white: 1, alpha: 0.38), rimWidth: 1.5,
                             sheen: true, noise: true,
                             rowFill: [0.09, 0.05, 0.05, 0.05, 0.05], rowRadius: 10,
                             areaFill: 0.16)
        case .pill:
            return PanelSkin(fill: Palette.glassBG.withAlphaComponent(fillAlpha), radius: 26,
                             rim: NSColor(white: 1, alpha: 0.34), rimWidth: 1.5,
                             sheen: false, noise: false,
                             rowFill: [0.10, 0.055, 0.055, 0.055, 0.055], rowRadius: 20,
                             areaFill: 0.30)
        }
    }

    /// 磨砂颗粒
    private func noiseDots(in path: NSBezierPath, rect: NSRect, count: Int, range: ClosedRange<CGFloat>) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var seed: UInt64 = 20261014
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }
        for _ in 0..<count {
            NSColor(white: 1, alpha: range.lowerBound + rnd() * (range.upperBound - range.lowerBound)).setFill()
            NSRect(x: rect.minX + rnd() * rect.width, y: rect.minY + rnd() * rect.height,
                   width: 1.3, height: 1.3).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPanel() {
        let sk = skin(for: ballStyle)
        let w = Metrics.panelW
        let h = Metrics.panelH
        let pad = Metrics.pad

        do {
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                                    xRadius: sk.radius, yRadius: sk.radius)
            sk.fill.setFill()
            path.fill()

            if sk.sheen {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSGradient(starting: NSColor(white: 1, alpha: 0.09), ending: NSColor(white: 1, alpha: 0))?
                    .draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: h * 0.45), options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
            if sk.noise {
                noiseDots(in: path, rect: NSRect(x: 0, y: 0, width: w, height: h), count: 420, range: 0.03...0.08)
            }
            sk.rim.setStroke()
            path.lineWidth = sk.rimWidth
            path.stroke()
        }

        let fTitle = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let fSmall = NSFont.systemFont(ofSize: 11, weight: .medium)
        let fRate = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        let fRow = NSFont.systemFont(ofSize: 13, weight: .medium)
        let fVal = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let fFoot = NSFont.systemFont(ofSize: 10, weight: .regular)

        text("实时流量", x: pad, y: 15, font: fTitle, color: Palette.text)
        text(paused ? "已暂停" : "\(procCount) 个进程",
             x: pad, y: 15, font: fSmall, color: Palette.dim, align: .right, boxWidth: w - 2 * pad)

        text("↓ " + Fmt.rate(totalRx), x: pad, y: 42, font: fRate, color: Palette.cyan)
        text("↑ " + Fmt.rate(totalTx), x: pad, y: 42, font: fRate, color: Palette.amber,
             align: .right, boxWidth: w - 2 * pad)

        if showPeriodStatistics {
            drawPeriodSummary(x: pad, width: w - 2 * pad, small: fSmall, rate: fRate, foot: fFoot)
        } else {
            drawSparkline(NSRect(x: pad, y: 78, width: w - 2 * pad, height: 56), sk: sk)
        }

        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: pad, y: 146, width: w - 2 * pad, height: 1).fill()

        drawPanelTab("实时", rect: liveTabRect, selected: !showPeriodStatistics, font: fSmall)
        drawPanelTab("统计", rect: statisticsTabRect, selected: showPeriodStatistics, font: fSmall)
        let processHeading: String
        if showPeriodStatistics {
            let total = periodStatistics.processes.count
            let start = total == 0 ? 0 : min(statisticsScrollOffset + 1, total)
            let end = min(statisticsScrollOffset + 5, total)
            processHeading = total > 5 ? "累计 \(start)-\(end)/\(total)" : "进程累计"
        } else {
            processHeading = "进程排行"
        }
        text(processHeading, x: pad + 112, y: 154, font: fSmall, color: Palette.dim)
        let downloadTitle = showPeriodStatistics && statisticsSort.column == .download
            ? "下载 \(statisticsSort.ascending ? "↑" : "↓")" : "下载"
        let uploadTitle = showPeriodStatistics && statisticsSort.column == .upload
            ? "上传 \(statisticsSort.ascending ? "↑" : "↓")" : "上传"
        text(downloadTitle, x: pad + 150, y: 154, font: fSmall,
             color: showPeriodStatistics && statisticsSort.column == .download ? Palette.cyan : Palette.dim,
             align: .right, boxWidth: 62)
        text(uploadTitle, x: pad + 212, y: 154, font: fSmall,
             color: showPeriodStatistics && statisticsSort.column == .upload ? Palette.amber : Palette.dim,
             align: .right, boxWidth: 68)

        if showPeriodStatistics {
            let count = periodStatistics.processes.count
            statisticsScrollOffset = min(statisticsScrollOffset, max(0, count - 5))
            let sorted = periodStatistics.sortedProcesses(
                byUpload: statisticsSort.column == .upload, ascending: statisticsSort.ascending)
            let top = Array(sorted.dropFirst(statisticsScrollOffset).prefix(5))
            if top.isEmpty {
                text("这段期间还没有流量", x: pad, y: 202, font: fRow, color: Palette.dim)
            } else {
                let maxTotal = max(Double(top[0].totalBytes), 1)
                for (i, p) in top.enumerated() {
                    drawPeriodRow(p, index: i, y: 176 + CGFloat(i) * 46, maxTotal: maxTotal,
                                  fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
                }
            }
        } else {
            let top = Array(rows.prefix(5))
            if top.isEmpty {
                text(paused ? "采樣已暫停" : "正在採樣…", x: pad, y: 200, font: fRow, color: Palette.dim)
            } else {
                let maxTotal = max(top[0].total, 1)
                for (i, r) in top.enumerated() {
                    drawRow(r, index: i, y: 176 + CGFloat(i) * 46, maxTotal: maxTotal,
                            fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
                }
            }
        }

        let foot = "自身 \(Fmt.pct(selfCPU)) · \(String(format: "%.0f", selfMemMB)) MB"
            + " · nettop \(Fmt.pct(nettopCPU)) · 采样 \(intervalLabel)"
        text(foot, x: pad, y: h - 22, font: fFoot, color: Palette.dim)
    }

    private var liveTabRect: NSRect { NSRect(x: Metrics.pad, y: 151, width: 50, height: 22) }
    private var statisticsTabRect: NSRect { NSRect(x: Metrics.pad + 54, y: 151, width: 50, height: 22) }
    private var downloadSortRect: NSRect { NSRect(x: Metrics.pad + 150, y: 151, width: 62, height: 22) }
    private var uploadSortRect: NSRect { NSRect(x: Metrics.pad + 212, y: 151, width: 68, height: 22) }
    private var resetStatisticsRect: NSRect {
        NSRect(x: Metrics.panelW - Metrics.pad - 56, y: 78, width: 56, height: 22)
    }

    private func toggleStatisticsSort(_ column: Sampler.StatisticsSortState.Column) {
        statisticsSort.click(column)
        statisticsScrollOffset = 0
        needsDisplay = true
    }

    private func drawPanelTab(_ title: String, rect: NSRect, selected: Bool, font: NSFont) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if selected {
            Palette.cyan.withAlphaComponent(0.18).setFill()
            Palette.cyan.withAlphaComponent(0.52).setStroke()
        } else {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSColor(white: 1, alpha: 0.12).setStroke()
        }
        path.lineWidth = 1
        path.fill()
        path.stroke()
        text(title, x: rect.minX, y: rect.minY + 4, font: font,
             color: selected ? Palette.cyan : Palette.dim, align: .center, boxWidth: rect.width)
    }

    private func drawPeriodSummary(x: CGFloat, width: CGFloat, small: NSFont, rate: NSFont, foot: NSFont) {
        text("累计总流量 · 自启动/重置起", x: x, y: 80, font: small, color: Palette.dim)
        let resetPath = NSBezierPath(roundedRect: resetStatisticsRect, xRadius: 7, yRadius: 7)
        NSColor(white: 1, alpha: 0.07).setFill()
        resetPath.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        resetPath.lineWidth = 1
        resetPath.stroke()
        text("重置", x: resetStatisticsRect.minX, y: resetStatisticsRect.minY + 4,
             font: small, color: Palette.text, align: .center, boxWidth: resetStatisticsRect.width)

        text("↓ " + Fmt.bytes(periodStatistics.rxBytes), x: x, y: 100,
             font: rate, color: Palette.cyan)
        text("↑ " + Fmt.bytes(periodStatistics.txBytes), x: x, y: 100,
             font: rate, color: Palette.amber, align: .right, boxWidth: width)
        let elapsed = Date().timeIntervalSince(periodStatistics.since)
        text("统计时长 \(Fmt.duration(elapsed)) · \(periodStatistics.processes.count) 种进程",
             x: x, y: 128, font: foot, color: Palette.dim)
    }

    private func drawPeriodRow(_ p: Sampler.ProcessTotal, index: Int, y: CGFloat, maxTotal: Double,
                               fRow: NSFont, fVal: NSFont, w: CGFloat, pad: CGFloat, sk: PanelSkin) {
        let rowRect = NSRect(x: pad, y: y, width: w - 2 * pad, height: 40)
        let rowAlpha = index < sk.rowFill.count ? sk.rowFill[index] : 0
        if rowAlpha > 0 {
            let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: sk.rowRadius, yRadius: sk.rowRadius)
            NSColor(white: 1, alpha: rowAlpha).setFill()
            rowPath.fill()
        } else {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSRect(x: rowRect.minX, y: rowRect.minY - 3, width: rowRect.width, height: 1).fill()
        }

        let dot = NSRect(x: rowRect.minX + 12, y: rowRect.minY + 12, width: 15, height: 15)
        Palette.iconColors[stableHash(p.name) % Palette.iconColors.count].setFill()
        NSBezierPath(ovalIn: dot).fill()

        let valX = rowRect.maxX - 12
        let nameX = dot.maxX + 9
        let room = max(20, valX - 148 - nameX - (p.viaProxy ? 43 : 0))
        let shown = truncated(p.name, font: fRow, maxWidth: room)
        let nameWidth = text(shown, x: nameX, y: rowRect.minY + 9, font: fRow, color: Palette.text)
        if p.viaProxy {
            let badge = NSRect(x: nameX + nameWidth + 5, y: rowRect.minY + 11, width: 34, height: 16)
            let badgePath = NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8)
            Palette.cyan.withAlphaComponent(0.16).setFill()
            badgePath.fill()
            Palette.cyan.withAlphaComponent(0.65).setStroke()
            badgePath.lineWidth = 1
            badgePath.stroke()
            text("代理", x: badge.minX + 4, y: badge.minY + 2, font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                 color: Palette.cyan)
        }

        let track = NSRect(x: rowRect.minX + 36, y: rowRect.minY + 32,
                           width: rowRect.width - 48, height: 3)
        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let ratio = min(CGFloat(Double(p.totalBytes) / maxTotal), 1)
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * ratio, height: track.height)
        Palette.cyan.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()

        text(Fmt.bytes(p.rxBytes), x: valX - 148, y: rowRect.minY + 11, font: fVal,
             color: Palette.cyan, align: .right, boxWidth: 70)
        text(Fmt.bytes(p.txBytes), x: valX - 70, y: rowRect.minY + 11, font: fVal,
             color: Palette.amber, align: .right, boxWidth: 70)
    }

    private func drawSparkline(_ r: NSRect, sk: PanelSkin) {
        guard history.count > 1 else { return }
        let n = history.count
        let maxV = max(history.map { max($0.rx, $0.tx) }.max() ?? 1, 1024)

        func path(_ pick: (Double, Double) -> Double) -> NSBezierPath {
            let p = NSBezierPath()
            p.lineWidth = 1.6
            for (i, s) in history.enumerated() {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(max(n - 1, 1))
                let y = r.maxY - r.height * CGFloat(min(pick(s.rx, s.tx) / maxV, 1.0))
                i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
            }
            return p
        }

        if sk.areaFill > 0 {
            let area = path { rx, _ in rx }
            area.line(to: NSPoint(x: r.maxX, y: r.maxY))
            area.line(to: NSPoint(x: r.minX, y: r.maxY))
            area.close()
            Palette.cyan.withAlphaComponent(sk.areaFill).setFill()
            area.fill()
        }

        Palette.cyan.setStroke()
        path { rx, _ in rx }.stroke()
        Palette.amber.setStroke()
        path { _, tx in tx }.stroke()

        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: r.minX, y: r.maxY - 0.5, width: r.width, height: 1).fill()
    }

    private func drawRow(_ r: Sampler.Row, index: Int, y: CGFloat, maxTotal: Double,
                         fRow: NSFont, fVal: NSFont, w: CGFloat, pad: CGFloat, sk: PanelSkin) {
        let rowRect = NSRect(x: pad, y: y, width: w - 2 * pad, height: 40)
        let rowAlpha = index < sk.rowFill.count ? sk.rowFill[index] : 0
        if rowAlpha > 0 {
            let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: sk.rowRadius, yRadius: sk.rowRadius)
            NSColor(white: 1, alpha: rowAlpha).setFill()
            rowPath.fill()
        } else {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSRect(x: rowRect.minX, y: rowRect.minY - 3, width: rowRect.width, height: 1).fill()
        }

        let dot = NSRect(x: rowRect.minX + 12, y: rowRect.minY + 12, width: 15, height: 15)
        let color = Palette.iconColors[stableHash(r.name) % Palette.iconColors.count]
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let nameX = dot.maxX + 9
        let valX = rowRect.maxX - 12
        if r.viaProxy {
            // 行尾标「代理」：告诉用户这条流量是从代理出去的（不是直连）
            let fBadge = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
            let badgeW = ("代理" as NSString).size(withAttributes: [.font: fBadge]).width + 11
            let room = (valX - 148) - nameX - 6            // 值列左边的可用宽度
            let shown = truncated(r.name, font: fRow, maxWidth: room - badgeW - 6)
            let nw = text(shown, x: nameX, y: rowRect.minY + 11, font: fRow, color: Palette.text)
            let br = NSRect(x: nameX + nw + 6, y: rowRect.minY + 13, width: badgeW, height: 14)
            let path = NSBezierPath(roundedRect: br, xRadius: 7, yRadius: 7)
            Palette.cyan.withAlphaComponent(0.16).setFill()
            path.fill()
            Palette.cyan.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
            text("代理", x: br.minX + 5.5, y: rowRect.minY + 14.5, font: fBadge, color: Palette.cyan)
        } else {
            text(r.name, x: nameX, y: rowRect.minY + 11, font: fRow, color: Palette.text)
        }

        text(Fmt.rate(r.rx), x: valX - 148, y: rowRect.minY + 12, font: fVal, color: Palette.cyan,
             align: .right, boxWidth: 70)
        text(Fmt.rate(r.tx), x: valX - 70, y: rowRect.minY + 12, font: fVal, color: Palette.amber,
             align: .right, boxWidth: 70)

        // 占比：极简款画细线，其它款画圆角条
        let frac = CGFloat(min(r.total / maxTotal, 1.0))
        let barW = (w - 2 * pad - 40) * frac
        if barW > 1 {
            let h: CGFloat = 3
            let bar = NSBezierPath(roundedRect: NSRect(x: dot.maxX + 9, y: rowRect.maxY - 12,
                                                       width: barW, height: h),
                                   xRadius: h / 2, yRadius: h / 2)
            Palette.cyan.withAlphaComponent(0.75).setFill()
            bar.fill()
        }
    }

    @discardableResult
    private func text(_ s: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor,
                      align: Align = .left, boxWidth: CGFloat = 0) -> CGFloat {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: a)
        let size = str.size()
        var px = x
        switch align {
        case .left: break
        case .center: px = x + (boxWidth - size.width) / 2
        case .right: px = x + boxWidth - size.width
        }
        str.draw(at: NSPoint(x: px, y: y))
        return size.width
    }

    /// 名字太长就截断加省略号——给行尾的「代理」标腾地方
    private func truncated(_ s: String, font: NSFont, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxWidth { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            let cand = t + "…"
            if (cand as NSString).size(withAttributes: attrs).width <= maxWidth { return cand }
        }
        return "…"
    }

    // MARK: 交互

    private var mouseDownAt: NSPoint = .zero
    private var windowOriginAt: NSPoint = .zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragged = false
        mouseDownAt = NSEvent.mouseLocation
        windowOriginAt = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard controller?.isHoverPanelActive != true else { return }
        guard let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownAt.x
        let dy = now.y - mouseDownAt.y
        if abs(dx) > 3 || abs(dy) > 3 { dragged = true }
        win.setFrameOrigin(NSPoint(x: windowOriginAt.x + dx, y: windowOriginAt.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            controller?.persistPosition()
            return
        }
        if expanded {
            let point = convert(event.locationInWindow, from: nil)
            if liveTabRect.contains(point) {
                controller?.setPeriodStatisticsVisible(false)
                return
            }
            if statisticsTabRect.contains(point) {
                controller?.setPeriodStatisticsVisible(true)
                return
            }
            if showPeriodStatistics && downloadSortRect.contains(point) {
                toggleStatisticsSort(.download)
                return
            }
            if showPeriodStatistics && uploadSortRect.contains(point) {
                toggleStatisticsSort(.upload)
                return
            }
            if showPeriodStatistics && resetStatisticsRect.contains(point) {
                controller?.resetPeriodStatistics()
                return
            }
        }
        controller?.toggleExpanded()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard expanded else { return }
        addCursorRect(liveTabRect, cursor: .pointingHand)
        addCursorRect(statisticsTabRect, cursor: .pointingHand)
        if showPeriodStatistics {
            addCursorRect(resetStatisticsRect, cursor: .pointingHand)
            addCursorRect(downloadSortRect, cursor: .pointingHand)
            addCursorRect(uploadSortRect, cursor: .pointingHand)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard expanded, showPeriodStatistics else {
            super.scrollWheel(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 172 && point.y < Metrics.panelH - 24 else {
            super.scrollWheel(with: event)
            return
        }
        let maxOffset = max(0, periodStatistics.processes.count - 5)
        guard maxOffset > 0 else { return }
        let direction = event.scrollingDeltaY > 0 ? -1 : 1
        statisticsScrollOffset = min(max(0, statisticsScrollOffset + direction), maxOffset)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - 控制器

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sampler = Sampler()
    private var window: NSWindow!
    private var view: BallView!

    private var mode: DisplayMode = .tray
    private var statusItem: NSStatusItem?
    private var statusHoverArea: NSTrackingArea?
    private var panelHoverArea: NSTrackingArea?
    private var hoverShowWorkItem: DispatchWorkItem?
    private var hoverHideWorkItem: DispatchWorkItem?
    private var hoverPanelActive = false
    private var hoverPanelRestoreOrigin: NSPoint?
    private var lastRx = 0.0
    private var lastTx = 0.0
    private var lastTitleText = ""
    private var trayStyle: TrayStyle = .stackLarge
    private var ballStyle: BallStyle = .glass
    private var fillAlpha: CGFloat = 0.85
    private lazy var mainMenu: NSMenu = {
        let m = NSMenu()
        m.delegate = self
        return m
    }()

    private var selfCPU = 0.0
    private var selfMem: UInt64 = 0
    private var lastCPUSample: (time: Date, cpu: Double)?
    private var benchmarkSeconds: Double?
    private var benchmarkStart = Date()
    private var benchmarkUpdates = 0
    private var benchmarkPeakSelf: UInt64 = 0
    private var benchmarkPeakChild: UInt64 = 0
    private var benchmarkSelfCPU0 = 0.0
    private var memTrace: [UInt64] = []
    private var animDemo = false
    private var animDemoPhase = 0.0
    private var animOff = false
    private var statsTimer: Timer?
    private var animTimer: Timer?
    private var animFrames = 0
    private let startDate = Date()

    private let posKey = "NetBall.origin"
    private let freqKey = "NetBall.interval"
    private let modeKey = "NetBall.mode"

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 单实例保护：重复启动会出现两个菜单栏图标
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                FileHandle.standardError.write("已有实例在运行，退出\n".data(using: .utf8)!)
                NSApp.terminate(nil)
                return
            }
        }

        let argv0 = CommandLine.arguments
        trayStyle = TrayStyle.load()
        ballStyle = BallStyle.load()
        if let i = argv0.firstIndex(of: "--style"), i + 1 < argv0.count,
           let st = BallStyle(rawValue: argv0[i + 1]) { ballStyle = st }
        let savedAlpha = UserDefaults.standard.double(forKey: "NetBall.fillAlpha")
        fillAlpha = savedAlpha > 0 ? CGFloat(savedAlpha) : 0.85

        let size = ballStyle.collapsedSize
        let origin = savedOrigin() ?? defaultOrigin(for: size)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // 系统那层也关掉，避免任何"背后一层影子"
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false

        view = BallView(frame: NSRect(origin: .zero, size: size))
        view.periodStatistics = sampler.currentPeriodStatistics()
        view.controller = self
        window.contentView = view
        installPanelHoverTracking()

        let argv = argv0
        view.ballStyle = ballStyle
        view.fillAlpha = fillAlpha
        animDemo = argv.contains("--anim-demo")   // 只给 --benchmark 用，见 syntheticRates()
        animOff = argv.contains("--anim-off")     // 关掉缓动，做 A/B 对照用
        if argv.contains("--tray") { mode = .tray }
        else if argv.contains("--both") { mode = .both }
        else if argv.contains("--ball") { mode = .ball }
        else { mode = DisplayMode.load() }
        applyMode()

        // 安全兜底：macOS 26 的「菜单栏」隐私开关可能把图标藏起来，
        // 若 2.5 秒后图标仍不可见，就回退成「菜单栏 + 悬浮球」，免得变成一个看不见也关不掉的进程。
        if mode == .tray {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                let visible = self.statusItem?.button?.window?.isVisible ?? false
                FileHandle.standardError.write("tray icon visible=\(visible)\n".data(using: .utf8)!)
                if !visible {
                    self.mode = .both
                    self.applyMode()
                }
            }
        }

        if let i = argv.firstIndex(of: "--pidfile"), i + 1 < argv.count {
            try? "\(ProcessInfo.processInfo.processIdentifier)"
                .write(toFile: argv[i + 1], atomically: true, encoding: .utf8)
        }

        let saved = UserDefaults.standard.double(forKey: freqKey)
        sampler.idleInterval = saved > 0 ? saved : 2.0
        sampler.activeInterval = 1.0
        view.intervalLabel = "\(Int(sampler.idleInterval))s"

        sampler.onSnapshot = { [weak self] rows, rx, tx, count, period in
            guard let self else { return }
            self.benchmarkUpdates += 1
            self.view.intervalLabel = "\(Int(self.sampler.interval))s"
            self.view.nettopCPU = self.startDate.timeIntervalSinceNow < 0
                ? self.sampler.childCPUSeconds / max(1, -self.startDate.timeIntervalSinceNow) * 100
                : 0
            self.view.rows = rows
            self.view.periodStatistics = period
            // --anim-demo：用振荡的合成速率替掉真实速率，强制每次采样都触发 0.4s 缓动，
            // 用来量"20fps 重绘"这部分的 CPU 代价（真实流量空闲时弧线根本不动，量不出来）
            let (urx, utx) = self.animDemo ? self.syntheticRates() : (rx, tx)
            self.view.updateRates(rx: urx, tx: utx)
            self.view.procCount = count
            self.view.history.append((rx: urx, tx: utx))
            if self.view.history.count > 60 { self.view.history.removeFirst(self.view.history.count - 60) }
            self.view.recomputePeaks()
            self.view.needsDisplay = true
            self.startArcAnimation()
            self.lastRx = urx
            self.lastTx = utx
            self.updateStatusTitle()
        }
        sampler.start()

        benchmarkSelfCPU0 = cpuSeconds(getpid()) ?? 0
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSelfStats()
        }
        statsTimer?.tolerance = 0.5   // 让系统合并定时器，少唤醒一次

        if let i = CommandLine.arguments.firstIndex(of: "--benchmark"),
           i + 1 < CommandLine.arguments.count,
           let secs = Double(CommandLine.arguments[i + 1]) {
            benchmarkSeconds = secs
            benchmarkStart = Date()
            // 最坏情况：按 --freq 的间隔 + 面板展开（含绘制）
            let freq = doubleArg("--freq", 2.0)
            sampler.setIntervals(idle: freq, active: freq)
            if !view.expanded && mode.showsBall && !CommandLine.arguments.contains("--ball") { toggleExpanded() }
            if let ci = CommandLine.arguments.firstIndex(of: "--collapse-after"),
               ci + 1 < CommandLine.arguments.count, let at = Double(CommandLine.arguments[ci + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self, self.view.expanded else { return }
                    self.toggleExpanded()
                }
            }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self else { return }
                let f = footprintBytes(getpid())
                self.benchmarkPeakSelf = max(self.benchmarkPeakSelf, f)
                self.memTrace.append(f)
                if Date().timeIntervalSince(self.benchmarkStart) >= (self.benchmarkSeconds ?? 20) {
                    t.invalidate()
                    self.finishBenchmark()
                }
            }
        }

        if let i = argv.firstIndex(of: "--title-probe"),
           i + 1 < argv.count, let secs = Double(argv[i + 1]) {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self else { return }
                let el = Date().timeIntervalSince(self.startDate)
                let vis = self.statusItem?.button?.window?.isVisible ?? false
                print("t=\(Int(el))s  模式=\(self.mode.rawValue)  图标可见=\(vis)  标题=[\(self.lastTitleText)]")
                if el >= secs { timer.invalidate(); self.sampler.stop(); exit(0) }
            }
            t.tolerance = 0.2
        }

        if let i = CommandLine.arguments.firstIndex(of: "--quit-after"),
           i + 1 < CommandLine.arguments.count,
           let secs = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
    }

    /// 弧线缓动：收到新速率后跑一小段 20fps 动画，收敛即停（不做无谓重绘）
    private func startArcAnimation() {
        guard ballStyle == .glass, mode.showsBall, !view.expanded else { return }
        guard view.needsAnimation() else { return }   // 数值没动就不折腾
        if animOff {                                  // --anim-off：直接跳，用来量缓动的净代价
            view.settleAnimation()
            view.needsDisplay = true
            return
        }
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animFrames += 1
            let settled = self.view.stepAnimation()
            self.view.needsDisplay = true
            if settled {
                t.invalidate()
                self.animTimer = nil
            }
        }
        animTimer?.tolerance = 0.01
    }

    /// `--anim-demo` 用的振荡速率：每次采样都给出明显不同的值，
    /// 让"1s 采样 + 0.4s 缓动"这个最坏占空比（缓动占 40% 时间）真的跑起来
    private func syntheticRates() -> (Double, Double) {
        animDemoPhase += 1
        let p = animDemoPhase
        return ((2.0 + 2.6 * sin(p / 3.1) + 1.1 * sin(p / 1.3)) * 1048576,
                (0.7 + 0.5 * sin(p / 2.7)) * 1048576)
    }

    // MARK: 显示模式与菜单栏

    private func applyMode() {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)

        if mode.showsTray {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.menu = mainMenu
                statusItem = item
                installStatusHoverTracking()
            }
        } else if let item = statusItem {
            if let statusHoverArea, let button = item.button {
                button.removeTrackingArea(statusHoverArea)
            }
            statusHoverArea = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        if mode.showsBall {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
        updateStatusTitle()
    }

    /// 当前该显示什么（暂停时用占位符）
    private func trayLines(_ style: TrayStyle) -> [String] {
        if sampler.paused { return style.lines(down: "--", up: "--", total: "--") }
        return style.lines(down: Fmt.tray(lastRx), up: Fmt.tray(lastTx),
                           total: Fmt.tray(lastRx + lastTx))
    }

    private func updateStatusTitle() {
        let text: String
        if sampler.paused {
            text = "⏸ --"
        } else {
            text = "↓\(Fmt.tray(lastRx)) ↑\(Fmt.tray(lastTx))"
        }
        lastTitleText = text
        guard let button = statusItem?.button else { return }
        button.image = trayIconImage(style: trayStyle, lines: trayLines(trayStyle))
        button.title = ""
        button.imagePosition = .imageOnly
    }

    // MARK: 菜单栏悬停面板

    private func installStatusHoverTracking() {
        guard let button = statusItem?.button else { return }
        if let statusHoverArea { button.removeTrackingArea(statusHoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: ["netball.hoverSource": "status"])
        button.addTrackingArea(area)
        statusHoverArea = area
    }

    private func installPanelHoverTracking() {
        guard let view else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: ["netball.hoverSource": "panel"])
        view.addTrackingArea(area)
        panelHoverArea = area
    }

    // NSTrackingArea sends the Objective-C selector `mouseEntered:`. Swift's
    // default selector for `mouseEntered(with:)` would be `mouseEnteredWith:`,
    // so spell out AppKit's selector explicitly for this NSObject owner.
    @objc(mouseEntered:) func handleMouseEntered(_ event: NSEvent) {
        let source = event.trackingArea?.userInfo?["netball.hoverSource"] as? String
        hoverHideWorkItem?.cancel()
        hoverHideWorkItem = nil

        guard source == "status" else { return }
        hoverShowWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isMouseOverStatusItem() else { return }
            self.showHoverPanel()
        }
        hoverShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc(mouseExited:) func handleMouseExited(_ event: NSEvent) {
        let source = event.trackingArea?.userInfo?["netball.hoverSource"] as? String
        guard source == "status" || source == "panel" else { return }
        if source == "status" {
            hoverShowWorkItem?.cancel()
            hoverShowWorkItem = nil
        }
        scheduleHoverPanelDismissal()
    }

    private func showHoverPanel() {
        // 菜单栏模式下悬停图标打开主面板；两种展示同时启用时，离开后还原悬浮球。
        guard mode.showsTray, !view.expanded, !hoverPanelActive else { return }
        hoverPanelActive = true
        hoverPanelRestoreOrigin = window.frame.origin
        view.expanded = true
        sampler.setActive(true)
        resizeWindow(to: NSSize(width: Metrics.panelW, height: Metrics.panelH), persist: false)
        positionHoverPanelUnderStatusItem()
        window.orderFrontRegardless()
        view.needsDisplay = true
    }

    private func scheduleHoverPanelDismissal() {
        hoverHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverPanelActive,
                  !self.isMouseInsideHoverRegions() else { return }
            self.dismissHoverPanel()
        }
        hoverHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func dismissHoverPanel() {
        guard hoverPanelActive else { return }
        hoverPanelActive = false
        hoverShowWorkItem?.cancel()
        hoverHideWorkItem?.cancel()
        hoverShowWorkItem = nil
        hoverHideWorkItem = nil
        view.expanded = false
        sampler.setActive(false)
        resizeWindow(to: ballStyle.collapsedSize, persist: false)
        if let origin = hoverPanelRestoreOrigin { window.setFrameOrigin(origin) }
        hoverPanelRestoreOrigin = nil
        if mode.showsBall { window.orderFrontRegardless() }
        else { window.orderOut(nil) }
        view.needsDisplay = true
    }

    var isHoverPanelActive: Bool { hoverPanelActive }

    private func positionHoverPanelUnderStatusItem() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonRect.origin) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let panelSize = window.frame.size
        let x = min(max(buttonRect.maxX - panelSize.width, visible.minX + 6),
                    visible.maxX - panelSize.width - 6)
        let y = visible.maxY - panelSize.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func isMouseOverStatusItem() -> Bool {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return false }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    private func isMouseInsideHoverRegions() -> Bool {
        let mouse = NSEvent.mouseLocation
        if hoverPanelActive && window.frame.contains(mouse) { return true }
        if let button = statusItem?.button, let buttonWindow = button.window {
            let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.contains(mouse) { return true }
        }
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 点击菜单栏图标时让原有菜单正常打开，收起临时悬停面板。
        dismissHoverPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--pidfile"), i + 1 < CommandLine.arguments.count {
            try? FileManager.default.removeItem(atPath: CommandLine.arguments[i + 1])
        }
        sampler.stop()
    }

    private func refreshSelfStats() {
        let now = Date()
        let cpu = cpuSeconds(getpid()) ?? 0
        if let last = lastCPUSample {
            let dt = max(0.5, now.timeIntervalSince(last.time))
            selfCPU = (cpu - last.cpu) / dt * 100
        }
        lastCPUSample = (now, cpu)
        selfMem = footprintBytes(getpid())
        view.selfCPU = selfCPU
        view.selfMemMB = Double(selfMem) / 1048576
        view.needsDisplay = true
    }

    private func finishBenchmark() {
        let wall = Date().timeIntervalSince(benchmarkStart)
        let selfCPUAvg = ((cpuSeconds(getpid()) ?? 0) - benchmarkSelfCPU0) / wall * 100
        let nettopCPU = sampler.childCPUSeconds / wall * 100
        var out = "benchmark 间隔=\(Int(sampler.interval))s  时长=\(String(format: "%.1f", wall))s  采样次数=\(sampler.shots)\n"
        out += "  NetBall  自身  cpu均值=\(Fmt.pct(selfCPUAvg))  peakFootprint=\(Fmt.mb(benchmarkPeakSelf))\n"
        out += "  nettop   子进程 cpu均值=\(Fmt.pct(nettopCPU))  peakFootprint=\(Fmt.mb(sampler.childPeakFootprint))\n"
        out += "  合计     cpu≈\(Fmt.pct(selfCPUAvg + nettopCPU))\n"
        out += String(format: "  弧线缓动 定时器帧=%d  实际重绘=%d  重绘均值=%.1f 次/秒\n",
                      animFrames, view.drawCount, Double(view.drawCount) / wall)
        let marks = memTrace.enumerated().filter { $0.offset % 10 == 0 }.map { "\($0.offset / 2)s:\($0.element / 1048576)MB" }
        out += "  内存轨迹 \(marks.joined(separator: "  "))\n"
        out += "  末值 \(Fmt.mb(memTrace.last ?? 0))\n"
        print(out)
        sampler.stop()
        exit(0)
    }

    // MARK: 窗口尺寸与位置

    private func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: posKey) else { return nil }
        let p = NSPointFromString(s)
        return (p.x == 0 && p.y == 0) ? nil : p
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return NSPoint(x: 100, y: 100) }
        return NSPoint(x: vis.maxX - size.width - 24, y: vis.maxY - size.height - 24)
    }

    func persistPosition() {
        guard let win = window, !hoverPanelActive else { return }
        UserDefaults.standard.set(NSStringFromPoint(win.frame.origin), forKey: posKey)
    }

    /// 改变窗口尺寸：左上角保持不动，并夹在屏幕内
    private func resizeWindow(to size: NSSize, persist: Bool = true) {
        var f = window.frame
        let top = f.origin.y + f.size.height
        f.size = size
        f.origin.y = top - size.height
        if let vis = (window.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vis.minX + 6), vis.maxX - size.width - 6)
            f.origin.y = min(max(f.origin.y, vis.minY + 6), vis.maxY - size.height - 6)
        }
        window.setFrame(f, display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        if persist { persistPosition() }
    }

    func toggleExpanded() {
        guard mode.showsBall, !hoverPanelActive else { return }   // 悬停面板只随指针离开收起
        view.expanded.toggle()
        sampler.setActive(view.expanded)
        resizeWindow(to: view.expanded
                     ? NSSize(width: Metrics.panelW, height: Metrics.panelH)
                     : ballStyle.collapsedSize)
    }

    func setPeriodStatisticsVisible(_ visible: Bool) {
        view.showPeriodStatistics = visible
        if visible { view.statisticsScrollOffset = 0 }
        window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    func resetPeriodStatistics() {
        view.periodStatistics = sampler.resetPeriodStatistics()
        view.statisticsScrollOffset = 0
        view.needsDisplay = true
    }

    func resetPosition() {
        let size = window.frame.size
        window.setFrameOrigin(defaultOrigin(for: size))
        persistPosition()
    }

    // MARK: 菜单

    /// 悬浮球右键用的临时菜单
    func buildMenu() -> NSMenu {
        let m = NSMenu()
        fill(m)
        return m
    }

    /// 菜单栏图标用的常驻菜单：每次弹出前重建，保证勾选状态最新
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        let modeItem = NSMenuItem(title: "显示模式", action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        for m in [DisplayMode.tray, .ball, .both] {
            let it = NSMenuItem(title: m.label, action: #selector(menuSetMode(_:)), keyEquivalent: "")
            it.representedObject = m.rawValue
            it.state = (m == mode) ? .on : .off
            modeSub.addItem(it)
        }
        modeItem.submenu = modeSub
        menu.addItem(modeItem)

        if mode.showsBall {
            menu.addItem(withTitle: view.expanded ? "收起面板" : "展开面板",
                         action: #selector(menuToggleExpand), keyEquivalent: "")

            let ballItem = NSMenuItem(title: "悬浮球样式", action: nil, keyEquivalent: "")
            let ballSub = NSMenu()
            for st in BallStyle.allCases {
                let it = NSMenuItem(title: st.label, action: #selector(menuSetBallStyle(_:)), keyEquivalent: "")
                it.representedObject = st.rawValue
                it.state = (st == ballStyle) ? .on : .off
                ballSub.addItem(it)
            }
            ballItem.submenu = ballSub
            menu.addItem(ballItem)

            let alphaItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
            let alphaSub = NSMenu()
            for v in [0.60, 0.70, 0.80, 0.85, 0.92, 1.00] {
                let it = NSMenuItem(title: "\(Int(v * 100))%", action: #selector(menuSetAlpha(_:)), keyEquivalent: "")
                it.representedObject = v
                it.state = (abs(Double(fillAlpha) - v) < 0.01) ? .on : .off
                alphaSub.addItem(it)
            }
            alphaItem.submenu = alphaSub
            menu.addItem(alphaItem)
        }

        if mode.showsTray {
            let styleItem = NSMenuItem(title: "菜单栏样式", action: nil, keyEquivalent: "")
            let styleSub = NSMenu()
            for st in TrayStyle.allCases {
                let it = NSMenuItem(title: st.label, action: #selector(menuSetTrayStyle(_:)), keyEquivalent: "")
                it.representedObject = st.rawValue
                it.state = (st == trayStyle) ? .on : .off
                styleSub.addItem(it)
            }
            styleItem.submenu = styleSub
            menu.addItem(styleItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: sampler.paused ? "继续采样" : "暂停采样",
                     action: #selector(menuTogglePause), keyEquivalent: "")

        let freqItem = NSMenuItem(title: "空闲采样频率", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [1.0, 2.0, 5.0] {
            let it = NSMenuItem(title: "\(Int(v)) 秒（展开面板时固定 1 秒）", action: #selector(menuSetFreq(_:)), keyEquivalent: "")
            it.representedObject = v
            it.state = (abs(sampler.idleInterval - v) < 0.01) ? .on : .off
            sub.addItem(it)
        }
        freqItem.submenu = sub
        menu.addItem(freqItem)

        if mode.showsBall {
            menu.addItem(.separator())
            menu.addItem(withTitle: "重置悬浮球位置", action: #selector(menuResetPosition), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 NetBall", action: #selector(menuQuit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
            item.submenu?.items.forEach { $0.target = self }
        }
    }

    @objc private func menuSetBallStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let st = BallStyle(rawValue: raw) else { return }
        ballStyle = st
        view.ballStyle = st
        // 胶囊样式下弧线不参与绘制，切回毛玻璃球时显示值可能停在很久以前——直接对齐到当前值
        view.settleAnimation()
        if !view.expanded { resizeWindow(to: st.collapsedSize) } else { view.needsDisplay = true }
        UserDefaults.standard.set(st.rawValue, forKey: "NetBall.ballStyle")
    }

    @objc private func menuSetAlpha(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        fillAlpha = CGFloat(v)
        view.fillAlpha = fillAlpha
        view.needsDisplay = true
        UserDefaults.standard.set(v, forKey: "NetBall.fillAlpha")
    }

    @objc private func menuSetTrayStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let st = TrayStyle(rawValue: raw) else { return }
        trayStyle = st
        UserDefaults.standard.set(st.rawValue, forKey: "NetBall.trayStyle")
        updateStatusTitle()
    }

    @objc private func menuSetMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = DisplayMode(rawValue: raw) else { return }
        dismissHoverPanel()
        mode = m
        // 收起/隐藏期间弧线不重绘，切回悬浮球先对齐到当前值，避免闪一下旧数据
        view.settleAnimation()
        applyMode()
    }

    @objc private func menuToggleExpand() { toggleExpanded() }

    @objc private func menuTogglePause() {
        if sampler.paused { sampler.resume() } else { sampler.stop() }
        view.paused = sampler.paused
        view.updateRates(rx: lastRx, tx: lastTx)
        view.needsDisplay = true
        startArcAnimation()
        updateStatusTitle()
    }

    @objc private func menuSetFreq(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        sampler.setIdleInterval(v)
        UserDefaults.standard.set(v, forKey: freqKey)
        view.intervalLabel = "\(Int(sampler.interval))s"
        view.paused = sampler.paused
        view.needsDisplay = true
    }

    @objc private func menuResetPosition() { resetPosition() }
    @objc private func menuQuit() { sampler.stop(); NSApp.terminate(nil) }
}

// MARK: - 渲染自检（不需要屏幕录制权限）

private let snapshotMargin: CGFloat = 24

/// 用给定数据把界面渲染成 PNG
private func renderSnapshot(to path: String, expanded: Bool, fill: (BallView) -> Void) {
    _ = NSApplication.shared

    var snapStyle = BallStyle.load()
    if let i = CommandLine.arguments.firstIndex(of: "--style"),
       i + 1 < CommandLine.arguments.count,
       let st = BallStyle(rawValue: CommandLine.arguments[i + 1]) { snapStyle = st }
    let contentSize = expanded
        ? NSSize(width: Metrics.panelW, height: Metrics.panelH)
        : snapStyle.collapsedSize
    let canvasSize = NSSize(width: contentSize.width + snapshotMargin * 2,
                            height: contentSize.height + snapshotMargin * 2)

    let win = NSWindow(contentRect: NSRect(origin: .zero, size: canvasSize),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.isOpaque = false
    win.backgroundColor = .clear

    let v = BallView(frame: NSRect(origin: .zero, size: canvasSize))
    v.snapshotBackdrop = true
    v.snapshotWhite = CommandLine.arguments.contains("--bg-white")
    v.history = []
    v.expanded = expanded
    v.showPeriodStatistics = CommandLine.arguments.contains("--stats")
    v.ballStyle = snapStyle
    v.selfCPU = 0.4
    v.selfMemMB = 21
    v.intervalLabel = "1s"
    fill(v)
    v.recomputePeaks()
    v.settleAnimation()

    v.frame = NSRect(x: snapshotMargin, y: snapshotMargin,
                     width: contentSize.width, height: contentSize.height)
    win.contentView = v
    v.display()
    v.layoutSubtreeIfNeeded()

    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
        FileHandle.standardError.write("无法创建位图\n".data(using: .utf8)!)
        exit(1)
    }
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path)  (\(Int(v.bounds.width))x\(Int(v.bounds.height)))")
    } catch {
        FileHandle.standardError.write("写入失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

/// 把两种悬浮球样式渲染成对照图（自检用）
private func renderBallSnapshot(to path: String, demo: Bool) {
    _ = NSApplication.shared

    var scale: CGFloat = 2.0
    if let i = CommandLine.arguments.firstIndex(of: "--scale"), i + 1 < CommandLine.arguments.count,
       let v = Double(CommandLine.arguments[i + 1]) { scale = CGFloat(v) }

    // 用演示数据填满历史曲线，方便看胶囊里的走势图
    func demoHistory() -> [(rx: Double, tx: Double)] {
        var h: [(rx: Double, tx: Double)] = []
        for i in 0..<24 {
            let t = Double(i)
            h.append((rx: (2.0 + 2.6 * sin(t / 3.1) + 1.1 * sin(t / 1.3)) * 1048576,
                      tx: (0.7 + 0.5 * sin(t / 2.7)) * 1048576))
        }
        return h
    }

    // --levels：同一款球在几档速率下的样子（验证弧长确实在动、峰值刻度留在哪）
    if CommandLine.arguments.contains("--levels") {
        // (标题, 当前下行 MB/s, 当前上行 MB/s, 峰值参考下行 MB/s)
        // 峰值参考为 nil 时按当前值的 1.55 倍合成一段历史
        let levels: [(String, Double, Double, Double?)] = [
            ("空闲 0.05 / 0.02 MB/s", 0.05, 0.02, nil),
            ("轻载 1.5 / 0.3 MB/s", 1.5, 0.3, nil),
            ("中载 12 / 3 MB/s", 12, 3, nil),
            ("满载 80 / 20 MB/s", 80, 20, nil),
            ("刚回落到 0（峰值刻度仍在）", 0.0, 0.0, 12),
        ]
        let style = BallStyle(rawValue: CommandLine.arguments.firstIndex(of: "--style").flatMap {
            $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
        } ?? "") ?? .glass
        let size = style.collapsedSize
        let colW = max(240, size.width * scale + 60)
        let W = colW * CGFloat(levels.count)
        let H = 54 + size.height * scale + 70

        let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
            NSGradient(colors: [hx2(0x22, 0x30, 0x3E), hx2(0x10, 0x18, 0x21)])?
                .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
            let title: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor(white: 0.95, alpha: 1),
            ]
            let sub: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(white: 0.6, alpha: 1),
            ]
            NSAttributedString(string: "\(style.label) · 不同速率下的弧长（上弧＝下载，下弧＝上传）", attributes: title)
                .draw(at: NSPoint(x: 22, y: 16))
            NSAttributedString(string: "对数映射：1KB/s≈0 · 1MB/s≈0.6 · 100MB/s≈1", attributes: sub)
                .draw(at: NSPoint(x: 22, y: 36))

            for (i, lv) in levels.enumerated() {
                let v = BallView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
                v.ballStyle = style
                v.updateRates(rx: lv.1 * 1048576, tx: lv.2 * 1048576)
                // 合成一段历史，让峰值刻度落在当前值之上
                let refRx = lv.3 ?? lv.1
                let refTx = lv.3 == nil ? lv.2 : lv.2 + 3.0
                var hist: [(rx: Double, tx: Double)] = []
                for i in 0..<30 {
                    let t = Double(i)
                    let df = max(0.15, 1.0 + 0.55 * sin(t / 2.3))
                    let uf = max(0.15, 0.95 + 0.5 * cos(t / 3.1))
                    hist.append((rx: refRx * 1048576 * df, tx: refTx * 1048576 * uf))
                }
                v.history = hist
                v.recomputePeaks()
                v.settleAnimation()
                let originX = CGFloat(i) * colW + (colW - size.width * scale) / 2
                let originY: CGFloat = 60
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: originX, yBy: originY)
                t.scale(by: scale)
                t.concat()
                v.draw(v.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let label: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor(white: 0.9, alpha: 1),
                ]
                NSAttributedString(string: lv.0, attributes: label)
                    .draw(at: NSPoint(x: originX, y: originY + size.height * scale + 16))
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("levels -> \(path)")
        exit(0)
    }

    let styles = BallStyle.allCases
    let maxW = styles.map { $0.collapsedSize.width }.max() ?? 140
    let maxH = styles.map { $0.collapsedSize.height }.max() ?? 140
    let colW = max(300, maxW * scale + 90)
    let W = colW * CGFloat(styles.count)
    let H = 54 + maxH * scale + 70

    let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
        NSGradient(colors: [hx2(0x22, 0x30, 0x3E), hx2(0x10, 0x18, 0x21)])?
            .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
        for (col, alpha, rect) in [(hx2(0x31, 0xE1, 0xF7), CGFloat(0.05), NSRect(x: W * 0.6, y: H * 0.35, width: 420, height: 420)),
                                   (hx2(0xFF, 0x7A, 0xB6), 0.04, NSRect(x: -120, y: H * 0.5, width: 380, height: 380))] {
            col.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(white: 0.95, alpha: 1),
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ]
        NSAttributedString(string: "NetBall 悬浮球样式（\(scale == 1 ? "实际尺寸" : "放大 \(Int(scale)) 倍")）", attributes: titleAttrs)
            .draw(at: NSPoint(x: 22, y: 16))
        NSAttributedString(string: "菜单栏图标 / 球体右键 → 悬浮球样式，选择会被记住", attributes: subAttrs)
            .draw(at: NSPoint(x: 22, y: 36))

        for (i, st) in styles.enumerated() {
            let size = st.collapsedSize
            let v = BallView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
            v.ballStyle = st
            v.paused = false
            v.updateRates(rx: demo ? 8.4 * 1048576 : 0, tx: demo ? 1.2 * 1048576 : 0)
            v.history = demo ? demoHistory() : []
            v.recomputePeaks()
            v.settleAnimation()

            let originX = CGFloat(i) * colW + (colW - size.width * scale) / 2
            let originY: CGFloat = 60

            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: originX, yBy: originY)
            t.scale(by: scale)
            t.concat()
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()

            let label: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
            ]
            let sizeText = String(format: "%@ · 实际 %.0f×%.0f pt", st.label, size.width, size.height)
            NSAttributedString(string: sizeText, attributes: label)
                .draw(at: NSPoint(x: originX, y: originY + size.height * scale + 16))
        }
        return true
    }

    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("ball styles -> \(path)")
    exit(0)
}

/// 便捷颜色构造
private func hx2(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

/// 把所有菜单栏样式渲染成一张对照图（自检用，不需要截屏权限）
private func renderTraySnapshot(to path: String, demo: Bool) {
    _ = NSApplication.shared

    let styles = TrayStyle.allCases
    let scale: CGFloat = 3
    let rowH: CGFloat = 86
    let header: CGFloat = 52
    let W: CGFloat = 680
    let H = header + rowH * CGFloat(styles.count) + 16

    var down = demo ? "8.4M" : "0.0K"
    var up = demo ? "1.2M" : "0.0K"
    var total = demo ? "9.6M" : "0.0K"
    if let i = CommandLine.arguments.firstIndex(of: "--values"), i + 1 < CommandLine.arguments.count {
        let v = CommandLine.arguments[i + 1].split(separator: ",").map(String.init)
        if v.count == 3 { down = v[0]; up = v[1]; total = v[2] }
    }

    let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
        NSColor(white: 0.07, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.55, alpha: 1),
        ]
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.5, alpha: 1),
        ]

        NSAttributedString(string: "NetBall 菜单栏样式对照（放大 3 倍显示，右侧是实际尺寸）", attributes: titleAttrs)
            .draw(at: NSPoint(x: 20, y: 14))
        NSAttributedString(string: "深色/浅色菜单栏都会自动适配；图标宽度按模板值固定，数字跳动不会让图标左右抖",
                           attributes: subAttrs).draw(at: NSPoint(x: 20, y: 32))

        for (i, st) in styles.enumerated() {
            let y = header + CGFloat(i) * rowH
            NSColor(white: i % 2 == 0 ? 0.12 : 0.145, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: W, height: rowH - 8).fill()

            let lines = st.lines(down: down, up: up, total: total)
            let icon = trayIconImage(style: st, lines: lines, color: .white, template: false)
            let s3 = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)

            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 26, yBy: y + (rowH - 8 - s3.height) / 2)
            t.scale(by: scale)
            t.concat()
            icon.draw(in: NSRect(x: 0, y: 0, width: icon.size.width, height: icon.size.height))
            NSGraphicsContext.restoreGraphicsState()

            NSAttributedString(string: st.label, attributes: nameAttrs)
                .draw(at: NSPoint(x: 26 + s3.width + 24, y: y + 20))
            let sizeText = String(format: "实际 %.0f×%.0f pt · 字号 %.1f pt%@",
                                  icon.size.width, icon.size.height, st.fontSize,
                                  st.stacked ? " · 两行叠放" : "")
            NSAttributedString(string: sizeText, attributes: sizeAttrs)
                .draw(at: NSPoint(x: 26 + s3.width + 24, y: y + 42))
        }
        return true
    }

    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("tray styles -> \(path)")
    exit(0)
}

/// 采样器最新一次结果（跨线程取用）
private final class LiveBox {
    private let lock = NSLock()
    private var rows: [Sampler.Row] = []
    private var rx = 0.0
    private var tx = 0.0
    private var count = 0
    private var hist: [(rx: Double, tx: Double)] = []
    private var period = Sampler.PeriodStatistics(since: Date(), rxBytes: 0, txBytes: 0, processes: [])
    /// 不剔除代理核心的原始总量（代理穿透自检做对照用）
    private var raw: (rx: Double, tx: Double) = (0, 0)

    func update(_ r: [Sampler.Row], _ a: Double, _ b: Double, _ c: Int,
                raw: (rx: Double, tx: Double) = (0, 0),
                period: Sampler.PeriodStatistics? = nil) {
        lock.lock(); defer { lock.unlock() }
        rows = r; rx = a; tx = b; count = c; self.raw = raw
        if let period { self.period = period }
        hist.append((rx: a, tx: b))
        if hist.count > 60 { hist.removeFirst(hist.count - 60) }
    }

    var snapshot: ([Sampler.Row], Double, Double, Int, [(rx: Double, tx: Double)], Sampler.PeriodStatistics) {
        lock.lock(); defer { lock.unlock() }
        return (rows, rx, tx, count, hist, period)
    }

    var withRaw: (rows: [Sampler.Row], rx: Double, tx: Double, count: Int,
                  raw: (rx: Double, tx: Double)) {
        lock.lock(); defer { lock.unlock() }
        return (rows, rx, tx, count, raw)
    }
}

/// 采真实数据 N 秒后渲染，用来验证 UI 与解析链路是真的通了
private func renderLiveSnapshot(to path: String, seconds: Double) {
    let box = LiveBox()
    let s = Sampler()
    s.deliverQueue = DispatchQueue(label: "netball.live")
    s.onSnapshot = { rows, rx, tx, c, period in
        box.update(rows, rx, tx, c, raw: s.lastRawTotals, period: period)
    }
    s.setActive(true)   // 渲染的是展开面板，按展开档跑（这样「代理」标才会出现）
    s.start()

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let (rows, rx, tx, count, hist, period) = box.snapshot
    s.stop()
    FileHandle.standardError.write(
        "live: rows=\(rows.count) total=\(Fmt.rate(rx))/\(Fmt.rate(tx)) procs=\(count)\n".data(using: .utf8)!)

    var i = 0
    renderSnapshot(to: path, expanded: true) { v in
        v.rows = rows
        v.totalRx = rx
        v.totalTx = tx
        v.procCount = count
        v.history = hist
        v.periodStatistics = period
        i += 1
    }
    _ = i
}

// MARK: - 入口

let argv = CommandLine.arguments

func doubleArg(_ name: String, _ fallback: Double) -> Double {
    if let i = argv.firstIndex(of: name), i + 1 < argv.count, let v = Double(argv[i + 1]) { return v }
    return fallback
}

if let i = argv.firstIndex(of: "--snapshot-ball"), i + 1 < argv.count {
    renderBallSnapshot(to: argv[i + 1], demo: argv.contains("--demo"))
}

if argv.contains("--ease-test") {
    // 缓动自检：确认 0.4s 内走完、单调不回跳、收敛后定时器确实能停
    _ = NSApplication.shared
    let v = BallView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
    // 假时钟：每帧精确推进 50ms，等价于控制器里 1/20s 的定时器
    var fake = Date()
    v.clock = { fake }
    v.updateRates(rx: 12.0 * 1048576.0, tx: 3.0 * 1048576.0)   // 从 0 直接跳到中载
    let expected = (log10(12.0 * 1048576.0) - 3.0) / 5.0
    print("假时钟按 20fps 喂帧（每帧 50ms），和控制器里那个定时器同节奏：")
    var frames = 0
    var prev = v.shownRxLevel
    var jumpedBack = false
    while v.needsAnimation() && frames < 20 {
        fake = fake.addingTimeInterval(1.0 / 20)
        let done = v.stepAnimation()
        frames += 1
        if v.shownRxLevel < prev - 0.0001 { jumpedBack = true }
        prev = v.shownRxLevel
        print(String(format: "  第 %2d 帧  t=%4.0fms  下载弧=%.4f  上传弧=%.4f%@",
                     frames, Double(frames) * 50, v.shownRxLevel, v.shownTxLevel,
                     done ? "  ← 收敛，停表" : ""))
    }
    print(String(format: "结果：%d 帧 / %.0fms（目标 %.0fms）",
                 frames, Double(frames) * 50, BallView.arcEaseSeconds * 1000))
    print(String(format: "      终值 %.4f（应为 %.4f）  单调不回跳=%@  收敛后 needsAnimation=%@",
                 v.shownRxLevel, expected, jumpedBack ? "否" : "是",
                 v.needsAnimation() ? "否（还在跑）" : "是（已停）"))
    exit(0)
}

if argv.contains("--stats-test") {
    var acc = Sampler.PeriodAccumulator()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    acc.reset(at: start)
    acc.add(name: "curl", rx: 2_048, tx: 512, viaProxy: true)
    acc.add(name: "curl", rx: 1_024, tx: 256, viaProxy: false)
    acc.add(name: "Safari", rx: 4_096, tx: 128, viaProxy: false)
    let sample = acc.snapshot()
    precondition(sample.rxBytes == 7_168 && sample.txBytes == 896)
    precondition(sample.processes.count == 2)
    precondition(sample.processes[0].name == "Safari")
    precondition(sample.processes[1].rxBytes == 3_072 && sample.processes[1].txBytes == 768)
    precondition(sample.processes[1].viaProxy)
    precondition(sample.sortedProcesses(byUpload: false).first?.name == "Safari") // 默认按下载量降序
    precondition(sample.sortedProcesses(byUpload: true).first?.name == "curl")  // 上传列点击后改按上传量降序
    precondition(sample.sortedProcesses(byUpload: false, ascending: true).first?.name == "curl")
    var sort = Sampler.StatisticsSortState()
    precondition(sort.column == .download && !sort.ascending)
    sort.click(.upload)
    precondition(sort.column == .upload && !sort.ascending)
    sort.click(.upload)
    precondition(sort.column == .upload && sort.ascending)
    sort.click(.download)
    precondition(sort.column == .download && !sort.ascending)
    acc.reset(at: start.addingTimeInterval(60))
    precondition(acc.snapshot().rxBytes == 0 && acc.snapshot().processes.isEmpty)
    precondition(Fmt.bytes(1_536) == "1.5 KB")
    print("统计自检通过：同名进程合并、上下行分别累计、下载/上传排序与升降序切换、重置清零、单位格式正确")
    exit(0)
}

if argv.contains("--draw-cost") {
    // 单帧重绘代价自检：不依赖定时器精度（沙箱/负载下 Timer 会明显偏慢），
    // 直接同步重绘 N 帧、量自己的 CPU 时间，再换算成"20fps 要多花几个百分点"。
    _ = NSApplication.shared
    let frames = Int(doubleArg("--draw-cost", 400))
    let size = BallStyle.glass.collapsedSize
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.isOpaque = false
    win.backgroundColor = .clear
    let v = BallView(frame: NSRect(origin: .zero, size: size))
    win.contentView = v

    var fake = Date()
    v.clock = { fake }
    func jump(_ i: Int) {
        v.updateRates(rx: (2.0 + 2.6 * sin(Double(i) / 3.1)) * 1048576,
                      tx: (0.7 + 0.5 * sin(Double(i) / 2.7)) * 1048576)
    }
    jump(0)
    // 只能量 offscreen：窗口在这个会话里没有被真正合成，display() 会被 AppKit 直接跳过，
    // 量出来是 0.005ms/帧 的假数（踩过）。cacheDisplay 一定真的走 draw(_:)，
    // drawCount 对账。注意这是"纯绘制"成本，不含窗口合成/WindowServer 那一层。
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
    func render() { v.cacheDisplay(in: v.bounds, to: rep) }
    for _ in 0..<20 { render() }   // 热身：字体与缓存位图别算进第一帧

    let drawn0 = v.drawCount
    let cpu0 = cpuSeconds(getpid()) ?? 0
    let wall0 = Date()
    for i in 0..<frames {
        if !v.needsAnimation() { jump(i) }                   // 保证每帧都走"缓动中重绘"这条路
        fake = fake.addingTimeInterval(1.0 / 20)
        _ = v.stepAnimation()
        render()
    }
    let cpuMs = ((cpuSeconds(getpid()) ?? 0) - cpu0) * 1000
    let wall = Date().timeIntervalSince(wall0)
    let drawn = v.drawCount - drawn0
    guard drawn > 0 else {
        FileHandle.standardError.write("drawCount=0，这一轮没真正重绘，数字不可信\n".data(using: .utf8)!)
        exit(1)
    }
    let perFrame = cpuMs / Double(drawn)
    print(String(format: "纯绘制 %d 帧（drawCount 对账 %d）：CPU %.1fms  单帧 %.3fms  速度 %.0f 帧/秒",
                 frames, drawn, cpuMs, perFrame, Double(drawn) / wall))
    print(String(format: "  若 20fps 一直跑：额外 ≈ %.1f%% CPU", perFrame * 20 / 10))
    print(String(format: "  实际占空比（1s 采样 / 0.4s 缓动，其中 1 帧本来也要画）≈ %.1f%% CPU",
                 perFrame * 7 / 10))
    print(String(format: "  2s 采样（默认档）≈ %.1f%% CPU", perFrame * 7 / 20))
    print("  端到端（含窗口合成）用 --benchmark 做 A/B：--anim-off vs --anim-demo")
    exit(0)
}

if argv.contains("--proxy-test") {
    // 代理穿透自检：开一次真实采样（面板展开档），同一份数据里同时给出
    // "不剔除代理核心"和"剔除后"两个总量，不用开 GUI 也能验证虚高修掉了多少。
    // 取整段里流量最大的那一次采样 —— 下载这类短时流量只出现在中间某几拍。
    _ = NSApplication.shared
    let secs = doubleArg("--proxy-test", 8)
    let box = LiveBox()
    let s = Sampler()
    s.deliverQueue = DispatchQueue(label: "netball.proxytest")
    s.setIntervals(idle: 1.0, active: 1.0)
    s.setActive(true)
    s.onSnapshot = { rows, rx, tx, n, period in
        box.update(rows, rx, tx, n, raw: s.lastRawTotals, period: period)
    }
    s.start()

    var best = box.withRaw
    let deadline = Date().addingTimeInterval(secs)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let cur = box.withRaw
        if cur.raw.rx + cur.raw.tx > best.raw.rx + best.raw.tx { best = cur }
    }
    s.stop()

    print("控制器端点: \(s.proxy.endpointDesc ?? "没找到 —— 不做穿透，保持原样")")
    print("代理核心 PID: \(s.proxy.corePIDs.sorted())  （从排行和总量里剔除）")
    print("走代理的 PID: \(s.proxy.proxiedPIDs.sorted())")
    print(String(format: "\n峰值那一刻："))
    print(String(format: "  不剔除（nettop 原样）  ↓%-12@ ↑%-12@",
                 Fmt.rate(best.raw.rx) as NSString, Fmt.rate(best.raw.tx) as NSString))
    print(String(format: "  剔除后（实际显示）      ↓%-12@ ↑%-12@   进程数 %d",
                 Fmt.rate(best.rx) as NSString, Fmt.rate(best.tx) as NSString, best.count))
    let rt = best.raw.rx + best.raw.tx, ft = best.rx + best.tx
    if rt > 0 {
        print(String(format: "  → 原来虚高了 %.0f%%（同一个字节被代理核心重复记的那部分）", (1 - ft / rt) * 100))
    }
    print("\n排行（剔除后）:")
    for r in best.rows.prefix(8) {
        print(String(format: "  %-24@ pid %-7d ↓%-11@ ↑%-11@%@",
                     r.name as NSString, r.pid, Fmt.rate(r.rx) as NSString,
                     Fmt.rate(r.tx) as NSString, (r.viaProxy ? "  [代理]" : "") as NSString))
    }
    exit(0)
}

if argv.contains("--fmt-test") {
    let samples: [(String, Double)] = [
        ("0 B/s", 0), ("512 B/s", 512), ("1.5 KB/s", 1536), ("15.5 KB/s", 15872),
        ("99.9 KB/s", 102298), ("100 KB/s", 102400), ("155.0 KB/s", 158720),
        ("286.0 KB/s", 292864), ("999.9 KB/s", 1023898), ("1.0 MB/s", 1048576),
        ("9.6 MB/s", 10066330), ("155 MB/s", 162529280), ("999.9 MB/s", 1048473600),
        ("1.5 GB/s", 1610612736), ("12.3 GB/s", 13207024435),
    ]
    print("值 → 菜单栏字符串（长度）")
    var maxLen = 0
    for (label, v) in samples {
        let out = Fmt.tray(v)
        maxLen = max(maxLen, out.count)
        print(String(format: "  %-12@ → %-6@ (%d)", label as NSString, out as NSString, out.count))
    }
    print("最长 \(maxLen) 字符（模板宽 5 字符，超长也不会被裁）")
    exit(0)
}

if let i = argv.firstIndex(of: "--snapshot-tray"), i + 1 < argv.count {
    renderTraySnapshot(to: argv[i + 1], demo: argv.contains("--demo"))
}

if let i = argv.firstIndex(of: "--snapshot-live"), i + 1 < argv.count {
    renderLiveSnapshot(to: argv[i + 1], seconds: doubleArg("--after", 6))
}

if let i = argv.firstIndex(of: "--snapshot"), i + 1 < argv.count {
    let expanded = !argv.contains("--ball")
    let demo = argv.contains("--demo")
    renderSnapshot(to: argv[i + 1], expanded: expanded) { v in
        if demo {
            func mb(_ x: Double) -> Double { x * 1048576 }
            func kb(_ x: Double) -> Double { x * 1024 }
            // 走 updateRates 而不是直接塞 totalRx/totalTx：弧线现在读的是缓动后的显示值，
            // 绕过它会让 --ball 快照画出一条空弧（这个坑踩过一次）
            v.updateRates(rx: mb(8.4), tx: mb(1.2))
            v.procCount = 7
            v.rows = [
                Sampler.Row(name: "Google Chrome", pid: 45565, rx: mb(5.8), tx: kb(120), viaProxy: true),
                Sampler.Row(name: "WeChat", pid: 52526, rx: mb(1.6), tx: kb(340)),
                Sampler.Row(name: "node", pid: 798, rx: kb(210), tx: kb(64), viaProxy: true),
                Sampler.Row(name: "Google Chrome Helper", pid: 45599, rx: kb(96), tx: kb(18), viaProxy: true),
                Sampler.Row(name: "Dropbox", pid: 900, rx: kb(88), tx: kb(12)),
            ]
            var hist: [(rx: Double, tx: Double)] = []
            for i in 0..<48 {
                let t = Double(i)
                let down = mb(2.0 + 2.4 * sin(t / 4.1) + 1.4 * sin(t / 1.7))
                let up = mb(0.6 + 0.5 * sin(t / 3.3 + 1))
                hist.append((rx: down, tx: up))
            }
            v.history = hist
            if v.showPeriodStatistics {
                let processes = [
                    Sampler.ProcessTotal(name: "Google Chrome", rxBytes: 8_420_000_000, txBytes: 1_120_000_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "WeChat", rxBytes: 4_210_000_000, txBytes: 830_000_000, viaProxy: false),
                    Sampler.ProcessTotal(name: "node", rxBytes: 2_800_000_000, txBytes: 210_000_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "Google Chrome Helper", rxBytes: 1_780_000_000, txBytes: 440_000_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "Dropbox", rxBytes: 940_000_000, txBytes: 150_000_000, viaProxy: false),
                    Sampler.ProcessTotal(name: "Safari", rxBytes: 620_000_000, txBytes: 87_000_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "Steam Helper", rxBytes: 340_000_000, txBytes: 92_000_000, viaProxy: false),
                    Sampler.ProcessTotal(name: "Tailscale", rxBytes: 120_000_000, txBytes: 3_400_000_000, viaProxy: false),
                ]
                v.periodStatistics = Sampler.PeriodStatistics(
                    since: Date().addingTimeInterval(-3 * 3600 - 27 * 60),
                    rxBytes: processes.reduce(0) { $0 &+ $1.rxBytes },
                    txBytes: processes.reduce(0) { $0 &+ $1.txBytes },
                    processes: processes
                )
            }
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
