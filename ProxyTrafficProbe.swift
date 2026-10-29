import Foundation
import CoreFoundation
import Darwin

/// Local, read-only mihomo payload counters. No proxy environment, credentials,
/// remote controller, process command lines, or physical-interface totals are used.
/// Call on the sampler's serial queue on *every* tick, including while UI is closed.
final class ProxyTrafficProbe {
    private(set) var corePIDs: Set<Int> = []
    private(set) var endpointDesc: String?
    private(set) var status = "未检测到代理"
    private(set) var proxiedPIDs: Set<Int> = []

    private struct Endpoint {
        let socket: String?
        var base: String { socket == nil ? "http://127.0.0.1:9090" : "http://localhost" }
        var description: String { socket ?? base }
        var identity: String {
            let attrs = socket.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            // Unix socket 的设备与 inode 是选中 controller 的证据，不关联其他核心。
            return ProxyProbeLogic.endpointIdentity(socket: socket,
                device: (attrs?[.systemNumber] as? NSNumber)?.uint64Value,
                inode: (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
    }

    private struct Configuration {
        var tunEnabled = false
        var listeners: Set<TrafficEndpoint> = []
        var ports: Set<Int> = []
    }

    private var endpoint: Endpoint?
    private var configuration = Configuration()
    private var nextDiscovery = Date.distantPast
    private var discoveryBackoff: TimeInterval = 2
    private var nextConfiguration = Date.distantPast
    private var nextCoreScan = Date.distantPast
    private var coreBirths: [Int: String] = [:]
    private var lastHealthyEndpointIdentity: String?
    private var controllerListener: ProxyProbeLogic.ControllerListener?
    private var controllerEpochState = ProxyProbeLogic.ControllerEpochState()
    private var nextControllerScan = Date.distantPast
    private var localAddresses: Set<String> = []
    private var nextAddressScan = Date.distantPast
    private var appNames: [String: String] = [:]

    init() {}

    func poll(sockets: [SocketTraffic]?, at now: Date) -> ProxyTrafficSnapshot? {
        // Check live birth for already-known PIDs before any early return. Never
        // suppress a reused/gone PID simply because the controller is unavailable.
        let hadCore = !corePIDs.isEmpty
        refreshCores(at: now, force: false)
        if now >= nextAddressScan {
            localAddresses = Self.interfaceAddresses()
            nextAddressScan = now.addingTimeInterval(15)
        }
        guard let selected = endpoint ?? discover(at: now) else {
            proxiedPIDs = []
            status = corePIDs.isEmpty ? "未检测到代理" : "代理归属不可用"
            return nil
        }
        var refreshedConfiguration = false
        if now >= nextConfiguration {
            refreshConfiguration(selected)
            nextConfiguration = now.addingTimeInterval(30)
            refreshedConfiguration = true
        }
        let identityBefore = controllerIdentity(selected, at: now, discover: true)
        guard let acquisition = ProxyProbeLogic.acquireConnections(request: {
            Self.request(selected, path: "/connections")
        }), let parsed = ProxyProbeLogic.parse(acquisition.data) else {
            endpoint = nil
            endpointDesc = nil
            configuration = Configuration()
            nextConfiguration = .distantPast
            nextDiscovery = now.addingTimeInterval(discoveryBackoff)
            discoveryBackoff = min(discoveryBackoff * 2, 30)
            proxiedPIDs = []
            status = "代理归属不可用"
            return nil // nil, unlike a successful empty array, preserves ledger baselines.
        }
        discoveryBackoff = 2
        // Discovery may have found/restarted the core since the first scan. Refresh
        // before publishing healthy flows, not one tick after changing their epoch.
        let identity = controllerIdentity(selected, at: now, discover: false)
        // 请求横跨 socket 重建或已证明的 controller 换代时，不能把响应猜归任一代。
        guard identity == identityBefore else {
            proxiedPIDs = []
            status = "代理归属不可用"
            return nil
        }
        let endpointChanged = lastHealthyEndpointIdentity != identity
        refreshCores(at: now, force: endpointChanged || (corePIDs.isEmpty && (hadCore || refreshedConfiguration)))
        lastHealthyEndpointIdentity = identity
        // 全局核心仅用于 raw 排除；其他代理启停不得改变选中 controller 的 epoch。
        let epoch = identity
        let index = ProxyProbeLogic.SocketIndex(sockets ?? [])
        var executablePaths: [Int: String] = [:]
        var unreadablePIDs: Set<Int> = []
        let flows = parsed.connections.map { connection -> ProxyTraffic in
            let owner = ProxyProbeLogic.owner(
                connection, index: index, localAddresses: localAddresses,
                listeners: configuration.listeners,
                executable: { pid in
                    if let cached = executablePaths[pid] { return cached }
                    if unreadablePIDs.contains(pid) { return nil }
                    if let path = Self.executablePath(pid) { executablePaths[pid] = path; return path }
                    unreadablePIDs.insert(pid)
                    return nil
                }, appName: { bundle in
                    if let cached = self.appNames[bundle] { return cached }
                    let object = Bundle(path: bundle)
                    let name = (object?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (object?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                    if self.appNames.count >= 256 { self.appNames.removeAll(keepingCapacity: true) }
                    self.appNames[bundle] = name
                    return name
                })
            return ProxyTraffic(id: connection.id, start: connection.start,
                                network: connection.network, type: connection.type,
                                source: connection.source, destination: connection.destination,
                                owner: owner, rx: connection.rx, tx: connection.tx,
                                viaProxy: connection.viaProxy)
        }
        proxiedPIDs = Set(flows.filter(\.viaProxy).compactMap { $0.owner?.pid })
        if parsed.partial {
            status = "代理归属不完整"
        } else if !flows.isEmpty && flows.contains(where: { $0.owner == nil }) {
            status = "代理部分已归属"
        } else if coreBirths.isEmpty {
            status = "代理已连接（核心受限）"
        } else {
            status = "代理已归属"
        }
        let tunEnabled = configuration.tunEnabled || parsed.connections.contains { $0.type.lowercased() == "tun" }
        return ProxyTrafficSnapshot(epoch: epoch, flows: flows, tunEnabled: tunEnabled,
                                    acquisitionStartedAt: acquisition.startedAt)
    }

    private func controllerIdentity(_ selected: Endpoint, at now: Date, discover: Bool) -> String {
        let identity = ProxyProbeLogic.endpointIdentity(socket: selected.socket, device: nil, inode: nil)
        guard selected.socket == nil else {
            return controllerEpochState.resolve(identity: identity, verifiedEpoch: selected.identity)
        }
        // lsof 只按十秒节流发现候选；每轮用内核 fd 信息核验，不启动额外工具。
        if discover && now >= nextControllerScan {
            nextControllerScan = now.addingTimeInterval(10)
            controllerListener = nil
            if let data = Self.tool("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:9090", "-sTCP:LISTEN", "-Fpfnt"],
                                    timeout: 0.7, limit: 524_288),
               let output = String(data: data, encoding: .utf8),
               let candidate = ProxyProbeLogic.controllerCandidate(output),
               let birth = Self.processBirth(candidate.pid),
               let generation = Self.controllerSocketGeneration(pid: candidate.pid, fd: candidate.fd),
               Self.processBirth(candidate.pid) == birth {
                controllerListener = .init(pid: candidate.pid, fd: candidate.fd, birth: birth, generation: generation)
            }
        }
        guard let listener = controllerListener else {
            return controllerEpochState.resolve(identity: identity, verifiedEpoch: identity)
        }
        let birthBefore = Self.processBirth(listener.pid)
        let generation = Self.controllerSocketGeneration(pid: listener.pid, fd: listener.fd)
        let birthAfter = Self.processBirth(listener.pid)
        let verified = ProxyProbeLogic.controllerEpoch(identity: identity, listener: listener,
                                                       birthBefore: birthBefore, birthAfter: birthAfter,
                                                       generation: generation)
        return controllerEpochState.resolve(identity: identity, verifiedEpoch: verified)
    }

    private static func controllerSocketGeneration(pid: Int, fd: Int32) -> UInt64? {
        guard pid > 0, pid <= Int(Int32.max), fd >= 0 else { return nil }
        var info = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.size
        guard proc_pidfdinfo(pid_t(pid), fd, PROC_PIDFDSOCKETINFO, &info, Int32(size)) == Int32(size),
              info.psi.soi_kind == SOCKINFO_TCP,
              info.psi.soi_family == AF_INET,
              info.psi.soi_options & Int16(SO_REUSEPORT) == 0 else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        let address = UInt32(bigEndian: tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr)
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        // 仅接受选中 IPv4 controller 的精确地址或 IPv4 通配监听；不猜 IPv6 双栈。
        guard tcp.tcpsi_state == TSI_S_LISTEN, port == 9090,
              address == 0 || address == 0x7f000001,
              tcp.tcpsi_ini.insi_gencnt != 0 else { return nil }
        return tcp.tcpsi_ini.insi_gencnt
    }

    private func discover(at now: Date) -> Endpoint? {
        guard now >= nextDiscovery else { return nil }
        nextDiscovery = now.addingTimeInterval(discoveryBackoff)
        let uid = getuid()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sockets = [
            "/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock",
            "/tmp/clash-verge-service/users/\(uid)/verge-mihomo.sock",
            home + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock"
        ]
        // Missing Unix sockets are free to reject; at most one local TCP candidate.
        let candidates = sockets.filter { FileManager.default.fileExists(atPath: $0) }
            .map { Endpoint(socket: $0) } + [Endpoint(socket: nil)]
        for candidate in candidates {
            guard let data = Self.request(candidate, path: "/version"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? String, !version.isEmpty else { continue }
            endpoint = candidate
            endpointDesc = candidate.description
            nextConfiguration = .distantPast
            // raw 排除需要全局核心集合，与此次选中的 controller 身份独立。
            refreshCores(at: now, force: true)
            return candidate
        }
        discoveryBackoff = min(discoveryBackoff * 2, 30)
        return nil
    }

    private func refreshConfiguration(_ selected: Endpoint) {
        // Only pick non-secret fields from this local response; never retain/log
        // the whole config, or access auth tokens/configuration files.
        guard let data = Self.request(selected, path: "/configs"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var result = Configuration()
        result.tunEnabled = (object["tun"] as? [String: Any])?["enable"] as? Bool ?? false
        result.ports = Set(["mixed-port", "port", "socks-port"].compactMap {
            ProxyProbeLogic.port(object[$0])
        })
        let bind = (object["bind-address"] as? String) ?? "*"
        let allowLAN = object["allow-lan"] as? Bool ?? false
        var addresses: Set<String> = ["127.0.0.1", "::1"]
        if allowLAN {
            if bind == "*" || bind == "0.0.0.0" || bind == "::" {
                addresses.formUnion(localAddresses)
            } else {
                let address = TrafficEndpoint(address: bind, port: 0).address
                if localAddresses.contains(address) { addresses.insert(address) }
            }
        }
        for port in result.ports {
            for address in addresses { result.listeners.insert(TrafficEndpoint(address: address, port: port)) }
        }
        configuration = result
    }

    private func refreshCores(at now: Date, force: Bool) {
        var live: Set<Int> = []
        var births: [Int: String] = [:]
        for pid in corePIDs {
            if let birth = Self.processBirth(pid) {
                // If PID was recycled, require rediscovery by name/listener first.
                if let previous = coreBirths[pid], previous != birth { continue }
                live.insert(pid)
                births[pid] = birth
            } else if Self.processExists(pid) {
                // Lack of permission is not evidence of a reboot; preserve a
                // previously proven incarnation only while that PID still exists.
                live.insert(pid)
                births[pid] = coreBirths[pid]
            }
        }
        corePIDs = live
        coreBirths = births
        guard force || now >= nextCoreScan else { return }
        nextCoreScan = now.addingTimeInterval(10)
        let names = "(verge-mihomo|mihomo|clash|clash-meta|clash-meta-alpha|sing-box|xray|v2ray|hysteria|tuic)"
        var found: Set<Int> = []
        if let data = Self.tool("/usr/bin/pgrep", ["-x", names], timeout: 0.5, limit: 32_768),
           let output = String(data: data, encoding: .utf8) {
            for line in output.split(separator: "\n") {
                if let pid = Int(line), pid > 0, Self.processExists(pid) { found.insert(pid) }
            }
        }
        if found.isEmpty, endpoint != nil, !configuration.ports.isEmpty {
            found = verifiedListenerPIDs()
        }
        // Do not preserve disappeared/non-matching names across a successful scan.
        // pgrep exit 1 and permission errors both produce no result; validated live
        // previous identities are retained only when their executable is unreadable.
        for pid in live where Self.executablePath(pid) == nil { found.insert(pid) }
        corePIDs = found
        coreBirths = [:]
        for pid in found {
            if let birth = Self.processBirth(pid) { coreBirths[pid] = birth }
            else if let birth = births[pid] { coreBirths[pid] = birth }
        }
    }

    private func verifiedListenerPIDs() -> Set<Int> {
        guard let data = Self.tool("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                                   timeout: 0.7, limit: 524_288),
              let output = String(data: data, encoding: .utf8) else { return [] }
        var pid: Int?
        var listeners: [Int: Set<TrafficEndpoint>] = [:]
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()) }
            else if line.first == "n", let pid,
                    let address = ProxyProbeLogic.listener(String(line.dropFirst())) {
                listeners[pid, default: []].insert(address)
            }
        }
        let hints: Set<String> = ["verge-mihomo", "mihomo", "clash", "clash-meta", "clash-meta-alpha",
                                  "sing-box", "xray", "v2ray", "hysteria", "tuic"]
        return Set(listeners.compactMap { pid, addresses -> Int? in
            guard addresses.contains(where: { configuration.ports.contains($0.port) }),
                  Self.processExists(pid) else { return nil }
            let knownExecutable = Self.executablePath(pid).map {
                hints.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased())
            } ?? false
            // An unknown executable must own BOTH the successful TCP controller
            // and its advertised proxy listener; a port number alone proves nothing.
            let controllerOwner = endpoint?.socket == nil && addresses.contains(where: {
                $0.port == 9090 && ($0.isLoopback || $0.isUnspecified)
            })
            return knownExecutable || controllerOwner ? pid : nil
        })
    }

    private static func request(_ endpoint: Endpoint, path: String) -> Data? {
        var args = ["-q", "--noproxy", "*", "--proxy", "", "--fail", "--silent",
                    "--connect-timeout", "0.25", "--max-time", "0.7",
                    "--max-filesize", "8388608", "--proto", "=http"]
        if let socket = endpoint.socket { args += ["--unix-socket", socket] }
        args.append(endpoint.base + path)
        return tool("/usr/bin/curl", args, timeout: 0.95, limit: 8_388_608)
    }

    /// Bounded helper, independent of main.swift's private runTool. Drain stdout
    /// while running to avoid pipe-capacity deadlock; discard all stderr privately.
    private static func tool(_ executable: String, _ args: [String], timeout: TimeInterval, limit: Int) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(key.lowercased()) {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var result = Data()
        var tooLarge = false
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            if result.count <= limit - chunk.count { result.append(chunk) }
            else {
                tooLarge = true
                if process.isRunning { process.terminate() }
                break
            }
        }
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 && !tooLarge ? result : nil
    }

    private static func processExists(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func processBirth(_ pid: Int) -> String? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
              info.pbi_start_tvsec > 0 else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    private static func executablePath(_ pid: Int) -> String? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN; that expression-like C
        // macro is not imported by all supported macOS Swift SDKs.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ProxyProbeLogic.crediblePath(String(cString: buffer))
    }

    private static func interfaceAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return result }
        defer { freeifaddrs(first) }
        var cursor = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(TrafficEndpoint(address: String(cString: host), port: 0).address)
            }
        }
        return result
    }
}

/// Pure parser/mapping helpers. Tests inject executable/bundle lookups and local
/// addresses: no network, subprocesses, file reads, or real PIDs in the self-tests.
private enum ProxyProbeLogic {
    static func endpointIdentity(socket: String?, device: UInt64?, inode: UInt64?) -> String {
        guard let socket else { return "tcp:127.0.0.1:9090" }
        guard let device, let inode else { return "unix:\(socket)" }
        return "unix:\(socket):\(device):\(inode)"
    }

    struct ControllerEpochState {
        private var selectedIdentity: String?
        private var lastProvenEpoch: String?

        mutating func resolve(identity: String, verifiedEpoch: String) -> String {
            if selectedIdentity != identity {
                selectedIdentity = identity
                lastProvenEpoch = nil
            }
            // 暂时失去可读证据不是重启；只保留已证明的代际，不据此认领任何流 owner。
            if verifiedEpoch != identity { lastProvenEpoch = verifiedEpoch }
            return lastProvenEpoch ?? identity
        }
    }

    struct ControllerListener {
        let pid: Int
        let fd: Int32
        let birth: String
        let generation: UInt64
    }

    static func controllerEpoch(identity: String, listener: ControllerListener,
                                birthBefore: String?, birthAfter: String?, generation: UInt64?) -> String {
        guard birthBefore == listener.birth, birthAfter == listener.birth,
              generation == listener.generation else { return identity }
        return identity + "|controller:\(listener.pid):\(listener.birth)"
    }

    static func controllerCandidate(_ output: String) -> (pid: Int, fd: Int32)? {
        var pid: Int?
        var fd: Int32?
        var family: String?
        var candidates: [(pid: Int, fd: Int32)] = []
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int(line.dropFirst()); fd = nil; family = nil
            case "f": fd = Int32(line.dropFirst()); family = nil
            case "t": family = String(line.dropFirst())
            case "n":
                guard let address = listener(String(line.dropFirst())), address.port == 9090,
                      address.address == "127.0.0.1" || address.isUnspecified else { continue }
                // 通配 IPv6、缺失字段或多个潜在 owner 都无法证明谁服务了 IPv4 请求。
                guard family == "IPv4", let pid, pid > 0, let fd, fd >= 0 else { return nil }
                candidates.append((pid, fd))
            default: break
            }
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    static func acquireConnections(request: () -> Data?, clock: () -> Date = Date.init)
        -> (data: Data, startedAt: Date)? {
        // 必须在实际请求之前取时钟；身份核验与 JSON 解析耗时不属于新流可计入窗口。
        let startedAt = clock()
        guard let data = request() else { return nil }
        return (data, startedAt)
    }

    struct Connection {
        let id: String
        let start: Date?
        let network: String
        let type: String
        let source: TrafficEndpoint
        let destination: TrafficEndpoint
        let inbound: TrafficEndpoint?
        let process: String?
        let processPath: String?
        let rx: UInt64
        let tx: UInt64
        let viaProxy: Bool
    }

    struct Parsed {
        let connections: [Connection]
        let partial: Bool
    }

    fileprivate struct SourceKey: Hashable {
        let network: String
        let endpoint: TrafficEndpoint
    }

    struct SocketIndex {
        fileprivate var bySource: [SourceKey: [SocketTraffic]] = [:]
        init(_ sockets: [SocketTraffic]) {
            // Truncation could hide a colliding owner and make it look unique.
            // Oversized input therefore allows path grouping, never a guessed PID.
            guard sockets.count <= 65_536 else { return }
            for socket in sockets {
                bySource[SourceKey(network: socket.network.lowercased(), endpoint: socket.local), default: []].append(socket)
            }
        }
    }

    static func parse(_ data: Data) -> Parsed? {
        guard data.count <= 8_388_608,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["connections"] as? [Any] else { return nil }
        var partial = records.count > 8_192
        var connections: [Connection] = []
        var ids: Set<String> = []
        var duplicateIDs: Set<String> = []
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        for record in records.prefix(8_192) {
            guard let record = record as? [String: Any], let id = record["id"] as? String,
                  !id.isEmpty, id.utf8.count <= 512,
                  let metadata = record["metadata"] as? [String: Any],
                  let network = (metadata["network"] as? String)?.lowercased(), ["tcp", "udp"].contains(network),
                  let type = metadata["type"] as? String, !type.isEmpty, type.count <= 64,
                  let sourceIP = metadata["sourceIP"] as? String, numericIP(sourceIP),
                  let sourcePort = port(metadata["sourcePort"]),
                  metadata["processPath"] == nil || metadata["processPath"] is String || metadata["processPath"] is NSNull,
                  let destinationIP = metadata["destinationIP"] as? String,
                  let destinationPort = port(metadata["destinationPort"]),
                  let rx = counter(record["download"]), let tx = counter(record["upload"]) else {
                partial = true
                continue
            }
            // A domain-based HTTP CONNECT may not have resolved destinationIP yet.
            // It still has ingress payload bytes, so retain a bounded host identity.
            let destinationAddress: String
            if !destinationIP.isEmpty, numericIP(destinationIP) {
                destinationAddress = destinationIP
            } else if destinationIP.isEmpty, let host = metadata["host"] as? String,
                      !host.isEmpty, host.utf8.count <= 253,
                      !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
                destinationAddress = host.lowercased()
            } else {
                partial = true
                continue
            }
            let start: Date?
            if let value = record["start"], !(value is NSNull) {
                guard let text = value as? String,
                      let date = fractional.date(from: text) ?? seconds.date(from: text) else {
                    partial = true
                    continue
                }
                start = date
            } else { start = nil }
            let inbound: TrafficEndpoint?
            if let ip = metadata["inboundIP"] as? String, numericIP(ip),
               let port = port(metadata["inboundPort"]) {
                inbound = TrafficEndpoint(address: ip, port: port)
            } else { inbound = nil }
            if !ids.insert(id).inserted { duplicateIDs.insert(id); partial = true }
            connections.append(Connection(id: id, start: start, network: network, type: type,
                source: TrafficEndpoint(address: sourceIP, port: sourcePort),
                destination: TrafficEndpoint(address: destinationAddress, port: destinationPort),
                inbound: inbound, process: metadata["process"] as? String,
                processPath: metadata["processPath"] as? String, rx: rx, tx: tx,
                viaProxy: hasProxyChain(record["chains"] as? [String])))
        }
        // Duplicate IDs cannot be safely accounted, even if each row looks valid.
        return Parsed(connections: connections.filter { !duplicateIDs.contains($0.id) }, partial: partial)
    }

    static func owner(_ connection: Connection, index: SocketIndex, localAddresses: Set<String>,
                      listeners: Set<TrafficEndpoint>, executable: (Int) -> String?,
                      appName: (String) -> String?) -> TrafficOwner? {
        guard !connection.source.isUnspecified,
              connection.source.isLoopback || localAddresses.contains(connection.source.address) else { return nil }
        let candidates = (index.bySource[SourceKey(network: connection.network, endpoint: connection.source)] ?? []).filter { socket in
            guard socket.owner.pid != nil else { return false }
            if connection.type.lowercased() == "tun" {
                return socket.remote == connection.destination
            }
            // Explicit proxy ingress: source tuple alone is insufficient. Verify
            // the client's peer against metadata's listener, or current config.
            if let inbound = connection.inbound, !inbound.isUnspecified {
                return (inbound.isLoopback || localAddresses.contains(inbound.address)) && socket.remote == inbound
            }
            if let inbound = connection.inbound, inbound.isUnspecified {
                return socket.remote.port == inbound.port && listeners.contains(socket.remote)
            }
            return listeners.contains(socket.remote)
        }
        if candidates.count == 1, let candidate = candidates.first, let pid = candidate.owner.pid {
            if connection.processPath == nil || connection.processPath?.isEmpty == true {
                return candidate.owner
            }
            // owner.path can be a Node entry script/app bundle, not executable.
            // Only proc_pidpath validates metadata.processPath for a PID match.
            if let expected = crediblePath(connection.processPath),
               let actual = executable(pid).flatMap(crediblePath), actual == expected {
                return candidate.owner
            }
        }
        // Ambiguous sockets, path mismatch, or unreadable executable must not
        // invent a PID. A local metadata executable still permits honest grouping.
        guard let path = crediblePath(connection.processPath) else { return nil }
        let parts = URL(fileURLWithPath: path).pathComponents
        let appIndex = parts.firstIndex { $0.lowercased().hasSuffix(".app") }
        let ownerPath: String
        let name: String
        if let appIndex {
            ownerPath = NSString.path(withComponents: Array(parts[...appIndex]))
            name = appName(ownerPath) ?? URL(fileURLWithPath: ownerPath).deletingPathExtension().lastPathComponent
        } else {
            ownerPath = path
            name = URL(fileURLWithPath: path).lastPathComponent
        }
        return TrafficOwner(pid: nil, incarnation: "path:" + ownerPath, name: name, path: ownerPath)
    }

    static func crediblePath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 4_096,
              !value.hasSuffix("/"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        guard path != "/", !path.lowercased().hasSuffix(".app") else { return nil }
        return path
    }

    static func port(_ value: Any?) -> Int? {
        guard let value = counter(value), value > 0, value <= 65_535 else { return nil }
        return Int(value)
    }

    private static func counter(_ value: Any?) -> UInt64? {
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            text = number.stringValue
        } else if let string = value as? String { text = string }
        else { return nil }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }

    private static func numericIP(_ address: String) -> Bool {
        let normalized = TrafficEndpoint(address: address, port: 0).address
        let pieces = normalized.split(separator: "%", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let host = pieces.first, !host.isEmpty else { return false }
        if pieces.count == 2, pieces[1].isEmpty { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        return String(host).withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    static func listener(_ value: String) -> TrafficEndpoint? {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
              (1...65_535).contains(port) else { return nil }
        let address = String(value[..<colon])
        guard address == "*" || numericIP(address) else { return nil }
        return TrafficEndpoint(address: address, port: port)
    }

    private static func hasProxyChain(_ chains: [String]?) -> Bool {
        guard let chains else { return false }
        let names = chains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        let nonProxy: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "BLOCK", "PASS"]
        return !names.isEmpty && !names.contains(where: nonProxy.contains)
    }
}

enum ProxyProbeSelfTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "ProxyProbeSelfTests: " + message) }
        }
        func row(id: String = "flow-1", source: String = "127.0.0.1", sourcePort: Any = "51000",
                 destination: String = "203.0.113.9", type: String = "HTTPS", inbound: String = "127.0.0.1",
                 inboundPort: Any = 7897, path: String? = "/opt/bin/node", download: Any = 100,
                 chains: [String] = ["DIRECT"]) -> [String: Any] {
            var metadata: [String: Any] = ["network": "tcp", "type": type, "sourceIP": source,
                "sourcePort": sourcePort, "destinationIP": destination, "destinationPort": "443",
                "inboundIP": inbound, "inboundPort": inboundPort, "process": "node"]
            metadata["processPath"] = path
            return ["id": id, "start": "2026-10-22T13:00:00.123456789Z", "metadata": metadata,
                    "upload": "20", "download": download, "chains": chains]
        }
        func parse(_ records: [[String: Any]]) -> ProxyProbeLogic.Parsed? {
            guard let data = try? JSONSerialization.data(withJSONObject: ["connections": records]) else { return nil }
            return ProxyProbeLogic.parse(data)
        }
        // Regression：身份只由选中端点/监听证据决定；不读取真实进程、服务或 socket。
        let unixIdentity = ProxyProbeLogic.endpointIdentity(socket: "/test/controller.sock", device: 1, inode: 100)
        try expect(unixIdentity == "unix:/test/controller.sock:1:100", "selected Unix inode identity")
        try expect(unixIdentity != ProxyProbeLogic.endpointIdentity(socket: "/test/controller.sock", device: 1, inode: 101),
                   "selected Unix socket recreation changes epoch")
        try expect(ProxyProbeLogic.endpointIdentity(socket: "/test/controller.sock", device: nil, inode: nil) == "unix:/test/controller.sock",
                   "unreadable Unix evidence does not invent birth")
        let tcpIdentity = ProxyProbeLogic.endpointIdentity(socket: nil, device: nil, inode: nil)
        let selectedListener = ProxyProbeLogic.ControllerListener(pid: 41, fd: 9, birth: "100.10", generation: 55)
        func epoch(_ listener: ProxyProbeLogic.ControllerListener = selectedListener,
                   before: String? = "100.10", after: String? = "100.10", generation: UInt64? = 55) -> String {
            ProxyProbeLogic.controllerEpoch(identity: tcpIdentity, listener: listener,
                                             birthBefore: before, birthAfter: after, generation: generation)
        }
        try expect(epoch() == "tcp:127.0.0.1:9090|controller:41:100.10", "TCP epoch uses proven selected listener birth only")
        try expect(epoch(before: nil) == tcpIdentity && epoch(after: nil) == tcpIdentity,
                   "unreadable birth cannot prove selected ownership")
        try expect(epoch(after: "101.20") == tcpIdentity && epoch(generation: 56) == tcpIdentity,
                   "PID or fd reuse cannot reuse controller proof")
        let restartedListener = ProxyProbeLogic.ControllerListener(pid: 41, fd: 9, birth: "101.20", generation: 56)
        try expect(epoch(restartedListener, before: "101.20", after: "101.20", generation: 56) != epoch(),
                   "proven selected controller restart changes epoch")
        var epochState = ProxyProbeLogic.ControllerEpochState()
        try expect(epochState.resolve(identity: tcpIdentity, verifiedEpoch: epoch()) == epoch(), "cache proven selected epoch")
        try expect(epochState.resolve(identity: tcpIdentity, verifiedEpoch: epoch(before: nil)) == epoch(),
                   "temporary unreadable proof preserves selected epoch")
        try expect(epochState.resolve(identity: tcpIdentity, verifiedEpoch: epoch()) == epoch(),
                   "restored proof does not reset epoch a second time")
        try expect(epochState.resolve(identity: tcpIdentity, verifiedEpoch: epoch(after: "101.20")) == epoch(),
                   "unbound recycled PID cannot assert selected restart")
        let restartedEpoch = epoch(restartedListener, before: "101.20", after: "101.20", generation: 56)
        try expect(epochState.resolve(identity: tcpIdentity, verifiedEpoch: restartedEpoch) == restartedEpoch,
                   "new proven selected birth replaces retained epoch")
        let unixBase = ProxyProbeLogic.endpointIdentity(socket: "/test/controller.sock", device: nil, inode: nil)
        try expect(epochState.resolve(identity: unixBase, verifiedEpoch: unixIdentity) == unixIdentity,
                   "switching selected endpoint cannot inherit another controller birth")
        try expect(epochState.resolve(identity: unixBase, verifiedEpoch: unixBase) == unixIdentity,
                   "temporary unreadable Unix inode preserves proven epoch")
        try expect(epochState.resolve(identity: unixBase, verifiedEpoch: unixIdentity) == unixIdentity,
                   "restored Unix inode does not reset epoch")
        let replacedUnix = ProxyProbeLogic.endpointIdentity(socket: "/test/controller.sock", device: 1, inode: 101)
        try expect(epochState.resolve(identity: unixBase, verifiedEpoch: replacedUnix) == replacedUnix,
                   "proven new selected Unix inode replaces cached evidence")
        let selectedOutput = "p41\nf9\ntIPv4\nn127.0.0.1:9090\n"
        let unrelatedOutput = "p99\nf12\ntIPv4\nn127.0.0.1:7897\n"
        let candidate = ProxyProbeLogic.controllerCandidate(selectedOutput + unrelatedOutput)
        try expect(candidate?.pid == 41 && candidate?.fd == 9,
                   "unrelated proxy listeners do not change selected controller")
        try expect(ProxyProbeLogic.controllerCandidate(selectedOutput)?.pid == candidate?.pid,
                   "unrelated core disappearance cannot change selected evidence")
        try expect(ProxyProbeLogic.controllerCandidate(unrelatedOutput) == nil, "proxy listener alone is not controller ownership")
        try expect(ProxyProbeLogic.controllerCandidate(selectedOutput + "p99\nf12\ntIPv4\nn*:9090\n") == nil,
                   "ambiguous controller ownership is not guessed")
        try expect(ProxyProbeLogic.controllerCandidate("p41\nf9\ntIPv6\nn*:9090\n") == nil,
                   "IPv6 wildcard does not prove selected IPv4 controller")
        try expect(ProxyProbeLogic.controllerCandidate("p41\ntIPv4\nn127.0.0.1:9090\n") == nil,
                   "missing fd does not prove controller ownership")
        var acquisitionEvents: [String] = []
        let requestStart = Date(timeIntervalSince1970: 100)
        let acquired = ProxyProbeLogic.acquireConnections(request: {
            acquisitionEvents.append("request")
            return Data("{\"connections\":[]}".utf8)
        }, clock: {
            acquisitionEvents.append("clock")
            return requestStart
        })!
        let snapshot = ProxyTrafficSnapshot(epoch: epoch(), flows: [], tunEnabled: false,
                                            acquisitionStartedAt: acquired.startedAt)
        try expect(acquisitionEvents == ["clock", "request"] && snapshot.acquisitionStartedAt == requestStart,
                   "snapshot carries actual pre-request time, not post-identity resolution time")
        try expect(ProxyProbeLogic.acquireConnections(request: { nil }, clock: { requestStart }) == nil,
                   "failed request does not produce an acquisition")
        let node = TrafficOwner(pid: 41, incarnation: "41:birth", name: "worker.js", path: "/work/worker.js")
        let other = TrafficOwner(pid: 42, incarnation: "42:birth", name: "Other", path: "/opt/other")
        func socket(_ owner: TrafficOwner, local: String = "127.0.0.1", peer: String = "127.0.0.1",
                    port: Int = 7897, network: String = "tcp") -> SocketTraffic {
            SocketTraffic(key: "\(owner.incarnation):\(local):\(peer):\(port)", owner: owner, network: network,
                          local: TrafficEndpoint(address: local, port: 51000),
                          remote: TrafficEndpoint(address: peer, port: port), interface: "lo0", rx: 0, tx: 0)
        }
        let valid = parse([row()])!
        try expect(valid.connections.count == 1 && !valid.partial, "valid schema")
        let flow = valid.connections[0]
        try expect(flow.id == "flow-1" && flow.start != nil && flow.rx == 100 && flow.tx == 20, "id/start/directions")
        try expect(!flow.viaProxy, "DIRECT retained without proxy label")
        func owner(_ flow: ProxyProbeLogic.Connection, _ sockets: [SocketTraffic],
                   locals: Set<String> = [], executable: String? = "/opt/bin/node",
                   listeners: Set<TrafficEndpoint> = []) -> TrafficOwner? {
            ProxyProbeLogic.owner(flow, index: .init(sockets), localAddresses: locals,
                                  listeners: listeners, executable: { _ in executable }, appName: { _ in nil })
        }
        try expect(owner(flow, [socket(node)]) == node, "preserve Node script identity after executable verification")
        try expect(owner(flow, [socket(node), socket(other, peer: "127.0.0.2")]) == node, "peer exact matching, not source-port only")
        try expect(owner(flow, [socket(other, local: "127.0.0.2")])?.pid == nil, "source IP collision")
        try expect(owner(flow, [socket(node, network: "udp")])?.pid == nil, "network collision")
        try expect(owner(flow, [socket(node), socket(other)])?.pid == nil, "ambiguous sockets do not pick PID")
        try expect(owner(flow, [socket(node)], executable: "/opt/bin/other")?.pid == nil, "mismatching executable")
        try expect(owner(flow, [socket(node)], executable: nil)?.pid == nil, "unreadable executable is conservative")
        let fallback = owner(flow, [])
        try expect(fallback?.path == "/opt/bin/node" && fallback?.name == "node" && fallback?.incarnation == "path:/opt/bin/node", "runtime path fallback, not script")
        let app = parse([row(path: "/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/Helper")])!.connections[0]
        let appOwner = owner(app, [])
        try expect(appOwner?.path == "/Applications/Outer.app" && appOwner?.name == "Outer", "outermost app bundle fallback")
        let foreign = parse([row(source: "192.0.2.88")])!.connections[0]
        try expect(owner(foreign, [socket(node, local: "192.0.2.88")]) == nil, "foreign LAN source cannot claim local PID or path")
        try expect(owner(foreign, [], locals: ["192.0.2.88"])?.pid == nil, "validated local interface allows path fallback")
        let noPath = parse([row(path: nil)])!.connections[0]
        try expect(owner(noPath, []) == nil, "unknown without credible path")
        try expect(owner(noPath, [socket(node)]) == node, "unique full ingress tuple does not require metadata path")
        let v6 = parse([row(source: "[::1]", destination: "2001:db8::9", inbound: "0:0:0:0:0:0:0:1")])!.connections[0]
        try expect(owner(v6, [socket(node, local: "::1", peer: "::1")]) == node, "IPv6 normalization and string ports")
        let mapped = parse([row(source: "::ffff:127.0.0.1")])!.connections[0]
        try expect(owner(mapped, [socket(node)]) == node, "IPv4 mapped IPv6")
        let tun = parse([row(source: "192.0.2.10", type: "Tun")])!.connections[0]
        try expect(owner(tun, [socket(node, local: "192.0.2.10", peer: "203.0.113.9", port: 443)], locals: ["192.0.2.10"]) == node, "TUN full tuple")
        try expect(owner(tun, [socket(node, local: "192.0.2.10", peer: "203.0.113.8", port: 443)], locals: ["192.0.2.10"])?.pid == nil, "TUN destination collision")
        var noInboundRow = row()
        var noInboundMetadata = noInboundRow["metadata"] as! [String: Any]
        noInboundMetadata.removeValue(forKey: "inboundIP")
        noInboundMetadata.removeValue(forKey: "inboundPort")
        noInboundRow["metadata"] = noInboundMetadata
        let noInbound = parse([noInboundRow])!.connections[0]
        try expect(owner(noInbound, [socket(node)])?.pid == nil, "unverified listener rejected")
        try expect(owner(noInbound, [socket(node)], listeners: [TrafficEndpoint(address: "127.0.0.1", port: 7897)]) == node, "configured listener fallback")
        let wildcard = parse([row(inbound: "0.0.0.0")])!.connections[0]
        try expect(owner(wildcard, [socket(node)])?.pid == nil, "wildcard inbound is not exact listener evidence")
        try expect(owner(wildcard, [socket(node)], listeners: [TrafficEndpoint(address: "127.0.0.1", port: 7897)]) == node, "wildcard needs configured listener")
        try expect(parse([row(sourcePort: true)])?.connections.isEmpty == true, "boolean port rejected")
        var malformedStart = row()
        malformedStart["start"] = "not-a-date"
        try expect(parse([malformedStart])?.partial == true, "malformed start skipped")
        var noStart = row()
        noStart.removeValue(forKey: "start")
        try expect(parse([noStart])?.connections[0].start == nil, "missing start retained as optional")
        for bad in [-1, 1.5, true, "-1", "1.5", "18446744073709551616", "NaN"] as [Any] {
            let parsed = parse([row(download: bad)])!
            try expect(parsed.partial && parsed.connections.isEmpty, "invalid counters skipped, never default zero")
        }
        try expect(parse([row(download: "18446744073709551615")])?.connections[0].rx == UInt64.max, "UInt64 string counter")
        try expect(parse([row(), row(id: "bad", download: "bad")])?.connections.count == 1, "one bad record does not discard good rows")
        try expect(parse([])?.connections.isEmpty == true && parse([])?.partial == false, "successful empty list")
        for object: Any in [[:], ["connections": [:]], ["connections": NSNull()], ["connections": "bad"], []] {
            let data = try JSONSerialization.data(withJSONObject: object)
            try expect(ProxyProbeLogic.parse(data) == nil, "invalid top-level schema is failure")
        }
        try expect(parse([row(), row()])?.connections.isEmpty == true, "duplicate IDs not guessed")
        try expect(parse([row(chains: ["a-proxy", "auto"])])?.connections[0].viaProxy == true, "non-direct chain label")
        for chains in [["DIRECT"], [" direct "], ["REJECT"], ["REJECT-DROP"], ["BLOCK"], ["PASS"], ["DIRECT", "auto"], []] {
            try expect(parse([row(chains: chains)])?.connections[0].viaProxy == false, "direct/blocked/empty route is not proxy-labelled")
        }
        var noChains = row()
        noChains.removeValue(forKey: "chains")
        try expect(parse([noChains])?.connections[0].viaProxy == false, "missing route is not proxy-labelled")
        try expect(parse([row(chains: ["REJECT"])])?.connections.count == 1, "REJECT also retained")
        try expect(ProxyProbeLogic.crediblePath("/x/../bin/node") == nil && ProxyProbeLogic.crediblePath("node") == nil, "untrusted fallback path")
    }
}
