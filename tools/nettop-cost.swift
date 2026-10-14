// 开发用：单独测量 nettop 在不同参数下的 CPU / 内存开销
// 用法: swiftc -O -module-cache-path .modulecache -o build/nettop-cost tools/nettop-cost.swift && ./build/nettop-cost
import Darwin
import Foundation

let timebase: (Double, Double) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (Double(tb.numer), Double(tb.denom))
}()

func rusage(_ pid: pid_t) -> (cpu: Double, foot: UInt64)? {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
            proc_pid_rusage(pid, RUSAGE_INFO_V6, rp)
        }
    }
    guard rc == 0 else { return nil }
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return (ticks * timebase.0 / timebase.1 / 1e9, info.ri_phys_footprint)
}

func measure(_ label: String, args: [String], seconds: Double) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    var bytes = 0
    pipe.fileHandleForReading.readabilityHandler = { fh in
        bytes += fh.availableData.count   // 必须持续读走，否则子进程会被管道写满卡住
    }
    guard (try? p.run()) != nil else { print("\(label): 启动失败"); return }
    let pid = p.processIdentifier
    usleep(300_000)
    guard let a = rusage(pid) else { print("\(label): 取不到 rusage"); p.terminate(); return }
    var peak: UInt64 = a.foot
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        usleep(250_000)
        if let r = rusage(pid) { peak = max(peak, r.foot) }
    }
    let wall = Date().timeIntervalSince(t0)
    let b = rusage(pid)
    let cpu = ((b?.cpu ?? a.cpu) - a.cpu) / wall * 100
    p.terminate()
    print(String(format: "%-46s cpu=%6.1f%%  peak=%.1f MB  out=%.0f KB",
                 (label as NSString).utf8String!, cpu, Double(peak) / 1048576, Double(bytes) / 1024))
}

let base = ["-P", "-x", "-n", "-J", "bytes_in,bytes_out"]
measure("nettop -s 1 (无 -l，交互模式)", args: ["-P", "-x", "-n", "-s", "1", "-J", "bytes_in,bytes_out"], seconds: 6)
measure("nettop -l 0 -s 1 (当前用的日志模式)", args: base + ["-l", "0", "-s", "1"], seconds: 6)
measure("nettop -l 0 -s 2", args: base + ["-l", "0", "-s", "2"], seconds: 6)
measure("nettop -l 0 -s 5", args: base + ["-l", "0", "-s", "5"], seconds: 6)
measure("nettop -L 0 -s 1 (CSV 模式)", args: ["-P", "-x", "-n", "-s", "1", "-L", "0", "-J", "bytes_in,bytes_out"], seconds: 6)
measure("nettop -l 0 -s 1 -c (gentle CPU)", args: base + ["-l", "0", "-s", "1", "-c"], seconds: 6)
