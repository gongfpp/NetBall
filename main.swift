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

/// PID 必须连同进程创建时间一起使用，避免退出后复用 PID 把流量归给旧应用。
private func processIncarnation(_ pid: Int) -> String? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    if proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
       info.pbi_start_tvsec > 0 {
        return processLifetime(pid: pid, bsdStart: (info.pbi_start_tvsec, info.pbi_start_tvusec), absoluteStart: nil)
    }
    // 部分进程无法读取 BSD 元数据时，仍可用内核提供的启动时钟验证同一生命周期。
    // 两种接口均不可读就不猜 PID 身份，也不生成每轮变化的伪启动时间。
    return processLifetime(pid: pid, bsdStart: nil, absoluteStart: rusageV6(pid_t(pid))?.ri_proc_start_abstime)
}

private func processLifetime(pid: Int, bsdStart: (UInt64, UInt64)?, absoluteStart: UInt64?) -> String? {
    if let (seconds, micros) = bsdStart, seconds > 0 { return "\(pid):\(seconds):\(micros)" }
    if let start = absoluteStart, start > 0 { return "\(pid):absolute:\(start)" }
    return nil
}

/// 把 nettop 的通用 runtime 名称映射成可辨认的应用/项目身份，并为 uv 显示可执行文件路径。
/// 只显示应用包名或脚本/工作目录/可执行文件路径；完整命令行只在内存里解析，绝不展示其余参数。
private final class ProcessIdentityResolver {
    struct Identity {
        let name: String
        let fullPath: String?
    }

    private var cache: [Int: (sourceName: String, incarnation: String?, identity: Identity)] = [:]

    func retain(only pids: Set<Int>) {
        // 暂时没有 socket 不等于进程退出；复用身份前仍校验 PID 创建时间。
        // 保留少量离线身份，避免 Node 间歇联网反复触发 ps/目录查询。
        if cache.count > 512 { cache = cache.filter { pids.contains($0.key) } }
    }

    func resolve(_ processes: [(name: String, pid: Int)]) -> [Int: Identity] {
        let lifetimes: [Int: String] = Dictionary(uniqueKeysWithValues: processes.compactMap { process in
            guard let lifetime = processIncarnation(process.pid) else { return nil }
            return (process.pid, lifetime)
        })
        let missing = processes.filter {
            cache[$0.pid]?.sourceName != $0.name || lifetimes[$0.pid] == nil
                || cache[$0.pid]?.incarnation != lifetimes[$0.pid]
        }
        let electronProcesses = missing.filter { Self.isElectron($0.name) }
        let nodeProcesses = missing.filter { Self.isNode($0.name) }
        let uvProcesses = missing.filter { Self.isUV($0.name) }

        for process in electronProcesses {
            let executable = Self.executablePath(pid: process.pid)
            let bundlePath = executable.flatMap(Self.outermostAppBundlePath(from:))
            let appBundle = bundlePath.flatMap { Bundle(url: URL(fileURLWithPath: $0)) }
            let appName = appBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? appBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? NSRunningApplication(processIdentifier: pid_t(process.pid))?.localizedName
            let name = appName.flatMap { Self.isUsefulAppName($0) ? $0 : nil }
                ?? bundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? process.name
            let fullPath = bundlePath ?? executable
            cache[process.pid] = (process.name, lifetimes[process.pid], Identity(name: name, fullPath: fullPath))
        }

        for process in uvProcesses {
            let executable = Self.executablePath(pid: process.pid)
            cache[process.pid] = (process.name, lifetimes[process.pid], Identity(name: process.name, fullPath: executable))
        }

        if !nodeProcesses.isEmpty {
            let cwdByPID = Self.workingDirectories(pids: nodeProcesses.map(\.pid))
            let commandByPID = Self.commandLines(pids: nodeProcesses.map(\.pid))
            for process in nodeProcesses {
                let cwd = cwdByPID[process.pid]
                let executable = Self.executablePath(pid: process.pid)
                let script = Self.nodeEntrypoint(from: commandByPID[process.pid], workingDirectory: cwd)
                let projectDirectory = Self.projectDirectory(for: script, workingDirectory: cwd)
                let location = projectDirectory ?? script ?? cwd ?? executable
                let label: String
                if let projectDirectory {
                    label = "node · \(URL(fileURLWithPath: projectDirectory).lastPathComponent)"
                } else if let script {
                    label = "node · \(URL(fileURLWithPath: script).lastPathComponent)"
                } else if let cwd {
                    label = "node · \(URL(fileURLWithPath: cwd).lastPathComponent)"
                } else {
                    label = process.name
                }
                cache[process.pid] = (process.name, lifetimes[process.pid], Identity(name: label, fullPath: location))
            }
        }

        for process in missing where !Self.isElectron(process.name) && !Self.isNode(process.name) && !Self.isUV(process.name) {
            let executable = Self.executablePath(pid: process.pid)
            let bundlePath = executable.flatMap(Self.outermostAppBundlePath(from:))
            let bundle = bundlePath.flatMap { Bundle(path: $0) }
            let label = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? process.name
            cache[process.pid] = (process.name, lifetimes[process.pid],
                                  Identity(name: label, fullPath: bundlePath ?? executable))
        }

        return Dictionary(uniqueKeysWithValues: processes.compactMap { process in
            guard let entry = cache[process.pid], entry.sourceName == process.name,
                  entry.incarnation == lifetimes[process.pid] else { return nil }
            return (process.pid, entry.identity)
        })
    }

    static func isElectron(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("electron")
    }

    static func isNode(_ name: String) -> Bool {
        ["node", "nodejs"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isUV(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "uv"
    }

    static func outermostAppBundlePath(from executablePath: String) -> String? {
        var current = URL(fileURLWithPath: executablePath).standardizedFileURL
        var outermost: URL?
        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" { outermost = current }
            current.deleteLastPathComponent()
        }
        return outermost?.path
    }

    /// 从 Node 启动参数中只取入口脚本路径；忽略 `-e`、预加载脚本及包管理器自身入口。
    static func nodeEntrypoint(from commandLine: String?, workingDirectory: String?) -> String? {
        guard let commandLine else { return nil }
        let tokens = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return nil }
        let valueFlags: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader",
                                       "--conditions", "--inspect-port", "--title"]
        let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts"]
        var i = 1
        while i < tokens.count {
            let token = unquote(tokens[i])
            if token == "-e" || token == "--eval" { return nil }
            if valueFlags.contains(token) { i += 2; continue }
            if token.hasPrefix("--require=") || token.hasPrefix("--import=")
                || token.hasPrefix("--loader=") { i += 1; continue }
            if token.hasPrefix("-") { i += 1; continue }

            let last = min(tokens.count - 1, i + 10)
            for end in i...last {
                let candidate = unquote(tokens[i...end].joined(separator: " "))
                let ext = URL(fileURLWithPath: candidate).pathExtension.lowercased()
                let isBinScript = candidate.contains("/node_modules/.bin/")
                guard scriptExtensions.contains(ext) || isBinScript else { continue }
                let normalized = absolutePath(candidate, workingDirectory: workingDirectory)
                if isPackageManagerBootstrap(normalized) { continue }
                return normalized
            }
            i += 1
        }
        return nil
    }

    static func projectDirectory(for script: String?, workingDirectory: String?) -> String? {
        guard let script, let workingDirectory else { return nil }
        let cwd = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        return script.hasPrefix(cwd + "/node_modules/") ? cwd : nil
    }

    static func isPackageManagerBootstrap(_ path: String) -> Bool {
        let normalized = path.lowercased()
        return normalized.contains("/node_modules/npm/bin/npm-cli.js")
            || normalized.contains("/node_modules/pnpm/bin/pnpm.cjs")
            || normalized.contains("/node_modules/yarn/bin/yarn.js")
    }

    private static func isUsefulAppName(_ name: String) -> Bool {
        !name.isEmpty && !name.localizedCaseInsensitiveContains("electron")
            && !name.localizedCaseInsensitiveContains("helper")
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'"))
    }

    private static func absolutePath(_ path: String, workingDirectory: String?) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.hasPrefix("/") else {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        guard let workingDirectory else { return expanded }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
            .standardizedFileURL.path
    }

    private static func executablePath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let size = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func commandLines(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty,
              let output = runTool("/bin/ps", ["-ww", "-p", pids.map { String($0) }.joined(separator: ","), "-o", "pid=,command="]) else {
            return [:]
        }
        var result: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int(fields[0]) else { continue }
            result[pid] = String(fields[1])
        }
        return result
    }

    private static func workingDirectories(pids: [Int]) -> [Int: String] {
        var result: [Int: String] = [:]
        for pid in pids {
            var info = proc_vnodepathinfo()
            let size = MemoryLayout<proc_vnodepathinfo>.size
            guard proc_pidinfo(pid_t(pid), PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { result[pid] = path }
        }
        return result
    }
}

// MARK: - 采样器
//
// 为什么不用 `nettop -l 0` 长驻流式：实测它在两次采样之间忙等，持续吃掉 1.0~1.4 个核
// （见 tools/nettop-cost.swift）。单次快照 `nettop -l 1` 只要 ~0.018s CPU / ~0.14s wall，
// 所以这里改成"按间隔跑一次单发快照 + 与上一次做差分"，开销降到 ~1~2%。

/// 从 macOS 接口计数器读取物理网络设备流量。只统计 enN，避免把 lo0 回环、utun VPN
/// 隧道和 bridge/awdl 等虚拟接口再次算入总额。应用明细另由连接账本归属，不能反推物理总量。
private struct ExternalInterfaceSnapshot {
    struct Counters {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var identity: String? = nil

        mutating func add(rx: UInt64, tx: UInt64) {
            self.rx &+= rx
            self.tx &+= tx
        }
    }

    let byInterface: [String: Counters]
    var interfaceNames: [String] { byInterface.keys.sorted() }

    func delta(since previous: ExternalInterfaceSnapshot) -> Counters {
        var result = Counters()
        for (name, current) in byInterface {
            guard let old = previous.byInterface[name], old.identity == current.identity,
                  current.rx >= old.rx, current.tx >= old.tx else { continue }
            // 同名接口重建或任一计数回退时整轮重建基线，不把设备历史或复位猜成流量。
            result.add(rx: current.rx - old.rx, tx: current.tx - old.tx)
        }
        return result
    }

    static func isExternalInterfaceName(_ name: String) -> Bool {
        guard name.hasPrefix("en"), name.count > 2 else { return false }
        return name.dropFirst(2).allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    static func read() -> ExternalInterfaceSnapshot? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // 接口可能在两次 sysctl 之间增加；缓冲区不足就重新读取，不能把截断快照当成功。
        for _ in 0..<3 {
            var count = 0
            guard sysctl(&mib, u_int(mib.count), nil, &count, nil, 0) == 0,
                  count > 0, count <= 16 * 1024 * 1024 else { return nil }
            var data = Data(count: count)
            let result = data.withUnsafeMutableBytes { bytes in
                sysctl(&mib, u_int(mib.count), bytes.baseAddress, &count, nil, 0)
            }
            if result == 0 {
                guard count <= data.count else { return nil }
                return parse(Data(data.prefix(count)))
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    /// NET_RT_IFLIST2 的 if_data64 才是真正的 64 位字节计数；扩大旧 if_data 类型无效。
    static func parse(_ data: Data) -> ExternalInterfaceSnapshot? {
        data.withUnsafeBytes { bytes -> ExternalInterfaceSnapshot? in
            var byInterface: [String: Counters] = [:]
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return nil }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset,
                      bytes[offset + 2] == UInt8(RTM_VERSION) else { return nil }
                defer { offset += length }
                guard bytes[offset + 3] == UInt8(RTM_IFINFO2) else { continue }
                let headerSize = MemoryLayout<if_msghdr2>.size
                guard length >= headerSize + 8 else { return nil }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard (header.ifm_addrs & RTA_IFP) != 0 else { return nil }
                let link = offset + headerSize
                let linkLength = Int(bytes[link]), nameLength = Int(bytes[link + 5])
                let addressLength = Int(bytes[link + 6])
                guard linkLength >= 8, linkLength <= length - headerSize,
                      bytes[link + 1] == UInt8(AF_LINK), nameLength > 0,
                      8 + nameLength + addressLength <= linkLength,
                      bytes.loadUnaligned(fromByteOffset: link + 2, as: UInt16.self) == header.ifm_index else { return nil }
                let nameBytes = UnsafeRawBufferPointer(rebasing: bytes[(link + 8)..<(link + 8 + nameLength)])
                guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }
                guard isExternalInterfaceName(name), (header.ifm_flags & IFF_UP) != 0 else { continue }
                guard byInterface[name] == nil else { return nil }
                let address = bytes[(link + 8 + nameLength)..<(link + 8 + nameLength + addressLength)]
                    .map { String(format: "%02x", $0) }.joined()
                let identity = "\(header.ifm_index):\(bytes[link + 4]):\(address)"
                byInterface[name] = Counters(rx: header.ifm_data.ifi_ibytes, tx: header.ifm_data.ifi_obytes,
                                             identity: identity)
            }
            return ExternalInterfaceSnapshot(byInterface: byInterface)
        }
    }

    static func runTests() {
        func message(_ name: String, index: UInt16 = 4, rx: UInt64, tx: UInt64 = 200,
                     address: [UInt8] = [0, 1, 2, 3, 4, 5], up: Bool = true) -> Data {
            let nameBytes = Array(name.utf8)
            let linkLength = 8 + nameBytes.count + address.count
            var header = if_msghdr2()
            header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + linkLength)
            header.ifm_version = UInt8(RTM_VERSION)
            header.ifm_type = UInt8(RTM_IFINFO2)
            header.ifm_addrs = RTA_IFP
            header.ifm_flags = up ? IFF_UP : 0
            header.ifm_index = index
            header.ifm_data.ifi_ibytes = rx
            header.ifm_data.ifi_obytes = tx
            var data = withUnsafeBytes(of: &header) { Data($0) }
            var link: [UInt8] = [UInt8(linkLength), UInt8(AF_LINK), 0, 0, 6, UInt8(nameBytes.count), UInt8(address.count), 0]
            withUnsafeBytes(of: index) { link.replaceSubrange(2..<4, with: $0) }
            data.append(contentsOf: link + nameBytes + address)
            return data
        }
        let beforeWrap = UInt64(UInt32.max) - 99
        let old = parse(message("en0", rx: beforeWrap))!
        let new = parse(message("en0", rx: beforeWrap + 200, tx: 250))!
        precondition(new.delta(since: old).rx == 200 && new.delta(since: old).tx == 50)
        precondition(new.byInterface["en0"]!.rx > UInt64(UInt32.max))
        let replaced = parse(message("en0", index: 9, rx: beforeWrap + 999))!
        precondition(replaced.delta(since: old).rx == 0)
        let newAddress = parse(message("en0", rx: beforeWrap + 999, address: [6, 7, 8, 9, 10, 11]))!
        precondition(newAddress.delta(since: old).rx == 0)
        let reset = parse(message("en0", rx: 10, tx: 500))!
        precondition(reset.delta(since: old).rx == 0 && reset.delta(since: old).tx == 0)
        precondition(parse(message("lo0", rx: 999))!.byInterface.isEmpty)
        precondition(parse(message("en0", rx: 999, up: false))!.byInterface.isEmpty)
        let complete = message("en0", rx: 999)
        for count in 1..<complete.count { precondition(parse(Data(complete.prefix(count))) == nil) }
        precondition(parse(complete + complete) == nil)
        var malformed = complete
        malformed[0] = 0; malformed[1] = 0
        precondition(parse(malformed) == nil)
        malformed = complete; malformed[2] = 0
        precondition(parse(malformed) == nil)
        malformed = complete; malformed[MemoryLayout<if_msghdr2>.size + 5] = 250
        precondition(parse(malformed) == nil)
        precondition(processLifetime(pid: 12, bsdStart: (100, 2), absoluteStart: 999) == "12:100:2")
        precondition(processLifetime(pid: 12, bsdStart: nil, absoluteStart: 999) == "12:absolute:999")
        precondition(processLifetime(pid: 12, bsdStart: nil, absoluteStart: 0) == nil)
        precondition(processLifetime(pid: 12, bsdStart: nil, absoluteStart: nil) == nil)
        print("ExternalInterfaceTests: passed (64-bit, interface lifetime, reset, truncated messages, process birth fallback)")
    }
}

final class Sampler {
    static let unassignedTrafficName = "未归属流量"

    // 需要连接元组来做代理归属；读取回环仅用于匹配，绝不把回环原始字节加入明细。
    // 参数顺序和 -c 都经过实测：避免 nettop 在首次快照前忙等；保留累计字节，不用 -d。
    static let nettopArguments = ["-x", "-n", "-L", "1", "-J", "interface,state,bytes_in,bytes_out", "-c"]

    struct Row {
        let name: String
        let pid: Int
        let rx: Double  // bytes/s 下行
        let tx: Double  // bytes/s 上行
        /// 只为 Electron / Node 补充应用包、入口脚本或工作目录路径
        var fullPath: String? = nil
        /// 这条流量是经代理出去的（ProxyProbe 打标）
        var viaProxy = false
        var total: Double { rx + tx }
        var isUnassigned: Bool { name == Sampler.unassignedTrafficName && fullPath == nil }
    }

    struct ProcessTotal {
        let name: String
        var rxBytes: UInt64
        var txBytes: UInt64
        var viaProxy: Bool
        var fullPath: String? = nil
        var totalBytes: UInt64 { rxBytes &+ txBytes }
        var identityKey: String { name + "\u{0}" + (fullPath ?? "") }
        var isUnassigned: Bool { name == Sampler.unassignedTrafficName && fullPath == nil }
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

    /// Convert wheel/trackpad deltas to whole process-row steps; ignore zero and sub-row jitter.
    struct StatisticsScrollAccumulator {
        private var preciseRemainder: CGFloat = 0
        private static let preciseStep: CGFloat = 46

        mutating func consume(deltaY: CGFloat, precise: Bool) -> Int {
            guard deltaY.isFinite, abs(deltaY) > 0.001 else { return 0 }
            guard precise else { return deltaY > 0 ? -1 : 1 }
            preciseRemainder += deltaY
            let steps = Int(preciseRemainder / Self.preciseStep)
            guard steps != 0 else { return 0 }
            preciseRemainder -= CGFloat(steps) * Self.preciseStep
            return -steps
        }

        mutating func reset() {
            preciseRemainder = 0
        }
    }

    struct PeriodStatistics {
        let since: Date
        /// 系统物理网络接口累计字节；应用明细为代理 payload + 去重后的直连 socket 字节。
        let rxBytes: UInt64
        let txBytes: UInt64
        let externalInterfaces: [String]
        let processes: [ProcessTotal]
        var attributionStatus: String = "归属待采样"

        func sortedProcesses(byUpload: Bool, ascending: Bool = false) -> [ProcessTotal] {
            processes.sorted { a, b in
                let primaryA = byUpload ? a.txBytes : a.rxBytes
                let primaryB = byUpload ? b.txBytes : b.rxBytes
                if primaryA != primaryB { return ascending ? primaryA < primaryB : primaryA > primaryB }
                let secondaryA = byUpload ? a.rxBytes : a.txBytes
                let secondaryB = byUpload ? b.rxBytes : b.txBytes
                if secondaryA != secondaryB { return secondaryA > secondaryB }
                let nameOrder = a.name.localizedCaseInsensitiveCompare(b.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return (a.fullPath ?? "").localizedCaseInsensitiveCompare(b.fullPath ?? "") == .orderedAscending
            }
        }
    }

    /// 总量取物理网卡计数；明细仅累加连接账本产出的去重增量。
    /// 同一应用或 Node 入口的多个 PID 在明细里归并一行。
    struct PeriodAccumulator {
        private(set) var since = Date()
        private(set) var rxBytes: UInt64 = 0
        private(set) var txBytes: UInt64 = 0
        private(set) var externalInterfaces: [String] = []
        private var byIdentity: [String: ProcessTotal] = [:]
        private var attributionStatus = "归属待采样"

        mutating func setAttributionStatus(_ status: String) { attributionStatus = status }

        mutating func addExternal(rx: UInt64, tx: UInt64, interfaces: [String]) {
            rxBytes &+= rx
            txBytes &+= tx
            externalInterfaces = interfaces
        }

        mutating func add(name: String, rx: UInt64, tx: UInt64, viaProxy: Bool, fullPath: String? = nil) {
            let identity = ProcessTotal(name: name, rxBytes: 0, txBytes: 0, viaProxy: false, fullPath: fullPath)
            var p = byIdentity[identity.identityKey] ?? identity
            p.rxBytes &+= rx
            p.txBytes &+= tx
            p.viaProxy = p.viaProxy || viaProxy
            byIdentity[identity.identityKey] = p
        }

        mutating func reset(at date: Date = Date()) {
            since = date
            rxBytes = 0
            txBytes = 0
            externalInterfaces = []
            attributionStatus = "归属待采样"
            byIdentity.removeAll(keepingCapacity: true)
        }

        func snapshot() -> PeriodStatistics {
            let rows = byIdentity.values.sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return ($0.fullPath ?? "").localizedCaseInsensitiveCompare($1.fullPath ?? "") == .orderedAscending
            }
            return PeriodStatistics(since: since, rxBytes: rxBytes, txBytes: txBytes,
                                    externalInterfaces: externalInterfaces, processes: rows,
                                    attributionStatus: attributionStatus)
        }
    }

    /// 回调：实时排行 / 速率 / 进程数 + 自启动或重置以来的累计统计
    var onSnapshot: (([Row], Double, Double, Int, PeriodStatistics) -> Void)?
    private(set) var snapshotTime = Date()
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
    private let detailQueue = DispatchQueue(label: "netball.connections", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var running = false
    private var needsResumeBaseline = false
    private var detailBudget = SamplingBudget()
    private var detailProvider: (() -> DetailSample)? // 仅自检注入阻塞扫描，生产默认为 nil。
    private var detailGeneration = 0
    private var detailRows: [Row] = []
    private var detailRawTotals = (rx: 0.0, tx: 0.0)
    private var detailCoreTotals = (rx: 0.0, tx: 0.0)
    private var physicalRates = (rx: 0.0, tx: 0.0)
    private(set) var detailInterval = SamplingBudget.minimumInterval
    private(set) var detailScans = 0
    private var rawBaselines: [String: (rx: UInt64, tx: UInt64, at: Date)] = [:]
    private var attribution = AttributionLedger()
    private var previousExternalSnapshot: ExternalInterfaceSnapshot?
    private var lastTick = Date()
    private var inFlight = false
    private var periodAccumulator = PeriodAccumulator()
    private let processIdentityResolver = ProcessIdentityResolver()
    // 仅用于身份读取失败时保留旧 socket 基线；绝不据此认领该轮的应用流量。
    private var verifiedLifetimes: [Int: String] = [:]

    /// 读取当前统计（与采样队列串行，避免跨线程读写竞态）
    func currentPeriodStatistics() -> PeriodStatistics {
        queue.sync { periodAccumulator.snapshot() }
    }

    /// 从此刻重新开始统计；清空基线，避免把重置前最后一个采样间隔算进来
    @discardableResult
    func resetPeriodStatistics() -> PeriodStatistics {
        queue.sync {
            let now = Date()
            detailGeneration += 1
            periodAccumulator.reset(at: now)
            detailRows = []
            detailBudget.requestRefresh()
            // 队列顺序保证旧扫描先结束、再清基线；旧结果用 generation 丢弃。
            // 不在主线程等待昂贵扫描，重置立即生效。
            detailQueue.async { [self] in
                attribution.reset(at: now)
                rawBaselines.removeAll(keepingCapacity: true)
            }
            previousExternalSnapshot = ExternalInterfaceSnapshot.read()
            lastTick = now
            return periodAccumulator.snapshot()
        }
    }

    /// 每个明细周期都读取代理计数；与面板是否展开无关。
    let proxy = ProxyTrafficProbe()
    /// 原始物理 socket 速率，仅自检用；含核心 wire bytes，绝不加回应用明细。
    private(set) var lastRawTotals: (rx: Double, tx: Double) = (0, 0)
    private(set) var lastCoreTotals: (rx: Double, tx: Double) = (0, 0)

    // 子进程开销统计（nettop 是一次性的短命进程）
    private(set) var childCPUSeconds = 0.0
    private(set) var deliveredChildCPUSeconds = 0.0
    private(set) var childPeakFootprint: UInt64 = 0
    private(set) var shots = 0

    func start() {
        paused = false
        queue.sync {
            if needsResumeBaseline {
                let now = Date()
                previousExternalSnapshot = ExternalInterfaceSnapshot.read()
                lastTick = now
                detailBudget.requestRefresh()
                // 不把暂停期间的字节补进累计；旧扫描之后、下一轮扫描之前清基线。
                detailQueue.async { [self] in
                    attribution.reset(at: now)
                    rawBaselines.removeAll(keepingCapacity: true)
                }
                needsResumeBaseline = false
            }
            running = true
        }
        schedule(immediate: true)
    }

    /// 用户暂停/退出不等昂贵扫描；仅基准和无界面自检明确要求排空队列。
    func stop(waitForDetails: Bool = false) {
        paused = true
        timer?.cancel()
        timer = nil
        queue.sync {
            running = false
            if !waitForDetails {
                detailGeneration += 1
                detailRows = []
                needsResumeBaseline = true
            }
        }
        guard waitForDetails else { return }
        // 两条队列都排空：CPU 基准必须包含最后一轮扫描及其已回收子进程。
        detailQueue.sync {}
        queue.sync { publishSnapshot() }
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
        guard running else { return }
        let now = Date()
        recordExternal(ExternalInterfaceSnapshot.read(), at: now)
        shots += 1

        if !inFlight, detailBudget.isDue(at: now) {
            inFlight = true
            let generation = detailGeneration
            detailQueue.async { [self] in
                let sample = collectDetails()
                queue.async { [self] in
                    inFlight = false
                    childCPUSeconds += sample.childrenCPU
                    detailScans += 1
                    guard generation == detailGeneration else { return }
                    detailBudget.completed(cpuSeconds: sample.effort, started: sample.started, finished: sample.finished)
                    detailRows = sample.rows
                    detailRawTotals = sample.raw
                    detailCoreTotals = sample.core
                    periodAccumulator.setAttributionStatus(sample.status)
                    for delta in sample.deltas {
                        let owner = delta.owner
                        periodAccumulator.add(name: owner == .unknown ? Self.unassignedTrafficName : owner.name,
                                              rx: delta.rx, tx: delta.tx, viaProxy: delta.viaProxy, fullPath: owner.path)
                    }
                }
            }
        }
        publishSnapshot(at: now)
    }

    private func recordExternal(_ current: ExternalInterfaceSnapshot?, at now: Date) {
        // 读取失败不是接口消失；保留上一成功基线及时间，下次成功仍能补齐物理字节。
        guard let current else { physicalRates = (0, 0); return }
        let elapsed = max(0.2, now.timeIntervalSince(lastTick))
        let delta = previousExternalSnapshot.map { current.delta(since: $0) } ?? .init()
        previousExternalSnapshot = current
        lastTick = now
        periodAccumulator.addExternal(rx: delta.rx, tx: delta.tx, interfaces: current.interfaceNames)
        physicalRates = (Double(delta.rx) / elapsed, Double(delta.tx) / elapsed)
    }

    /// 只在轻量状态队列组装 UI 快照；连接队列即使阻塞也不影响顶部网速。
    private func publishSnapshot(at time: Date = Date()) {
        let rows = detailRows, rates = physicalRates
        let raw = detailRawTotals, core = detailCoreTotals
        let period = periodAccumulator.snapshot()
        let childCPU = childCPUSeconds, detailInterval = detailBudget.interval
        deliverQueue.async { [weak self] in
            guard let self else { return }
            self.snapshotTime = time
            self.deliveredChildCPUSeconds = childCPU
            self.detailInterval = detailInterval
            self.lastRawTotals = raw
            self.lastCoreTotals = core
            self.onSnapshot?(rows, rates.rx, rates.tx, rows.count, period)
        }
    }

    static func runSchedulingTests() {
        let sampler = Sampler()
        sampler.deliverQueue = DispatchQueue(label: "netball.scheduler-test.delivery")
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        sampler.detailProvider = {
            began.signal()
            precondition(release.wait(timeout: .now() + 5) == .success)
            let now = Date()
            let delta = TrafficDelta(owner: .unknown, rx: 123, tx: 456, rxRate: 123, txRate: 456, viaProxy: true)
            return DetailSample(rows: [], deltas: [delta], status: "stale-test", raw: (0, 0), core: (0, 0),
                                childrenCPU: 0.1, effort: 0.1, started: now, finished: now)
        }
        sampler.queue.sync { sampler.running = true; sampler.poll() }
        precondition(began.wait(timeout: .now() + 2) == .success)
        // 昂贵扫描仍被阻塞时，网卡刷新和重置必须可以继续，且不能开启重叠扫描。
        sampler.queue.sync { sampler.poll(); precondition(sampler.shots == 2 && sampler.inFlight) }
        let reset = sampler.resetPeriodStatistics()
        sampler.stop() // 必须在扫描还被阻塞时立即返回，不能卡住用户的暂停操作。
        sampler.queue.sync { precondition(!sampler.running && sampler.inFlight) }
        release.signal()
        sampler.stop(waitForDetails: true)
        sampler.deliverQueue.sync {}
        let final = sampler.currentPeriodStatistics()
        precondition(sampler.detailScans == 1 && abs(sampler.childCPUSeconds - 0.1) < 0.0001)
        precondition(final.since == reset.since && final.processes.isEmpty && final.attributionStatus == "归属待采样")
        let physical = Sampler()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        physical.recordExternal(.init(byInterface: ["en0": .init(rx: 100, tx: 200)]), at: time)
        physical.recordExternal(nil, at: time.addingTimeInterval(1))
        physical.recordExternal(.init(byInterface: ["en0": .init(rx: 400, tx: 600)]), at: time.addingTimeInterval(3))
        precondition(physical.currentPeriodStatistics().rxBytes == 300)
        precondition(physical.currentPeriodStatistics().txBytes == 400)
        precondition(abs(physical.physicalRates.rx - 100) < 0.001)
        print("SamplingSchedulingTests: passed (responsive physical/pause, no overlap, stale reset discarded, failed-read recovery)")
    }

    private struct DetailSample {
        let rows: [Row]
        let deltas: [TrafficDelta]
        let status: String
        let raw: (rx: Double, tx: Double)
        let core: (rx: Double, tx: Double)
        let childrenCPU: Double
        let effort: Double
        let started: Date
        let finished: Date
    }

    /// nettop/身份/代理必须在同一轮中归属和去重，但不能阻塞物理网速刷新。
    private func collectDetails() -> DetailSample {
        if let detailProvider { return detailProvider() }
        let started = Date()
        let cpuBefore = Self.reapedChildrenCPU()
        let ownBefore = cpuSeconds(getpid()) ?? 0
        let text = shot()
        let socketTime = Date()
        var unverifiedPIDs: Set<Int> = [], observedPIDs: Set<Int> = []
        let snapshot = text.flatMap { text in
            SocketTraffic.parseSnapshotCSV(text) { pid, name in
                observedPIDs.insert(pid)
                if let lifetime = processIncarnation(pid) {
                    verifiedLifetimes[pid] = lifetime
                    return TrafficOwner(pid: pid, incarnation: lifetime, name: name)
                }
                unverifiedPIDs.insert(pid)
                return TrafficOwner(pid: pid, incarnation: verifiedLifetimes[pid] ?? "\(pid):unverified", name: name)
            }
        }
        var ambiguousIdentities = snapshot?.ambiguousIdentities ?? []
        // 启动时间不可验证时只保留既有基线，既不把旧 PID 当作当前应用，也不回放失败区间。
        for socket in snapshot?.sockets ?? [] where socket.owner.pid.map(unverifiedPIDs.contains) == true {
            ambiguousIdentities.insert(socket.key)
        }
        if snapshot != nil { verifiedLifetimes = verifiedLifetimes.filter { observedPIDs.contains($0.key) } }
        var parsed = snapshot?.sockets.filter { $0.owner.pid.map(unverifiedPIDs.contains) != true }
        if let sockets = parsed {
            let names = Dictionary(sockets.compactMap { socket -> (Int, String)? in
                guard let pid = socket.owner.pid else { return nil }
                return (pid, socket.owner.name)
            }, uniquingKeysWith: { first, _ in first })
            processIdentityResolver.retain(only: Set(names.keys))
            let identities = processIdentityResolver.resolve(names.map { (name: $0.value, pid: $0.key) })
            parsed = sockets.map { socket in
                let identity = socket.owner.pid.flatMap { identities[$0] }
                let owner = TrafficOwner(pid: socket.owner.pid, incarnation: socket.owner.incarnation,
                                         name: identity?.name ?? socket.owner.name, path: identity?.fullPath)
                return SocketTraffic(key: socket.key, owner: owner, network: socket.network,
                                     local: socket.local, remote: socket.remote, interface: socket.interface,
                                     rx: socket.rx, tx: socket.tx)
            }
        }
        let proxySnapshot = proxy.poll(sockets: parsed, at: socketTime)
        let now = Date()
        let deltas = attribution.sample(sockets: parsed, proxy: proxySnapshot,
                                       corePIDs: proxy.corePIDs, at: now, ambiguousSocketIdentities: ambiguousIdentities)
        var status = proxy.status
        if parsed == nil { status = "进程归属不可用" }
        else if !unverifiedPIDs.isEmpty { status = "部分进程身份不可读" }
        else if !attribution.diagnostics.isEmpty, proxySnapshot != nil {
            status = "代理归属不完整"
        }

        // 实时/累计都按应用身份合并多个 PID；同一应用的代理连接和真正直连只各记一次。
        var byIdentity: [String: Row] = [:]
        for delta in deltas {
            let owner = delta.owner
            let name = owner == .unknown ? Sampler.unassignedTrafficName : owner.name
            let key = name + "\u{0}" + (owner.path ?? "")
            let previous = byIdentity[key]
            byIdentity[key] = Row(name: name, pid: previous?.pid ?? owner.pid ?? 0,
                                  rx: (previous?.rx ?? 0) + delta.rxRate,
                                  tx: (previous?.tx ?? 0) + delta.txRate,
                                  fullPath: owner.path, viaProxy: (previous?.viaProxy ?? false) || delta.viaProxy)
        }
        let rows = byIdentity.values.sorted { $0.total > $1.total }

        var rawRx = 0.0, rawTx = 0.0, coreRx = 0.0, coreTx = 0.0
        if let sockets = parsed {
            var current: [String: (rx: UInt64, tx: UInt64, at: Date)] = [:]
            for socket in sockets where ExternalInterfaceSnapshot.isExternalInterfaceName(socket.interface)
                && !socket.local.isLoopback && !socket.remote.isLoopback {
                if let old = rawBaselines[socket.key] {
                    let elapsed = max(0.2, now.timeIntervalSince(old.at))
                    let rx = Double(socket.rx >= old.rx ? socket.rx - old.rx : 0) / elapsed
                    let tx = Double(socket.tx >= old.tx ? socket.tx - old.tx : 0) / elapsed
                    rawRx += rx; rawTx += tx
                    if let pid = socket.owner.pid, proxy.corePIDs.contains(pid) { coreRx += rx; coreTx += tx }
                }
                current[socket.key] = (socket.rx, socket.tx, now)
            }
            rawBaselines = current
        }
        let childrenCPU = max(0, Self.reapedChildrenCPU() - cpuBefore)
        let ownCPU = max(0, (cpuSeconds(getpid()) ?? ownBefore) - ownBefore)
        return DetailSample(rows: rows, deltas: deltas, status: status,
                            raw: (rawRx, rawTx), core: (coreRx, coreTx), childrenCPU: childrenCPU,
                            effort: childrenCPU + ownCPU, started: started, finished: Date())
    }

    /// 跑一次单发快照；CSV 累计字节与现有连接账本相同，不运行常驻忙等进程。
    private func shot() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = Self.nettopArguments
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
        // nettop 偶发首帧忙等；超时只终止本轮自建子进程，不能拖住主界面。
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        if foot > 0 { childPeakFootprint = max(childPeakFootprint, foot) }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 已回收子进程的累计 CPU 秒数（用于统计 nettop 的真实开销）
    private static func reapedChildrenCPU() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_CHILDREN, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
             + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
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
    static let panelW: CGFloat = 392
    static let panelH: CGFloat = 522
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

    var expanded = false {
        didSet { if !expanded { chartHoverX = nil } }
    }
    var rows: [Sampler.Row] = []
    var totalRx = 0.0
    var totalTx = 0.0
    var procCount = 0
    var history: [PanelChartSample] = []
    var showPeriodStatistics = false
    var periodStatistics = Sampler.PeriodStatistics(since: Date(), rxBytes: 0, txBytes: 0,
                                                    externalInterfaces: [], processes: [])
    var statisticsScrollOffset = 0
    var statisticsScrollAccumulator = Sampler.StatisticsScrollAccumulator()
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
    var detailIntervalLabel = "2s"
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

        text("外网流量", x: pad, y: 15, font: fTitle, color: Palette.text)
        if paused {
            text("已暂停", x: pad, y: 15, font: fSmall, color: Palette.dim,
                 align: .right, boxWidth: w - 2 * pad)
        }

        text("↓ " + Fmt.rate(totalRx), x: pad, y: 42, font: fRate, color: Palette.cyan)
        text("↑ " + Fmt.rate(totalTx), x: pad, y: 42, font: fRate, color: Palette.amber,
             align: .right, boxWidth: w - 2 * pad)

        if showPeriodStatistics {
            drawPeriodSummary(x: pad, width: w - 2 * pad, small: fSmall, rate: fRate, foot: fFoot)
        } else {
            drawSparkline(chartRect, sk: sk)
        }

        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: pad, y: 240, width: w - 2 * pad, height: 1).fill()

        drawPanelTab("实时", rect: liveTabRect, selected: !showPeriodStatistics, font: fSmall)
        drawPanelTab("统计", rect: statisticsTabRect, selected: showPeriodStatistics, font: fSmall)
        let processHeading: String
        if showPeriodStatistics {
            let total = periodStatistics.processes.count
            let maxOffset = max(0, total - 5)
            let clampedOffset = min(statisticsScrollOffset, maxOffset)
            if clampedOffset != statisticsScrollOffset {
                statisticsScrollOffset = clampedOffset
                statisticsScrollAccumulator.reset()
            }
            let start = total == 0 ? 0 : min(statisticsScrollOffset + 1, total)
            let end = min(statisticsScrollOffset + 5, total)
            processHeading = total > 5 ? "应用 \(start)-\(end)/\(total)" : "应用累计"
        } else {
            processHeading = "应用排行"
        }
        if showPeriodStatistics && periodStatistics.processes.count > 5 {
            text(processHeading, x: pad + 112, y: 255, font: NSFont.systemFont(ofSize: 9), color: Palette.dim)
        }
        let downloadTitle = showPeriodStatistics && statisticsSort.column == .download
            ? "下载 \(statisticsSort.ascending ? "↑" : "↓")" : "下载"
        let uploadTitle = showPeriodStatistics && statisticsSort.column == .upload
            ? "上传 \(statisticsSort.ascending ? "↑" : "↓")" : "上传"
        text(downloadTitle, x: w - pad - 145, y: 255, font: fSmall,
             color: showPeriodStatistics && statisticsSort.column == .download ? Palette.cyan : Palette.dim,
             align: .right, boxWidth: 62)
        text(uploadTitle, x: w - pad - 72, y: 255, font: fSmall,
             color: showPeriodStatistics && statisticsSort.column == .upload ? Palette.amber : Palette.dim,
             align: .right, boxWidth: 68)

        if showPeriodStatistics {
            let sorted = periodStatistics.sortedProcesses(
                byUpload: statisticsSort.column == .upload, ascending: statisticsSort.ascending)
            let top = Array(sorted.dropFirst(statisticsScrollOffset).prefix(5))
            if top.isEmpty {
                text("这段期间还没有流量", x: pad, y: 310, font: fRow, color: Palette.dim)
            } else {
                let maxTotal = max(top.map { Double($0.totalBytes) }.max() ?? 0, 1)
                for (i, p) in top.enumerated() {
                    drawPeriodRow(p, index: i, y: 285 + CGFloat(i) * 42, maxTotal: maxTotal,
                                  fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
                }
            }
        } else {
            let top = Array(rows.prefix(5))
            if top.isEmpty {
                text(paused ? "采樣已暫停" : "正在採樣…", x: pad, y: 310, font: fRow, color: Palette.dim)
            } else {
                let maxTotal = max(top[0].total, 1)
                for (i, r) in top.enumerated() {
                    drawRow(r, index: i, y: 285 + CGFloat(i) * 42, maxTotal: maxTotal,
                            fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
                }
            }
        }

        let foot = "CPU \(Fmt.pct(selfCPU + nettopCPU)) · \(String(format: "%.0f", selfMemMB)) MB"
        text(foot, x: pad, y: h - 22, font: fFoot, color: Palette.dim)
    }

    private var liveTabRect: NSRect { NSRect(x: Metrics.pad, y: 251, width: 50, height: 22) }
    private var statisticsTabRect: NSRect { NSRect(x: Metrics.pad + 54, y: 251, width: 50, height: 22) }
    private var downloadSortRect: NSRect { NSRect(x: Metrics.panelW - Metrics.pad - 145, y: 251, width: 65, height: 22) }
    private var uploadSortRect: NSRect { NSRect(x: Metrics.panelW - Metrics.pad - 72, y: 251, width: 68, height: 22) }
    private var resetStatisticsRect: NSRect {
        NSRect(x: Metrics.panelW - Metrics.pad - 56, y: 78, width: 56, height: 22)
    }

    private func toggleStatisticsSort(_ column: Sampler.StatisticsSortState.Column) {
        statisticsSort.click(column)
        statisticsScrollOffset = 0
        statisticsScrollAccumulator.reset()
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
        text("自启动/重置起", x: x, y: 80, font: small, color: Palette.dim)
        let resetPath = NSBezierPath(roundedRect: resetStatisticsRect, xRadius: 7, yRadius: 7)
        NSColor(white: 1, alpha: 0.07).setFill()
        resetPath.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        resetPath.lineWidth = 1
        resetPath.stroke()
        text("重置", x: resetStatisticsRect.minX, y: resetStatisticsRect.minY + 4,
             font: small, color: Palette.text, align: .center, boxWidth: resetStatisticsRect.width)

        text("↓ " + Fmt.bytes(periodStatistics.rxBytes), x: x, y: 130,
             font: rate, color: Palette.cyan)
        text("↑ " + Fmt.bytes(periodStatistics.txBytes), x: x, y: 130,
             font: rate, color: Palette.amber, align: .right, boxWidth: width)
        let elapsed = Date().timeIntervalSince(periodStatistics.since)
        text("统计时长 \(Fmt.duration(elapsed))",
             x: x, y: 186, font: foot, color: Palette.dim)
    }

    private let panelIcons = PanelIconCache()
    var chartHoverX: CGFloat?
    private var chartTracking: NSTrackingArea?
    private var chartRect: NSRect {
        NSRect(x: Metrics.pad + 28, y: 106, width: Metrics.panelW - Metrics.pad * 2 - 28, height: 100)
    }

    /// 样例数据也保留时间语义，不影响真实采样与统计。
    func usePreviewHistory(_ values: [(rx: Double, tx: Double)]) {
        let end = clock()
        history = values.enumerated().map { index, value in
            PanelChartSample(at: end.addingTimeInterval(Double(index - values.count + 1)), rx: value.rx, tx: value.tx)
        }
    }

    func appendHistory(at time: Date, rx: Double, tx: Double) {
        history.append(PanelChartSample(at: time, rx: rx, tx: tx))
        history.removeAll { time.timeIntervalSince($0.at) > 60 }
        if history.count > 256 { history.removeFirst(history.count - 256) }
    }

    private func drawPeriodRow(_ p: Sampler.ProcessTotal, index: Int, y: CGFloat, maxTotal: Double,
                               fRow: NSFont, fVal: NSFont, w: CGFloat, pad: CGFloat, sk: PanelSkin) {
        drawApplicationRow(name: p.name, path: p.fullPath, proxy: p.viaProxy, unassigned: p.isUnassigned,
                           rx: Fmt.bytes(p.rxBytes), tx: Fmt.bytes(p.txBytes), ratio: Double(p.totalBytes) / maxTotal,
                           index: index, y: y, fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
    }

    private func drawRow(_ r: Sampler.Row, index: Int, y: CGFloat, maxTotal: Double,
                         fRow: NSFont, fVal: NSFont, w: CGFloat, pad: CGFloat, sk: PanelSkin) {
        drawApplicationRow(name: r.name, path: r.fullPath, proxy: r.viaProxy, unassigned: r.isUnassigned,
                           rx: Fmt.rate(r.rx), tx: Fmt.rate(r.tx), ratio: r.total / maxTotal,
                           index: index, y: y, fRow: fRow, fVal: fVal, w: w, pad: pad, sk: sk)
    }

    /// 实时与累计共享列宽，路径留在悬停提示，不再挤占名称。
    private func drawApplicationRow(name: String, path: String?, proxy: Bool, unassigned: Bool,
                                    rx: String, tx: String, ratio: Double, index: Int, y: CGFloat,
                                    fRow: NSFont, fVal: NSFont, w: CGFloat, pad: CGFloat, sk: PanelSkin) {
        let row = NSRect(x: pad, y: y, width: w - 2 * pad, height: 40)
        NSColor(white: 1, alpha: index < sk.rowFill.count ? sk.rowFill[index] : 0.04).setFill()
        NSBezierPath(roundedRect: row, xRadius: 9, yRadius: 9).fill()
        let icon = NSRect(x: row.minX + 9, y: y + 9, width: 22, height: 22)
        if let image = panelIcons.image(for: path) {
            image.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            let color = Palette.iconColors[stableHash(name) % Palette.iconColors.count]
            color.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: icon, xRadius: 6, yRadius: 6).fill()
            let symbol = unassigned ? "?" : (name.hasPrefix("node") ? "N" : String(name.prefix(1)).uppercased())
            centeredText(symbol, in: icon, font: .systemFont(ofSize: 12, weight: .semibold), color: color)
        }
        let nameX = icon.maxX + 9
        let valueStart = row.maxX - 145
        let badgeWidth: CGFloat = proxy ? 25 : 0
        let room = max(12, valueStart - nameX - badgeWidth - 8)
        text(truncated(name, font: fRow, maxWidth: room), x: nameX, y: y + 10,
             font: fRow, color: Palette.text)
        if proxy {
            let badge = NSRect(x: valueStart - 28, y: y + 12, width: 24, height: 14)
            Palette.cyan.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            centeredText("代理", in: badge, font: .systemFont(ofSize: 8.5, weight: .medium), color: Palette.cyan)
        }
        drawColumnValue(rx, x: valueStart, y: y, font: fVal, color: Palette.cyan)
        drawColumnValue(tx, x: valueStart + 73, y: y, font: fVal, color: Palette.amber)
        let track = NSRect(x: nameX, y: y + 34, width: row.maxX - 9 - nameX, height: 2)
        NSColor(white: 1, alpha: 0.05).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        if ratio.isFinite && ratio > 0 {
            Palette.cyan.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                             width: track.width * CGFloat(min(1, ratio)), height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    /// 数值列固定边界，长读数缩字而不挤进相邻列或代理标记。
    static func columnValueFont(_ value: String, font: NSFont, width: CGFloat = 65) -> NSFont {
        var size = min(10.5, font.pointSize)
        var fitted = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        // 系统字体的光学尺寸与像素取整并非严格等比，缩字后重新实测。
        for _ in 0..<16 {
            let measured = (value as NSString).size(withAttributes: [.font: fitted]).width
            if measured <= width { break }
            size = max(1, size * min(0.95, (width - 0.25) / measured))
            fitted = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        }
        return fitted
    }

    private func drawColumnValue(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        let fitted = Self.columnValueFont(value, font: font)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: x, y: y + 4, width: 65, height: 28)).addClip()
        text(value, x: x, y: y + 11 + (12.5 - fitted.pointSize) / 2,
             font: fitted, color: color, align: .right, boxWidth: 65)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSparkline(_ r: NSRect, sk: PanelSkin) {
        let model = PanelChartModel(samples: history, end: clock())
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        text(model.unitLabel, x: r.minX, y: r.minY - 18, font: font, color: Palette.dim)
        func axisLabel(_ value: Double) -> String {
            let scaled = value / model.unitDivisor
            return String(format: scaled == scaled.rounded() ? "%.0f" : "%.1f", scaled)
        }
        for value in [model.tickValues[0], model.tickValues[2], model.tickValues[4]] {
            let y = r.maxY - r.height * CGFloat(value / model.maxValue)
            NSColor(white: 1, alpha: 0.08).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: r.minX, y: y)); line.line(to: NSPoint(x: r.maxX, y: y))
            line.lineWidth = 0.5; line.stroke()
            text(axisLabel(value), x: Metrics.pad - 1, y: y - 6,
                 font: font, color: Palette.dim, align: .right, boxWidth: 22)
        }
        for (fraction, label) in [(0.0, "-60s"), (0.5, "-30s"), (1.0, "0")] {
            let x = r.minX + r.width * fraction
            let width: CGFloat = 32
            text(label, x: min(r.maxX - width, max(r.minX, x - width / 2)), y: r.maxY + 7,
                 font: font, color: Palette.dim, align: fraction == 1 ? .right : .left, boxWidth: width)
        }
        func point(_ sample: PanelChartSample, _ value: Double) -> NSPoint {
            NSPoint(x: r.minX + r.width * model.pointX(for: sample),
                    y: r.maxY - r.height * CGFloat(min(1, value / model.maxValue)))
        }
        for (pick, color) in [({ (s: PanelChartSample) in s.rx }, Palette.cyan),
                              ({ (s: PanelChartSample) in s.tx }, Palette.amber)] {
            for segment in model.segments {
                guard let first = segment.first, let last = segment.last else { continue }
                let line = NSBezierPath(); line.lineWidth = 1.6
                for (index, sample) in segment.enumerated() {
                    let p = point(sample, pick(sample))
                    if index == 0 { line.move(to: p) } else { line.line(to: p) }
                }
                if segment.count == 1 {
                    let p = point(first, pick(first))
                    color.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
                } else {
                    let area = line.copy() as! NSBezierPath
                    area.line(to: NSPoint(x: point(last, 0).x, y: r.maxY))
                    area.line(to: NSPoint(x: point(first, 0).x, y: r.maxY)); area.close()
                    color.withAlphaComponent(min(sk.areaFill, 0.09)).setFill(); area.fill()
                    color.setStroke(); line.stroke()
                }
            }
        }
        if let peak = model.peak, max(peak.rx, peak.tx) > 0, chartHoverX == nil {
            let value = max(peak.rx, peak.tx)
            let color = peak.rx >= peak.tx ? Palette.cyan : Palette.amber
            let p = point(peak, value)
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
            let label = axisLabel(value)
            let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
            text(label, x: min(r.maxX - labelWidth, max(r.minX, p.x + 6)),
                 y: max(r.minY - 13, p.y - 16), font: font, color: color)
        }
        if let x = chartHoverX, let sample = model.nearest(at: Double((x - r.minX) / r.width)) {
            let selectedX = point(sample, 0).x
            Palette.text.withAlphaComponent(0.32).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: selectedX, y: r.minY)); line.line(to: NSPoint(x: selectedX, y: r.maxY))
            line.lineWidth = 0.7; line.stroke()
            for (value, color) in [(sample.rx, Palette.cyan), (sample.tx, Palette.amber)] {
                let p = point(sample, value)
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            }
            let bubble = NSRect(x: min(r.maxX - 130, max(r.minX, selectedX - 140)), y: r.minY + 7, width: 130, height: 59)
            NSColor(srgbRed: 0.09, green: 0.12, blue: 0.15, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
            let date = Calendar.current.dateComponents([.hour, .minute, .second], from: sample.at)
            let time = String(format: "%02d:%02d:%02d", date.hour ?? 0, date.minute ?? 0, date.second ?? 0)
            text(time, x: bubble.minX + 10, y: bubble.minY + 6, font: font, color: Palette.dim)
            text("↓ " + Fmt.rate(sample.rx), x: bubble.minX + 10, y: bubble.minY + 23, font: font, color: Palette.cyan)
            text("↑ " + Fmt.rate(sample.tx), x: bubble.minX + 10, y: bubble.minY + 39, font: font, color: Palette.amber)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let chartTracking { removeTrackingArea(chartTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); chartTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = expanded && !showPeriodStatistics && chartRect.contains(point) ? point.x : nil
        if next != chartHoverX { chartHoverX = next; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if chartHoverX != nil { chartHoverX = nil; needsDisplay = true }
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

    private func centeredText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let size = NSAttributedString(string: s, attributes: [.font: font]).size()
        text(s, x: rect.minX, y: rect.minY + (rect.height - size.height) / 2,
             font: font, color: color, align: .center, boxWidth: rect.width)
    }

    private func drawIdentityPath(_ path: String, x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 9, weight: .regular)
        text(shortenedPath(path, font: font, maxWidth: maxWidth),
             x: x, y: y, font: font, color: Palette.dim)
    }

    private func shortenedPath(_ path: String, font: NSFont, maxWidth: CGFloat) -> String {
        let home = NSHomeDirectory()
        let displayPath: String
        if path == home { displayPath = "~" }
        else if path.hasPrefix(home + "/") { displayPath = "~/" + String(path.dropFirst(home.count + 1)) }
        else { displayPath = path }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (displayPath as NSString).size(withAttributes: attrs).width <= maxWidth { return displayPath }
        let chars = Array(displayPath)
        for start in 0..<chars.count {
            let candidate = "…" + String(chars.dropFirst(start))
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth { return candidate }
        }
        return "…"
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
        if expanded && chartRect.contains(convert(event.locationInWindow, from: nil)) { return }
        controller?.toggleExpanded()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        guard expanded else { return }
        addToolTip(NSRect(x: Metrics.pad, y: 285, width: Metrics.panelW - 2 * Metrics.pad, height: 208),
                       owner: self, userData: nil)
        addToolTip(NSRect(x: Metrics.pad, y: Metrics.panelH - 24, width: Metrics.panelW - 2 * Metrics.pad, height: 24),
                   owner: self, userData: nil)
        addCursorRect(liveTabRect, cursor: .pointingHand)
        addCursorRect(statisticsTabRect, cursor: .pointingHand)
        if showPeriodStatistics {
            addCursorRect(resetStatisticsRect, cursor: .pointingHand)
            addCursorRect(downloadSortRect, cursor: .pointingHand)
            addCursorRect(uploadSortRect, cursor: .pointingHand)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard view === self, expanded else { return "" }
        if point.y >= Metrics.panelH - 24 {
            return "最近约30秒 CPU均值（100%=一个核心）：自身 \(Fmt.pct(selfCPU)) + 采集工具 \(Fmt.pct(nettopCPU))。\n内存仅为主程序；不含子进程或 WindowServer。\n明细间隔是CPU预算目标；受网速档位、扫描用时与调度影响，实际可能更久。明细速率为扫描区间平均值。\n网速\(intervalLabel)；明细目标\(detailIntervalLabel)。"
        }
        let offset = point.y - 285
        guard offset >= 0 else { return "" }
        let index = Int(offset / 42)
        let withinRow = offset - CGFloat(index) * 42
        guard index < 5, withinRow < 40 else { return "" }

        let fullPath: String?
        let unassigned: Bool
        if showPeriodStatistics {
            let sorted = periodStatistics.sortedProcesses(
                byUpload: statisticsSort.column == .upload, ascending: statisticsSort.ascending)
            let processIndex = statisticsScrollOffset + index
            fullPath = processIndex < sorted.count ? sorted[processIndex].fullPath : nil
            unassigned = processIndex < sorted.count && sorted[processIndex].isUnassigned && sorted[processIndex].viaProxy
        } else {
            fullPath = index < rows.count ? rows[index].fullPath : nil
            unassigned = index < rows.count && rows[index].isUnassigned && rows[index].viaProxy
        }
        if unassigned { return "Clash：尚不能确认具体应用的代理连接；不是物理总量减去明细的剩余值。" }
        guard let fullPath else { return "" }
        return "完整路径：\n\(fullPath)"
    }

    override func scrollWheel(with event: NSEvent) {
        guard expanded, showPeriodStatistics else {
            super.scrollWheel(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 285 && point.y < 493 else {
            statisticsScrollAccumulator.reset()
            super.scrollWheel(with: event)
            return
        }
        let maxOffset = max(0, periodStatistics.processes.count - 5)
        guard maxOffset > 0 else {
            statisticsScrollAccumulator.reset()
            return
        }
        let offsetDelta = statisticsScrollAccumulator.consume(
            deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard offsetDelta != 0 else { return }
        let nextOffset = min(max(0, statisticsScrollOffset + offsetDelta), maxOffset)
        guard nextOffset != statisticsScrollOffset else {
            statisticsScrollAccumulator.reset()
            return
        }
        statisticsScrollOffset = nextOffset
        if nextOffset == 0 || nextOffset == maxOffset { statisticsScrollAccumulator.reset() }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// Status-item tracking callbacks can be dropped while macOS switches menu-bar window state.
// A small run-loop poll provides a fallback, with the same short dwell as mouseEntered:.
struct StatusHoverDwellState {
    private var startedAt: TimeInterval?

    mutating func update(isHovering: Bool, now: TimeInterval, delay: TimeInterval = 0.12) -> Bool {
        guard isHovering else {
            startedAt = nil
            return false
        }
        guard let startedAt else {
            self.startedAt = now
            return false
        }
        guard now - startedAt >= delay else { return false }
        self.startedAt = nil
        return true
    }

    mutating func reset() { startedAt = nil }
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
    private var statusHoverWatchTimer: Timer?
    private var statusHoverDwell = StatusHoverDwellState()
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
    private var cpuWindow = CPUUsageWindow()
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
        startStatusHoverWatchdog()

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
            // reset 的 queue.sync 不能撤回已经排入主队列的旧快照。
            guard let self, period.since >= self.view.periodStatistics.since else { return }
            self.benchmarkUpdates += 1
            self.view.intervalLabel = "\(Int(self.sampler.interval))s"
            self.view.detailIntervalLabel = String(format: "%.0fs", self.sampler.detailInterval)
            self.view.rows = rows
            self.view.periodStatistics = period
            // --anim-demo：用振荡的合成速率替掉真实速率，强制每次采样都触发 0.4s 缓动，
            // 用来量"20fps 重绘"这部分的 CPU 代价（真实流量空闲时弧线根本不动，量不出来）
            let (urx, utx) = self.animDemo ? self.syntheticRates() : (rx, tx)
            self.view.updateRates(rx: urx, tx: utx)
            self.view.procCount = count
            self.view.appendHistory(at: self.sampler.snapshotTime, rx: urx, tx: utx)
            self.view.recomputePeaks()
            self.view.needsDisplay = true
            self.startArcAnimation()
            self.lastRx = urx
            self.lastTx = utx
            self.updateStatusTitle()
        }
        sampler.start()

        benchmarkSelfCPU0 = cpuSeconds(getpid()) ?? 0
        _ = cpuWindow.record(at: Date(), own: benchmarkSelfCPU0, helpers: 0)
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
                if el >= secs { timer.invalidate(); self.sampler.stop(waitForDetails: true); exit(0) }
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

    private func startStatusHoverWatchdog() {
        guard statusHoverWatchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollStatusHover()
        }
        // Include event-tracking mode so menu-bar interaction cannot pause the fallback.
        RunLoop.main.add(timer, forMode: .common)
        statusHoverWatchTimer = timer
    }

    private func pollStatusHover() {
        let hoveringStatus = mode.showsTray && isMouseOverStatusItem()
        let shouldShow = statusHoverDwell.update(
            isHovering: hoveringStatus && !view.expanded && !hoverPanelActive,
            now: ProcessInfo.processInfo.systemUptime)
        if shouldShow {
            hoverShowWorkItem?.cancel()
            hoverShowWorkItem = nil
            showHoverPanel()
        }

        guard hoverPanelActive else { return }
        if isMouseInsideHoverRegions() {
            hoverHideWorkItem?.cancel()
            hoverHideWorkItem = nil
        } else if hoverHideWorkItem == nil {
            scheduleHoverPanelDismissal()
        }
    }

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
        let usage = cpuWindow.record(at: now, own: cpu, helpers: sampler.deliveredChildCPUSeconds)
        selfCPU = usage.own
        selfMem = footprintBytes(getpid())
        view.nettopCPU = usage.helpers
        view.selfCPU = selfCPU
        view.selfMemMB = Double(selfMem) / 1048576
        view.needsDisplay = true
    }

    private func finishBenchmark() {
        sampler.stop(waitForDetails: true) // 先回收最后的子进程，再统计时间/CPU；不能漏掉在途扫描。
        let wall = Date().timeIntervalSince(benchmarkStart)
        let selfCPUAvg = ((cpuSeconds(getpid()) ?? 0) - benchmarkSelfCPU0) / wall * 100
        let nettopCPU = sampler.childCPUSeconds / wall * 100
        var out = "benchmark 网速=\(Int(sampler.interval))s 明细目标≈\(String(format: "%.1f", sampler.detailInterval))s 时长=\(String(format: "%.1f", wall))s 刷新=\(sampler.shots) 明细扫描=\(sampler.detailScans)\n"
        out += "  NetBall  自身  cpu均值=\(Fmt.pct(selfCPUAvg))  peakFootprint=\(Fmt.mb(benchmarkPeakSelf))\n"
        out += "  采集工具 子进程 cpu均值=\(Fmt.pct(nettopCPU))  nettopPeak=\(Fmt.mb(sampler.childPeakFootprint))\n"
        out += "  合计     cpu≈\(Fmt.pct(selfCPUAvg + nettopCPU))\n"
        out += String(format: "  弧线缓动 定时器帧=%d  实际重绘=%d  重绘均值=%.1f 次/秒\n",
                      animFrames, view.drawCount, Double(view.drawCount) / wall)
        let marks = memTrace.enumerated().filter { $0.offset % 10 == 0 }.map { "\($0.offset / 2)s:\($0.element / 1048576)MB" }
        out += "  内存轨迹 \(marks.joined(separator: "  "))\n"
        out += "  末值 \(Fmt.mb(memTrace.last ?? 0))\n"
        print(out)
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
        if visible {
            view.statisticsScrollOffset = 0
            view.statisticsScrollAccumulator.reset()
        }
        window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    func resetPeriodStatistics() {
        view.periodStatistics = sampler.resetPeriodStatistics()
        view.statisticsScrollOffset = 0
        view.statisticsScrollAccumulator.reset()
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
            let it = NSMenuItem(title: "\(Int(v)) 秒（网速；展开时 1 秒）", action: #selector(menuSetFreq(_:)), keyEquivalent: "")
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
    if CommandLine.arguments.contains("--hover") { v.chartHoverX = Metrics.panelW - Metrics.pad - 75 }
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
                v.usePreviewHistory(hist)
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
            v.usePreviewHistory(demo ? demoHistory() : [])
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
    private var hist: [PanelChartSample] = []
    private var period = Sampler.PeriodStatistics(since: Date(), rxBytes: 0, txBytes: 0,
                                                  externalInterfaces: [], processes: [])
    /// 物理 socket 原始速率，仅诊断，不参与应用累计。
    private var raw: (rx: Double, tx: Double) = (0, 0)

    func update(_ r: [Sampler.Row], _ a: Double, _ b: Double, _ c: Int,
                raw: (rx: Double, tx: Double) = (0, 0), at time: Date = Date(),
                period: Sampler.PeriodStatistics? = nil) {
        lock.lock(); defer { lock.unlock() }
        rows = r; rx = a; tx = b; count = c; self.raw = raw
        if let period { self.period = period }
        let now = time
        hist.append(PanelChartSample(at: now, rx: a, tx: b))
        hist.removeAll { now.timeIntervalSince($0.at) > 60 }
        if hist.count > 256 { hist.removeFirst(hist.count - 256) }
    }

    var snapshot: ([Sampler.Row], Double, Double, Int, [PanelChartSample], Sampler.PeriodStatistics) {
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
    let cpu0 = cpuSeconds(getpid()) ?? 0
    let started = Date()
    let box = LiveBox()
    let s = Sampler()
    s.deliverQueue = DispatchQueue(label: "netball.live")
    s.onSnapshot = { rows, rx, tx, c, period in
        box.update(rows, rx, tx, c, raw: s.lastRawTotals, at: s.snapshotTime, period: period)
    }
    s.setActive(true)   // 渲染展开面板，按展开档频率采样；收起时同样做归属。
    s.start()

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    s.stop(waitForDetails: true)
    s.deliverQueue.sync {}
    let (rows, rx, tx, count, hist, period) = box.snapshot
    FileHandle.standardError.write(
        "live: rows=\(rows.count) total=\(Fmt.rate(rx))/\(Fmt.rate(tx)) procs=\(count)\n".data(using: .utf8)!)

    let wall = max(0.1, Date().timeIntervalSince(started))
    let ownCPU = max(0, (cpuSeconds(getpid()) ?? cpu0) - cpu0) / wall * 100
    renderSnapshot(to: path, expanded: true) { v in
        v.rows = rows
        v.totalRx = rx
        v.totalTx = tx
        v.procCount = count
        v.history = hist
        v.periodStatistics = period
        v.selfCPU = ownCPU
        v.nettopCPU = s.childCPUSeconds / wall * 100
        v.selfMemMB = Double(footprintBytes(getpid())) / 1048576
        v.intervalLabel = String(format: "%.0fs", s.interval)
        v.detailIntervalLabel = String(format: "%.0fs", s.detailInterval)
    }
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
    let presentationFailures = PanelPresentationTests.run()
    precondition(presentationFailures.isEmpty, presentationFailures.joined(separator: "\n"))
    let columnFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    for value in ["1023.9 KB/s", "1000.0 MB/s", "16777216.00 TB", "0 B/s"] {
        let fitted = BallView.columnValueFont(value, font: columnFont)
        precondition((value as NSString).size(withAttributes: [.font: fitted]).width <= 65.01,
                     "数值越过列边界：\(value)")
    }
    print("面板图表/图标缓存/数值列宽自检通过")
    SamplingPerformanceTests.run()
    ExternalInterfaceSnapshot.runTests()
    Sampler.runSchedulingTests()
    AttributionSelfTests.run()
    do { try ProxyProbeSelfTests.run() }
    catch { fatalError("ProxyProbeSelfTests: \(error)") }
    precondition(Sampler.nettopArguments == ["-x", "-n", "-L", "1", "-J", "interface,state,bytes_in,bytes_out", "-c"])
    precondition(ExternalInterfaceSnapshot.isExternalInterfaceName("en0"))
    precondition(ExternalInterfaceSnapshot.isExternalInterfaceName("en12"))
    precondition(!ExternalInterfaceSnapshot.isExternalInterfaceName("lo0"))
    precondition(!ExternalInterfaceSnapshot.isExternalInterfaceName("utun4"))
    precondition(!ExternalInterfaceSnapshot.isExternalInterfaceName("bridge0"))
    precondition(!ExternalInterfaceSnapshot.isExternalInterfaceName("en0x"))
    let oldInterfaces = ExternalInterfaceSnapshot(byInterface: [
        "en0": .init(rx: 100, tx: 200),
        "en1": .init(rx: 50, tx: 70),
        "lo0": .init(rx: 10_000, tx: 10_000),
    ])
    let newInterfaces = ExternalInterfaceSnapshot(byInterface: [
        "en0": .init(rx: 130, tx: 260),
        "en1": .init(rx: 55, tx: 80),
        "en2": .init(rx: 900, tx: 900), // new interface contributes only after its next baseline
    ])
    let interfaceDelta = newInterfaces.delta(since: oldInterfaces)
    precondition(interfaceDelta.rx == 35 && interfaceDelta.tx == 70)

    var acc = Sampler.PeriodAccumulator()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    acc.reset(at: start)
    acc.addExternal(rx: 10_000, tx: 20_000, interfaces: ["en0"])
    acc.add(name: "curl", rx: 2_048, tx: 512, viaProxy: true)
    acc.add(name: "curl", rx: 1_024, tx: 256, viaProxy: false)
    acc.add(name: "Safari", rx: 4_096, tx: 128, viaProxy: false)
    let sample = acc.snapshot()
    precondition(sample.rxBytes == 10_000 && sample.txBytes == 20_000) // interface total is independent of process rows
    precondition(sample.externalInterfaces == ["en0"])
    precondition(sample.processes.reduce(UInt64(0)) { $0 &+ $1.rxBytes } == 7_168)
    precondition(sample.processes.reduce(UInt64(0)) { $0 &+ $1.txBytes } == 896)
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

    var scroll = Sampler.StatisticsScrollAccumulator()
    precondition(scroll.consume(deltaY: 0, precise: true) == 0) // zero-delta events must not move the list
    precondition(scroll.consume(deltaY: -23, precise: true) == 0)
    precondition(scroll.consume(deltaY: -23, precise: true) == 1) // one row down after 46pt
    precondition(scroll.consume(deltaY: 23, precise: true) == 0)
    precondition(scroll.consume(deltaY: 23, precise: true) == -1) // reverse gesture restores the top row
    precondition(scroll.consume(deltaY: 0, precise: false) == 0)
    precondition(scroll.consume(deltaY: -1, precise: false) == 1)
    scroll.reset()
    precondition(scroll.consume(deltaY: 23, precise: true) == 0) // no stale fractional delta after reset


    var hoverDwell = StatusHoverDwellState()
    precondition(!hoverDwell.update(isHovering: true, now: 0))
    precondition(!hoverDwell.update(isHovering: true, now: 0.119))
    precondition(hoverDwell.update(isHovering: true, now: 0.12))
    precondition(!hoverDwell.update(isHovering: true, now: 1.0)) // a new dwell begins after showing
    precondition(!hoverDwell.update(isHovering: false, now: 1.05)) // leaving cancels the dwell
    precondition(!hoverDwell.update(isHovering: true, now: 1.1))
    precondition(hoverDwell.update(isHovering: true, now: 1.23))

    acc.reset(at: start.addingTimeInterval(60))
    precondition(acc.snapshot().rxBytes == 0 && acc.snapshot().processes.isEmpty)
    precondition(Fmt.bytes(1_536) == "1.5 KB")

    var identities = Sampler.PeriodAccumulator()
    identities.add(name: "Visual Studio Code", rx: 100, tx: 10, viaProxy: false,
                   fullPath: "/Applications/Visual Studio Code.app")
    identities.add(name: "Visual Studio Code", rx: 200, tx: 20, viaProxy: true,
                   fullPath: "/Applications/Visual Studio Code.app")
    identities.add(name: "Visual Studio Code", rx: 50, tx: 5, viaProxy: false,
                   fullPath: "/Applications/VS Code Insiders.app")
    identities.add(name: "node · server.js", rx: 30, tx: 3, viaProxy: false,
                   fullPath: "/Users/me/Project A/server.js")
    identities.add(name: "node · server.js", rx: 40, tx: 4, viaProxy: false,
                   fullPath: "/Users/me/Project B/server.js")
    let identityRows = identities.snapshot().processes
    precondition(identityRows.count == 4)
    precondition(identityRows.first(where: { $0.fullPath == "/Applications/Visual Studio Code.app" })?.rxBytes == 300)
    precondition(identityRows.first(where: { $0.fullPath == "/Applications/Visual Studio Code.app" })?.viaProxy == true)

    precondition(ProcessIdentityResolver.isElectron("Electron Helper"))
    precondition(ProcessIdentityResolver.isNode("node"))
    precondition(ProcessIdentityResolver.isUV("uv"))
    precondition(!ProcessIdentityResolver.isUV("uvicorn"))
    precondition(ProcessIdentityResolver.outermostAppBundlePath(
        from: "/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Electron")
        == "/Applications/Editor.app")
    precondition(ProcessIdentityResolver.nodeEntrypoint(
        from: "/opt/homebrew/bin/node /Users/me/Dev/My Project/src/server.ts --port 3000",
        workingDirectory: "/Users/me") == "/Users/me/Dev/My Project/src/server.ts")
    precondition(ProcessIdentityResolver.nodeEntrypoint(
        from: "/opt/homebrew/bin/node --require /Users/me/hook.js /Users/me/app/main.js",
        workingDirectory: "/Users/me") == "/Users/me/app/main.js")
    precondition(ProcessIdentityResolver.nodeEntrypoint(
        from: "/opt/homebrew/bin/node /opt/node/lib/node_modules/npm/bin/npm-cli.js run start",
        workingDirectory: "/Users/me/app") == nil)
    precondition(ProcessIdentityResolver.nodeEntrypoint(
        from: "/opt/homebrew/bin/node -e 'console.log(1)'", workingDirectory: "/Users/me/app") == nil)
    precondition(ProcessIdentityResolver.projectDirectory(
        for: "/Users/me/app/node_modules/next/dist/server.js", workingDirectory: "/Users/me/app")
        == "/Users/me/app")
    precondition(ProcessIdentityResolver.projectDirectory(
        for: "/Users/me/shared/server.js", workingDirectory: "/Users/me/app") == nil)

    let tooltipView = BallView(frame: NSRect(x: 0, y: 0, width: Metrics.panelW, height: Metrics.panelH))
    tooltipView.expanded = true
    tooltipView.rows = [Sampler.Row(name: "node · server.js", pid: 1, rx: 10, tx: 0,
                                    fullPath: "/Users/me/Project/server.js")]
    let liveTooltip = tooltipView.view(tooltipView, stringForToolTip: 0,
                                       point: NSPoint(x: 60, y: 290), userData: nil)
    precondition(liveTooltip == "完整路径：\n/Users/me/Project/server.js")
    tooltipView.showPeriodStatistics = true
    tooltipView.periodStatistics = Sampler.PeriodStatistics(
        since: Date(), rxBytes: 10, txBytes: 0, externalInterfaces: ["en0"],
        processes: [Sampler.ProcessTotal(name: "node · server.js", rxBytes: 10, txBytes: 0,
                                         viaProxy: false, fullPath: "/Users/me/Project/server.js")])
    let statisticsTooltip = tooltipView.view(tooltipView, stringForToolTip: 0,
                                              point: NSPoint(x: 60, y: 290), userData: nil)
    precondition(statisticsTooltip == "完整路径：\n/Users/me/Project/server.js")

    print("统计/身份自检通过：物理总量独立、连接归属与去重、API 故障/重启/重置基线、回环排除、应用合并、路径隐私、滚动与排序")
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
    // 比较物理总量、非加总的 raw socket 诊断、以及归属后的应用明细。
    // --idle 验证面板收起时仍归属；--report-json path 写累计结果供受控实验核对。
    _ = NSApplication.shared
    let secs = doubleArg("--proxy-test", 8)
    let box = LiveBox()
    let s = Sampler()
    s.deliverQueue = DispatchQueue(label: "netball.proxytest")
    s.setIntervals(idle: 1.0, active: 1.0)
    s.setActive(!argv.contains("--idle"))
    s.onSnapshot = { rows, rx, tx, n, period in
        box.update(rows, rx, tx, n, raw: s.lastRawTotals, at: s.snapshotTime, period: period)
    }
    s.start()

    var best = box.withRaw
    let deadline = Date().addingTimeInterval(secs)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let cur = box.withRaw
        if cur.raw.rx + cur.raw.tx > best.raw.rx + best.raw.tx { best = cur }
    }
    s.stop(waitForDetails: true)
    s.deliverQueue.sync {}

    print("控制器端点: \(s.proxy.endpointDesc ?? "未找到 —— 不猜测代理应用归属")")
    print("代理核心 PID: \(s.proxy.corePIDs.sorted())  （wire bytes 仅诊断，绝不加回明细）")
    print("走代理的 PID: \(s.proxy.proxiedPIDs.sorted())")
    print(String(format: "\n峰值那一刻："))
    print(String(format: "  物理网卡外网总量       ↓%-12@ ↑%-12@",
                 Fmt.rate(best.rx) as NSString, Fmt.rate(best.tx) as NSString))
    print(String(format: "  原始物理 socket（仅诊断）↓%-12@ ↑%-12@   应用数 %d",
                 Fmt.rate(best.raw.rx) as NSString, Fmt.rate(best.raw.tx) as NSString, best.count))
    let (_, _, _, _, _, period) = box.snapshot
    print("归属状态: \(period.attributionStatus)")
    print("\n应用排行（代理 payload + 去重直连，不含回环及核心 wire bytes）:")
    for r in best.rows.prefix(8) {
        print(String(format: "  %-24@ pid %-7d ↓%-11@ ↑%-11@%@",
                     r.name as NSString, r.pid, Fmt.rate(r.rx) as NSString,
                     Fmt.rate(r.tx) as NSString, (r.viaProxy ? "  [代理]" : "") as NSString))
    }
    print("累计：物理 ↓\(Fmt.bytes(period.rxBytes)) ↑\(Fmt.bytes(period.txBytes))；\(period.processes.count) 个应用身份")
    if let index = argv.firstIndex(of: "--report-json"), index + 1 < argv.count {
        let object: [String: Any] = [
            "physicalRX": period.rxBytes, "physicalTX": period.txBytes,
            "since": period.since.timeIntervalSince1970, "status": period.attributionStatus,
            "processes": period.processes.map { process -> [String: Any] in
                ["name": process.name, "path": process.fullPath ?? "", "rx": process.rxBytes,
                 "tx": process.txBytes, "viaProxy": process.viaProxy]
            }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: argv[index + 1]), options: .atomic)
        } catch { fputs("归属报告写入失败: \(error)\n", stderr); exit(1) }
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
            v.procCount = 8
            v.rows = [
                Sampler.Row(name: "Google Chrome", pid: 45565, rx: mb(5.8), tx: kb(120), fullPath: "/Applications/Google Chrome.app", viaProxy: true),
                Sampler.Row(name: "WeChat", pid: 52526, rx: mb(1.6), tx: kb(340), fullPath: "/Applications/WeChat.app"),
                Sampler.Row(name: "node · server.js", pid: 798, rx: kb(210), tx: kb(64),
                            fullPath: NSHomeDirectory() + "/Developer/demo-api/server.js", viaProxy: true),
                Sampler.Row(name: Sampler.unassignedTrafficName, pid: 0, rx: kb(112), tx: kb(4), viaProxy: true),
                Sampler.Row(name: "Visual Studio Code", pid: 45599, rx: kb(96), tx: kb(18),
                            fullPath: "/Applications/Visual Studio Code.app", viaProxy: true),
                Sampler.Row(name: "Dropbox", pid: 900, rx: kb(88), tx: kb(12)),
            ]
            var hist: [(rx: Double, tx: Double)] = []
            for i in 0..<61 {
                let t = Double(i)
                let down = mb(max(0, 5.2 + 4.8 * sin(t / 6.1) + 2.0 * sin(t / 2.7)))
                let up = mb(0.6 + 0.5 * sin(t / 3.3 + 1))
                hist.append((rx: down, tx: up))
            }
            hist[hist.count - 1] = (rx: mb(8.4), tx: mb(1.2))
            v.usePreviewHistory(hist)
            if v.showPeriodStatistics {
                let processes = [
                    Sampler.ProcessTotal(name: "Google Chrome", rxBytes: 8_420_000_000, txBytes: 1_120_000_000, viaProxy: true, fullPath: "/Applications/Google Chrome.app"),
                    Sampler.ProcessTotal(name: "WeChat", rxBytes: 4_210_000_000, txBytes: 830_000_000, viaProxy: false, fullPath: "/Applications/WeChat.app"),
                    Sampler.ProcessTotal(name: "node · web-app", rxBytes: 2_800_000_000, txBytes: 210_000_000, viaProxy: true,
                                          fullPath: NSHomeDirectory() + "/Developer/web-app"),
                    Sampler.ProcessTotal(name: "Visual Studio Code", rxBytes: 1_780_000_000, txBytes: 440_000_000, viaProxy: true,
                                          fullPath: "/Applications/Visual Studio Code.app"),
                    Sampler.ProcessTotal(name: Sampler.unassignedTrafficName, rxBytes: 1_400_000_000,
                                         txBytes: 3_400_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "uv", rxBytes: 1_250_000_000, txBytes: 120_000, viaProxy: false,
                                          fullPath: NSHomeDirectory() + "/.local/bin/uv"),
                    Sampler.ProcessTotal(name: "Dropbox", rxBytes: 940_000_000, txBytes: 150_000_000, viaProxy: false),
                    Sampler.ProcessTotal(name: "Safari", rxBytes: 620_000_000, txBytes: 87_000_000, viaProxy: true),
                    Sampler.ProcessTotal(name: "Steam Helper", rxBytes: 340_000_000, txBytes: 92_000_000, viaProxy: false),
                    Sampler.ProcessTotal(name: "Tailscale", rxBytes: 120_000_000, txBytes: 3_400_000_000, viaProxy: false),
                ]
                v.periodStatistics = Sampler.PeriodStatistics(
                    since: Date().addingTimeInterval(-3 * 3600 - 27 * 60),
                    // Synthetic physical-interface totals intentionally differ from nettop process rows.
                    rxBytes: 11_200_000_000,
                    txBytes: 2_100_000_000,
                    externalInterfaces: ["en0"], processes: processes
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
