import Foundation
import Darwin

// Pure traffic accounting. Neither a process-wide counter nor the proxy core's
// wire counter is an application byte counter; only individual flows are added.
struct TrafficEndpoint: Hashable {
    let address: String
    let port: Int

    init(address: String, port: Int) {
        self.address = Self.normalizedAddress(address)
        self.port = port
    }

    var isLoopback: Bool {
        let host = address.components(separatedBy: "%")[0]
        if host == "::1" { return true }
        var value = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &value) }) == 1 else { return false }
        return (UInt32(bigEndian: value.s_addr) >> 24) == 127
    }

    var isUnspecified: Bool {
        let host = address.components(separatedBy: "%")[0]
        return host.isEmpty || host == "*" || host == "0.0.0.0" || host == "::"
    }

    // nettop prints IPv4 as address:port, IPv6 as address%scope.port.
    // Brackets remove the IPv6 port ambiguity; unbracketed IPv6 :port is not guessed.
    static func parseNettop(_ s: String) -> TrafficEndpoint? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let service: String
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<end])
            let suffix = text[text.index(after: end)...]
            guard suffix.first == ":" || suffix.first == "." else { return nil }
            service = String(suffix.dropFirst())
        } else if text.contains(":"), let dot = text.lastIndex(of: "."),
                  text[..<dot].contains(":") {
            host = String(text[..<dot])
            service = String(text[text.index(after: dot)...])
        } else if let colon = text.lastIndex(of: ":"), !text[..<colon].contains(":") {
            host = String(text[..<colon])
            service = String(text[text.index(after: colon)...])
        } else if text.hasPrefix("*.") {
            host = "*"
            service = String(text.dropFirst(2))
        } else {
            return nil
        }
        let port: Int
        if host == "*", service == "*" {
            port = 0
        } else {
            guard !service.isEmpty, service.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(service), (0...65535).contains(number) else { return nil }
            port = number
        }
        guard isNumericAddress(host) || host == "*" else { return nil }
        return TrafficEndpoint(address: host, port: port)
    }

    private static func isNumericAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return false }
        if parts.count == 2 {
            guard host.contains(":"), !parts[1].isEmpty,
                  parts[1].unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
                  }) else { return false }
        }
        var v4 = in_addr()
        var v6 = in6_addr()
        return String(host).withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    private static func normalizedAddress(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let host = parts.first.map(String.init) ?? ""
        let scope = parts.count == 2 ? "%" + parts[1] : ""
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil {
                return String(cString: buffer)
            }
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return bytes[12...15].map(String.init).joined(separator: ".")
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil {
                // A scoped link-local endpoint must not equal an unscoped endpoint.
                return String(cString: buffer) + scope
            }
        }
        return text
    }
}

struct TrafficOwner: Hashable {
    let pid: Int?
    let incarnation: String
    let name: String
    let path: String?

    init(pid: Int? = nil, incarnation: String = "", name: String, path: String? = nil) {
        self.pid = pid
        self.incarnation = incarnation
        self.name = name
        self.path = path
    }

    static let unknown = TrafficOwner(incarnation: "unknown", name: "Unknown")
}

struct SocketTraffic {
    let key: String
    let owner: TrafficOwner
    let network: String
    let local: TrafficEndpoint
    let remote: TrafficEndpoint
    let interface: String
    let rx: UInt64
    let tx: UInt64

    init(key: String, owner: TrafficOwner, network: String, local: TrafficEndpoint,
         remote: TrafficEndpoint, interface: String, rx: UInt64, tx: UInt64) {
        self.key = key
        self.owner = owner
        self.network = network.lowercased()
        self.local = local
        self.remote = remote
        self.interface = interface
        self.rx = rx
        self.tx = tx
    }

    // sendto/recvfrom UDP sockets can carry the whole remote session without a
    // connected peer. nettop reports their peer as *:* (or *.*), not a zero flow.
    var isUnconnectedUDP: Bool {
        network == "udp" && remote.isUnspecified && remote.port == 0
    }

    // 保留旧调用接口；需要判定 socket 消失的调用方必须使用带歧义信息的快照。
    static func parseCSV(_ text: String, owner: (Int, String) -> TrafficOwner) -> [SocketTraffic]? {
        parseSnapshotCSV(text, owner: owner)?.sockets
    }

    // nil 表示不可用而非健康空快照；重复行不计数，但仍证明该 identity 未明确消失。
    static func parseSnapshotCSV(_ text: String, owner: (Int, String) -> TrafficOwner) -> SocketTrafficSnapshot? {
        guard let records = csvRecords(text) else { return nil }
        var header: [String]?
        var indices: [String: Int] = [:]
        var currentOwner: TrafficOwner?
        var parsed: [SocketTraffic] = []
        var frequencies: [String: Int] = [:]
        for var record in records {
            if record.isEmpty || record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            // nettop appends one CSV terminator after its five actual columns.
            // Empty last counters are real columns, not extra terminators.
            if record.count == 6, record.last == "" { record.removeLast() }
            if header == nil {
                let names = record.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard names.first == "", names.count == 5,
                      Set(names.dropFirst()) == Set(["interface", "state", "bytes_in", "bytes_out"]) else { return nil }
                header = names
                for (index, name) in names.enumerated() { indices[name] = index }
                continue
            }
            guard record.count == header?.count,
                  let interfaceIndex = indices["interface"], let stateIndex = indices["state"],
                  let rxIndex = indices["bytes_in"], let txIndex = indices["bytes_out"] else { return nil }
            let rxText = record[rxIndex].trimmingCharacters(in: .whitespaces)
            let txText = record[txIndex].trimmingCharacters(in: .whitespaces)
            let label = record[0].trimmingCharacters(in: .whitespaces)
            let pieces = label.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let protocolName = pieces.first.map(String.init) ?? ""
            if ["tcp4", "tcp6", "udp4", "udp6", "tcp", "udp"].contains(protocolName) {
                guard pieces.count == 2, let connectionOwner = currentOwner else { return nil }
                let endpoints = pieces[1].components(separatedBy: "<->")
                guard endpoints.count == 2, let local = TrafficEndpoint.parseNettop(endpoints[0]),
                      let remote = TrafficEndpoint.parseNettop(endpoints[1]) else { return nil }
                let network = protocolName.hasPrefix("tcp") ? "tcp" : "udp"
                let state = record[stateIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let inactiveStates: Set<String> = ["listen", "closed", "timewait", "synsent", "synreceived", "finwait1", "finwait2", "closing", "closewait", "lastack"]
                if rxText.isEmpty && txText.isEmpty,
                   remote.isUnspecified || inactiveStates.contains(state) || (network == "udp" && state.isEmpty) {
                    // Inactive/listening rows legitimately have no counters. Do
                    // not invalidate the snapshot or lose this process context.
                    continue
                }
                guard let rx = csvCounter(rxText), let tx = csvCounter(txText) else { return nil }
                let interface = record[interfaceIndex].trimmingCharacters(in: .whitespaces)
                let key = identityKey(owner: connectionOwner, network: network, local: local, remote: remote, interface: interface)
                frequencies[key, default: 0] += 1
                parsed.append(SocketTraffic(key: key, owner: connectionOwner, network: network,
                                            local: local, remote: remote, interface: interface, rx: rx, tx: tx))
            } else {
                guard let dot = label.lastIndex(of: "."), dot != label.startIndex,
                      let pid = Int(label[label.index(after: dot)...]), pid > 0,
                      record[stateIndex].isEmpty,
                      csvCounter(rxText) != nil, csvCounter(txText) != nil else { return nil }
                // Current nettop can emit one process-summary row per interface,
                // with `interface` populated (for example `en0`). These aggregate
                // counters are deliberately ignored; accept them only as owner
                // context for the following per-socket rows.
                currentOwner = owner(pid, String(label[..<dot]))
            }
        }
        guard header != nil else { return nil }
        return SocketTrafficSnapshot(sockets: parsed.filter { frequencies[$0.key] == 1 },
                                     ambiguousIdentities: Set(frequencies.filter { $0.value > 1 }.map(\.key)))
    }

    fileprivate static func identityKey(owner: TrafficOwner, network: String, local: TrafficEndpoint,
                                        remote: TrafficEndpoint, interface: String) -> String {
        keyParts([owner.pid.map(String.init) ?? "?", owner.incarnation, network,
                  local.address, String(local.port), remote.address, String(remote.port), interface])
    }

    private static func csvCounter(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }

    private static func csvRecords(_ text: String) -> [[String]]? {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                        closedQuote = true
                    }
                } else { field.append(char) }
            } else if char == "," {
                row.append(field); field = ""; closedQuote = false
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                row.append(field); records.append(row)
                field = ""; row = []; closedQuote = false
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else if char == "\"" {
                guard field.isEmpty, !closedQuote else { return nil }
                quoted = true
            } else {
                guard !closedQuote else { return nil }
                field.append(char)
            }
            index += 1
        }
        guard !quoted else { return nil }
        if !field.isEmpty || !row.isEmpty || closedQuote { row.append(field); records.append(row) }
        return records
    }
}

// 歧义 identity 不产生字节，但不能被当作已关闭 socket 的证据。
struct SocketTrafficSnapshot {
    let sockets: [SocketTraffic]
    let ambiguousIdentities: Set<String>
}

struct ProxyTraffic {
    let id: String
    let start: Date?
    let network: String
    let type: String
    let source: TrafficEndpoint
    let destination: TrafficEndpoint
    let owner: TrafficOwner?
    let rx: UInt64
    let tx: UInt64
    let viaProxy: Bool

    init(id: String, start: Date? = nil, network: String, type: String,
         source: TrafficEndpoint, destination: TrafficEndpoint, owner: TrafficOwner? = nil,
         rx: UInt64, tx: UInt64, viaProxy: Bool) {
        self.id = id
        self.start = start
        self.network = network.lowercased()
        self.type = type
        self.source = source
        self.destination = destination
        self.owner = owner
        self.rx = rx
        self.tx = tx
        self.viaProxy = viaProxy
    }
}

struct ProxyTrafficSnapshot {
    let epoch: String
    let flows: [ProxyTraffic]
    let tunEnabled: Bool
    let acquisitionStartedAt: Date?

    init(epoch: String, flows: [ProxyTraffic], tunEnabled: Bool, acquisitionStartedAt: Date? = nil) {
        self.epoch = epoch
        self.flows = flows
        self.tunEnabled = tunEnabled
        self.acquisitionStartedAt = acquisitionStartedAt
    }
}

struct TrafficDelta {
    let owner: TrafficOwner
    let rx: UInt64
    let tx: UInt64
    let rxRate: Double
    let txRate: Double
    let viaProxy: Bool
}

private func keyParts(_ parts: [String]) -> String {
    parts.map { "\($0.utf8.count):\($0)" }.joined()
}

struct AttributionLedger {
    // Per-sample diagnostics, not additive byte estimates. The UI can expose
    // these when conservative exclusions make the attribution incomplete.
    private(set) var diagnostics: [String] = []

    private struct Tuple: Hashable {
        let network: String
        let source: TrafficEndpoint
        let destination: TrafficEndpoint
    }
    private struct Source: Hashable {
        let network: String
        let endpoint: TrafficEndpoint
    }
    private struct ProxyKey: Hashable {
        let epoch: String
        let id: String
        let start: Date?
        var sortKey: String { keyParts([epoch, id, start.map { String($0.timeIntervalSinceReferenceDate) } ?? "?"]) }
    }
    private struct Baseline {
        var rx: UInt64
        var tx: UInt64
        var at: Date
        var owner: TrafficOwner?
        var tuple: Tuple
        var coveredByAPI = false
        var socketIdentity: String?
        var needsRebaseline = false
    }

    private var socketBaselines: [String: Baseline] = [:]
    private var proxyBaselines: [ProxyKey: Baseline] = [:]
    private var proxyEpoch: String?
    private var lastHealthyProxyBoundary: Date?
    private var resetAt: Date?
    private var lastProxyTuples: Set<Tuple> = []
    private var lastProxySources: Set<Source> = []
    private var lastTunEnabled = false
    private var proxyWasUnavailable = false
    private static let retention: TimeInterval = 24 * 60 * 60
    private static let capacity = 16_384

    init() {}

    mutating func reset(at: Date) {
        socketBaselines.removeAll()
        proxyBaselines.removeAll()
        proxyEpoch = nil
        lastHealthyProxyBoundary = nil
        resetAt = at
        lastProxyTuples.removeAll()
        lastProxySources.removeAll()
        lastTunEnabled = false
        proxyWasUnavailable = false
        diagnostics = []
    }

    mutating func sample(sockets: [SocketTraffic]?, proxy: ProxyTrafficSnapshot?,
                         corePIDs: Set<Int>, at: Date,
                         ambiguousSocketIdentities: Set<String> = []) -> [TrafficDelta] {
        diagnostics = []
        var result: [TrafficDelta] = []
        var apiTuples = lastProxyTuples
        var apiSources = lastProxySources
        var tunEnabled = lastTunEnabled
        if let snapshot = proxy {
            let epochChanged = proxyEpoch != nil && proxyEpoch != snapshot.epoch
            if epochChanged {
                // Parent must include the core incarnation/restart in epoch.
                // Direct sockets are independent of a core restart.
                proxyBaselines.removeAll()
                diagnostics.append("proxy-epoch-changed: proxy counters rebaselined")
            }
            tunEnabled = snapshot.tunEnabled || snapshot.flows.contains { $0.type.lowercased() == "tun" }
            let uncertainTunTransition = proxyWasUnavailable && tunEnabled && !lastTunEnabled
            if uncertainTunTransition {
                // While the API said TUN was off, raw physical flows may have
                // been counted. A newly discovered TUN flow cannot replay that gap.
                diagnostics.append("tun-mode-changed-during-outage: unseen API flows rebaselined")
            }
            let newFlowBoundary = epochChanged || uncertainTunTransition ? nil : (lastHealthyProxyBoundary ?? resetAt)
            proxyEpoch = snapshot.epoch
            apiTuples = Set(snapshot.flows.map { Tuple(network: $0.network, source: $0.source, destination: $0.destination) })
            apiSources = Set(snapshot.flows.map { Source(network: $0.network, endpoint: $0.source) })
            let groups = Dictionary(grouping: snapshot.flows) { ProxyKey(epoch: snapshot.epoch, id: $0.id, start: $0.start) }
            for key in groups.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
                guard let group = groups[key], group.count == 1, let flow = group.first,
                      !flow.id.isEmpty, ["tcp", "udp"].contains(flow.network) else {
                    diagnostics.append("ambiguous-proxy-identity: skipped duplicate or invalid API flow")
                    continue
                }
                let tuple = Tuple(network: flow.network, source: flow.source, destination: flow.destination)
                if var baseline = proxyBaselines[key], baseline.tuple == tuple {
                    appendDelta(rx: flow.rx, tx: flow.tx, baseline: baseline, at: at,
                                viaProxy: flow.viaProxy, into: &result)
                    // Ownership discovered now applies only to future intervals.
                    if baseline.owner == nil || baseline.owner == .unknown, let known = flow.owner {
                        // A validated executable-path owner can be known without
                        // a PID. Once established it is frozen just like a PID.
                        baseline.owner = known
                    }
                    baseline.rx = flow.rx; baseline.tx = flow.tx; baseline.at = at
                    proxyBaselines[key] = baseline
                } else {
                    if let boundary = newFlowBoundary, let start = flow.start,
                       start > boundary, start < at {
                        let zero = Baseline(rx: 0, tx: 0, at: start, owner: flow.owner, tuple: tuple)
                        // Changed tuples with a reused id are not demonstrably new.
                        if proxyBaselines[key] == nil {
                            appendDelta(rx: flow.rx, tx: flow.tx, baseline: zero, at: at,
                                        viaProxy: flow.viaProxy, into: &result)
                        }
                    }
                    let previousOwner = proxyBaselines[key]?.owner
                    let frozenOwner = previousOwner == nil || previousOwner == .unknown ? flow.owner : previousOwner
                    if proxyBaselines[key] != nil {
                        diagnostics.append("proxy-tuple-changed: counters rebaselined; established owner retained")
                    }
                    proxyBaselines[key] = Baseline(rx: flow.rx, tx: flow.tx, at: at, owner: frozenOwner, tuple: tuple)
                }
            }
            // 请求开始后才出生的 flow 可能未进入本轮响应；下一轮应允许记首段。
            // 兼容没有采集时间的调用；异常未来时间不可信，reset 和旧边界均不可倒退。
            let acquiredAt = snapshot.acquisitionStartedAt.flatMap { $0 <= at ? $0 : nil } ?? at
            lastHealthyProxyBoundary = [acquiredAt, lastHealthyProxyBoundary, resetAt].compactMap { $0 }.max()
            lastProxyTuples = apiTuples
            lastProxySources = apiSources
            lastTunEnabled = tunEnabled
            proxyWasUnavailable = false
            pruneProxy(at: at)
        } else {
            proxyWasUnavailable = true
            diagnostics.append("proxy-unavailable: retained baselines; core wire bytes are excluded")
            if tunEnabled {
                diagnostics.append("tun-api-unavailable: physical socket deltas suppressed to avoid recovery double count")
            }
        }

        if let sockets {
            let identityCounts = Dictionary(grouping: sockets, by: socketIdentity).mapValues(\.count)
            let keyCounts = Dictionary(grouping: sockets, by: socketBaselineKey).mapValues(\.count)
            let udpSources = Dictionary(grouping: sockets.filter {
                $0.network == "udp" && isDirectCandidate($0, corePIDs: corePIDs)
            }) { Source(network: $0.network, endpoint: $0.local) }
            var ambiguousIdentities = ambiguousSocketIdentities
            ambiguousIdentities.formUnion(identityCounts.filter { $0.value > 1 }.map(\.key))
            for socket in sockets where socket.isUnconnectedUDP {
                let source = Source(network: socket.network, endpoint: socket.local)
                if (udpSources[source]?.count ?? 0) > 1 { ambiguousIdentities.insert(socketIdentity(socket)) }
            }
            // 只有可信快照中的明确缺席才结束 incarnation；nil 或 parser 过滤的歧义行不能清 sticky。
            let presentIdentities = Set(identityCounts.keys).union(ambiguousSocketIdentities)
            socketBaselines = socketBaselines.filter { entry in
                entry.value.socketIdentity.map { presentIdentities.contains($0) } ?? false
            }
            for key in Array(socketBaselines.keys) {
                if let identity = socketBaselines[key]?.socketIdentity, ambiguousIdentities.contains(identity) {
                    // 歧义区间不回放；仍然见到的 identity 不因歧义持续超过 TTL 而丢失覆盖。
                    socketBaselines[key]?.needsRebaseline = true
                    socketBaselines[key]?.at = at
                }
            }
            if !ambiguousSocketIdentities.isEmpty {
                diagnostics.append("ambiguous-socket-identity: duplicate rows excluded")
            }
            var ambiguousSource = false
            for socket in sockets.sorted(by: { socketBaselineKey($0) < socketBaselineKey($1) }) {
                let key = socketBaselineKey(socket)
                guard identityCounts[socketIdentity(socket)] == 1, keyCounts[key] == 1,
                      !ambiguousSocketIdentities.contains(socketIdentity(socket)) else {
                    diagnostics.append("ambiguous-socket-identity: duplicate rows excluded")
                    continue
                }
                guard isDirectCandidate(socket, corePIDs: corePIDs) else { continue }
                let tuple = Tuple(network: socket.network, source: socket.local, destination: socket.remote)
                let source = Source(network: socket.network, endpoint: socket.local)
                if socket.isUnconnectedUDP, (udpSources[source]?.count ?? 0) > 1 {
                    // 通配 UDP 可能与同源 connected 行重叠；既不求和，也不清旧覆盖或回放歧义区间。
                    diagnostics.append("ambiguous-udp-source: unconnected UDP socket excluded")
                    continue
                }
                let exactMatch = apiTuples.contains(tuple)
                // A wildcard UDP peer cannot match an API destination. Prefer its
                // same-source API payload even for explicit (non-TUN) UDP proxies.
                let sourceMatch = (tunEnabled || socket.isUnconnectedUDP) && apiSources.contains(source)
                if sourceMatch && !exactMatch {
                    if tunEnabled { ambiguousSource = true }
                    else { diagnostics.append("udp-source-covered: API preferred over unconnected UDP") }
                }
                let suppress = exactMatch || sourceMatch || (tunEnabled && proxy == nil)
                if var baseline = socketBaselines[key], baseline.tuple == tuple {
                    // Coverage is sticky for this socket incarnation: an API flow
                    // may disappear and later reappear with its cumulative counter.
                    baseline.coveredByAPI = baseline.coveredByAPI || exactMatch || sourceMatch
                    if !suppress && !baseline.coveredByAPI && !baseline.needsRebaseline {
                        appendDelta(rx: socket.rx, tx: socket.tx, baseline: baseline,
                                    at: at, viaProxy: false, into: &result)
                    }
                    baseline.rx = socket.rx; baseline.tx = socket.tx; baseline.at = at
                    baseline.needsRebaseline = false
                    socketBaselines[key] = baseline
                } else {
                    socketBaselines[key] = Baseline(rx: socket.rx, tx: socket.tx, at: at, owner: socket.owner,
                                                   tuple: tuple, coveredByAPI: exactMatch || sourceMatch,
                                                   socketIdentity: socketIdentity(socket))
                }
            }
            if ambiguousSource {
                diagnostics.append("tun-source-ambiguous: API preferred; same-source physical sockets excluded")
            }
            pruneSockets(at: at)
        } else {
            diagnostics.append("nettop-unavailable: retained socket baselines")
        }
        diagnostics = Array(Set(diagnostics)).sorted()
        return result
    }

    private func appendDelta(rx: UInt64, tx: UInt64, baseline: Baseline, at: Date,
                             viaProxy: Bool, into result: inout [TrafficDelta]) {
        let dt = at.timeIntervalSince(baseline.at)
        guard dt > 0, rx >= baseline.rx, tx >= baseline.tx else { return }
        let received = rx - baseline.rx
        let sent = tx - baseline.tx
        guard received > 0 || sent > 0 else { return }
        result.append(TrafficDelta(owner: baseline.owner ?? .unknown, rx: received, tx: sent,
                                   rxRate: Double(received) / dt, txRate: Double(sent) / dt, viaProxy: viaProxy))
    }

    private func socketIdentity(_ socket: SocketTraffic) -> String {
        SocketTraffic.identityKey(owner: socket.owner, network: socket.network, local: socket.local,
                                  remote: socket.remote, interface: socket.interface)
    }

    private func socketBaselineKey(_ socket: SocketTraffic) -> String {
        keyParts([socket.key, socketIdentity(socket)])
    }

    private func isDirectCandidate(_ socket: SocketTraffic, corePIDs: Set<Int>) -> Bool {
        if let pid = socket.owner.pid, corePIDs.contains(pid) { return false }
        // Only a concrete local endpoint on a physical interface qualifies.
        // The peer exception is UDP-only; TCP listeners, unbound UDP and core
        // sockets remain excluded, as do loopback and virtual interfaces.
        guard ["tcp", "udp"].contains(socket.network), socket.interface.hasPrefix("en"),
              !socket.interface.dropFirst(2).isEmpty,
              socket.interface.dropFirst(2).utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !socket.local.isLoopback, !socket.remote.isLoopback,
              !socket.local.isUnspecified,
              socket.local.address != socket.remote.address,
              (socket.isUnconnectedUDP || (!socket.remote.isUnspecified && (1...65535).contains(socket.remote.port))),
              (1...65535).contains(socket.local.port) else { return false }
        return true
    }

    private mutating func pruneSockets(at: Date) {
        socketBaselines = socketBaselines.filter { at.timeIntervalSince($0.value.at) <= Self.retention }
        if socketBaselines.count > Self.capacity {
            let ordered = socketBaselines.keys.sorted {
                let lhs = socketBaselines[$0]!.at, rhs = socketBaselines[$1]!.at
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            for key in ordered.prefix(socketBaselines.count - Self.capacity) { socketBaselines.removeValue(forKey: key) }
            diagnostics.append("socket-retention-limit: old baselines evicted; unseen old flows only rebaseline")
        }
    }

    private mutating func pruneProxy(at: Date) {
        // Process recovery before pruning, so an outage itself never expires an
        // observed survivor. Closed/absent flows leave bounded tombstones.
        proxyBaselines = proxyBaselines.filter { at.timeIntervalSince($0.value.at) <= Self.retention }
        if proxyBaselines.count > Self.capacity {
            let ordered = proxyBaselines.keys.sorted {
                let lhs = proxyBaselines[$0]!.at, rhs = proxyBaselines[$1]!.at
                return lhs == rhs ? $0.sortKey < $1.sortKey : lhs < rhs
            }
            for key in ordered.prefix(proxyBaselines.count - Self.capacity) { proxyBaselines.removeValue(forKey: key) }
            diagnostics.append("proxy-retention-limit: old tombstones evicted; unseen old flows only rebaseline")
        }
    }
}

// Deterministic and standalone: swiftc TrafficAttribution.swift /tmp/.../main.swift
// with `AttributionSelfTests.run()` in that temporary runner. No network or files.
enum AttributionSelfTests {
    static func run() {
        let app = TrafficOwner(pid: 101, incarnation: "101@1", name: "Browser", path: "/Applications/Browser.app")
        let other = TrafficOwner(pid: 102, incarnation: "102@1", name: "Other")
        let core = TrafficOwner(pid: 900, incarnation: "900@1", name: "Core")
        let local = TrafficEndpoint(address: "192.0.2.10", port: 50000)
        let remote = TrafficEndpoint(address: "203.0.113.20", port: 443)
        func time(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), "Attribution self-test failed: \(message)")
        }
        func amount(_ deltas: [TrafficDelta]) -> UInt64 { deltas.reduce(0) { $0 + $1.rx } }
        func socket(_ count: UInt64, key: String = "socket", owner: TrafficOwner? = nil,
                    source: TrafficEndpoint? = nil, destination: TrafficEndpoint? = nil,
                    interface: String = "en0", network: String = "tcp") -> SocketTraffic {
            SocketTraffic(key: key, owner: owner ?? app, network: network, local: source ?? local,
                          remote: destination ?? remote, interface: interface, rx: count, tx: count / 2)
        }
        func flow(_ count: UInt64, id: String = "flow", start: Double? = 0,
                  owner: TrafficOwner? = nil, source: TrafficEndpoint? = nil,
                  destination: TrafficEndpoint? = nil, type: String = "Tun", via: Bool = true) -> ProxyTraffic {
            ProxyTraffic(id: id, start: start.map(time), network: "tcp", type: type, source: source ?? local,
                         destination: destination ?? remote, owner: owner, rx: count, tx: count / 2, viaProxy: via)
        }
        func snapshot(_ flows: [ProxyTraffic], epoch: String = "core-1", tun: Bool = false,
                      acquired: Double? = nil) -> ProxyTrafficSnapshot {
            ProxyTrafficSnapshot(epoch: epoch, flows: flows, tunEnabled: tun,
                                 acquisitionStartedAt: acquired.map(time))
        }

        check(TrafficEndpoint.parseNettop("1.2.3.4:443") == TrafficEndpoint(address: "1.2.3.4", port: 443), "IPv4 endpoint")
        check(TrafficEndpoint.parseNettop("fe80::A%utun5.1025") == TrafficEndpoint(address: "[fe80::a%utun5]", port: 1025), "scoped IPv6")
        check(TrafficEndpoint.parseNettop("[2001:0DB8::1]:443") == TrafficEndpoint(address: "2001:db8::1", port: 443), "bracketed IPv6")
        check(TrafficEndpoint.parseNettop("::ffff:192.0.2.10.50000") == local, "mapped IPv6")
        check(TrafficEndpoint(address: "::ffff:127.1.2.3", port: 1).isLoopback, "mapped loopback")
        check(TrafficEndpoint(address: "::1%lo0", port: 1).isLoopback, "scoped loopback")
        check(TrafficEndpoint(address: "::", port: 0).isUnspecified, "IPv6 unspecified")
        check(TrafficEndpoint(address: "fe80::1%en0", port: 1) != TrafficEndpoint(address: "fe80::1%en1", port: 1), "scope retained")
        for malformed in ["", "garbage:80", "1.2.3.4:-1", "1.2.3.4:65536", "[::1]443", "fe80::1:443", "[fe80::1%]:80", "1.2.3.4:3x"] {
            check(TrafficEndpoint.parseNettop(malformed) == nil, "reject malformed endpoint \(malformed)")
        }
        let csv = """
        ,interface,state,bytes_in,bytes_out,
        apsd.370,,,79902,515040,
        tcp4 192.168.43.72:61521<->17.57.145.151:5223,en0,Established,79902,515040,
        \"quoted,name.371\",,,2134,973,
        tcp6 fe80::1%utun5.1025<->fe80::2%utun5.1027,utun5,Established,2134,973,
        """
        let parsed = SocketTraffic.parseCSV(csv) { TrafficOwner(pid: $0, incarnation: "\($0)@a", name: $1) }
        check(parsed?.count == 2 && parsed?[0].rx == 79902 && parsed?[1].network == "tcp", "CSV row counters, not process totals")
        check(parsed?[1].owner.name == "quoted,name", "CSV quoted process")
        check(parsed?[1].local.address == "fe80::1%utun5", "CSV scoped endpoint")
        check(SocketTraffic.parseCSV(",interface,state,bytes_in,bytes_out,\n", owner: { _, _ in app })?.isEmpty == true, "healthy empty CSV")
        let idleCSV = """
        ,interface,state,bytes_in,bytes_out,
        launchd.1,,,0,0,
        tcp4 *:5900<->*:*,,Listen,,,
        tcp6 *.5900<->*.*,,Listen,,,
        udp4 *:*<->*:*,,,,,
        udp4 *:88<->*:*,,,0,0,
        udp6 *.88<->*.*,,,0,0,
        tcp4 192.0.2.10:50003<->203.0.113.20:443,en0,Closed,,,
        tcp4 192.0.2.10:50000<->203.0.113.20:443,en0,Established,10,5,
        apsd.370,,,5289,13570,
        tcp4 192.168.43.72:61521<->17.57.145.151:5223,en0,Established,5289,13570,
        """
        let idleParsed = SocketTraffic.parseCSV(idleCSV) { TrafficOwner(pid: $0, incarnation: "\($0)@a", name: $1) }
        check(idleParsed?.count == 2 && idleParsed?[0].owner.pid == 1 && idleParsed?[1].owner.pid == 370, "real nettop wildcard/empty listener rows preserve owner and active counters")
        let interfaceGroupedCSV = """
        ,interface,state,bytes_in,bytes_out,
        proxy-client.42,en0,,100,50,
        proxy-client.42,utun4,,120,60,
        tcp4 192.0.2.10:50000<->127.0.0.1:7897,en0,Established,100,50,
        """
        let interfaceGrouped = SocketTraffic.parseCSV(interfaceGroupedCSV) { TrafficOwner(pid: $0, incarnation: "\($0)@a", name: $1) }
        check(interfaceGrouped?.count == 1 && interfaceGrouped?.first?.owner.pid == 42
              && interfaceGrouped?.first?.rx == 100, "per-interface process summary rows provide owner context but never add their aggregate counters")
        let activeMissing = idleCSV + "\ntcp4 192.0.2.10:50002<->203.0.113.20:443,en0,Established,,,"
        let activeMalformed = idleCSV + "\ntcp4 192.0.2.10:50002<->203.0.113.20:443,en0,Established,nope,5,"
        check(SocketTraffic.parseCSV(activeMissing, owner: { _, _ in app }) == nil, "established TCP empty counters remain malformed")
        check(SocketTraffic.parseCSV(activeMalformed, owner: { _, _ in app }) == nil, "active malformed numeric counters remain failure")
        for malformed in ["", "oops", ",interface,state,bytes_in,bytes_out,\nfoo.1,,,x,1,", ",interface,state,bytes_in,bytes_out,\ntcp4 1.2.3.4:1<->2.3.4.5:2,en0,Established,1,1,", csv + "\n\"unterminated"] {
            check(SocketTraffic.parseCSV(malformed, owner: { _, _ in app }) == nil, "malformed CSV is failure")
        }
        let oneRow = ",interface,state,bytes_in,bytes_out,\np.1,,,10,5,\ntcp4 192.0.2.10:50000<->203.0.113.20:443,en0,Established,10,5,\n"
        let duplicateCSV = oneRow + "tcp4 192.0.2.10:50000<->203.0.113.20:443,en0,Established,20,6,\n"
        check(SocketTraffic.parseCSV(duplicateCSV, owner: { _, _ in app })?.isEmpty == true, "duplicate CSV rows conservatively omitted")
        let changedOwner = SocketTraffic.parseCSV(oneRow, owner: { _, _ in other })!
        check(parsed?[0].key != changedOwner[0].key, "CSV key includes incarnation")

        var ledger = AttributionLedger()
        check(ledger.sample(sockets: [socket(1000)], proxy: snapshot([flow(2000, owner: app)]), corePIDs: [], at: time(10)).isEmpty, "first sample has no historical bytes")
        // The matching API tuple excludes even an en0 socket, independent of PID.
        let second = ledger.sample(sockets: [socket(1100)], proxy: snapshot([flow(2200, owner: app)]), corePIDs: [], at: time(12))
        check(amount(second) == 200 && second.first?.rxRate == 100, "per-flow delta and exact dedup")
        let newAndOld = ledger.sample(sockets: [], proxy: snapshot([flow(100, id: "new", start: 13, owner: app), flow(9000, id: "old", start: 1)]), corePIDs: [], at: time(14))
        check(amount(newAndOld) == 100 && newAndOld.first?.rxRate == 100, "only provably new API connection counts from zero")
        let epoch = ledger.sample(sockets: [], proxy: snapshot([flow(50000, id: "new", start: 15)], epoch: "core-2"), corePIDs: [], at: time(16))
        check(epoch.isEmpty, "core epoch rebaseline")
        check(ledger.sample(sockets: [], proxy: snapshot([flow(1, id: "new", start: 15)], epoch: "core-2"), corePIDs: [], at: time(17)).isEmpty, "counter rollback rebaseline")
        check(amount(ledger.sample(sockets: [], proxy: snapshot([flow(11, id: "new", start: 15)], epoch: "core-2"), corePIDs: [], at: time(18))) == 10, "counter after rollback")
        ledger.reset(at: time(20))
        let reset = ledger.sample(sockets: [socket(9000)], proxy: snapshot([flow(9000, start: 0), flow(20, id: "after-reset", start: 21)]), corePIDs: [], at: time(22))
        check(amount(reset) == 20, "reset ignores old history but permits provable post-reset start")
        check(ledger.sample(sockets: [], proxy: snapshot([flow(50, id: "future", start: 99)]), corePIDs: [], at: time(23)).isEmpty, "future start cannot count from zero")

        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [], proxy: snapshot([flow(100, owner: app)]), corePIDs: [], at: time(1))
        _ = ledger.sample(sockets: [], proxy: snapshot([]), corePIDs: [], at: time(2))
        let reappeared = ledger.sample(sockets: [], proxy: snapshot([flow(160, owner: app)]), corePIDs: [], at: time(4))
        check(amount(reappeared) == 60 && reappeared.first?.rxRate == 20, "missing and reappearing id keeps tombstone and actual interval")
        _ = ledger.sample(sockets: nil, proxy: nil, corePIDs: [], at: time(5))
        _ = ledger.sample(sockets: [socket(9999, owner: core)], proxy: nil, corePIDs: [900], at: time(7))
        let recovered = ledger.sample(sockets: [], proxy: snapshot([flow(260, owner: app)]), corePIDs: [900], at: time(9))
        check(amount(recovered) == 100 && recovered.first?.rxRate == 20, "API failure recovery uses five-second interval, no wire fallback")
        let reusedStart = ledger.sample(sockets: [], proxy: snapshot([flow(9999, start: -1)]), corePIDs: [], at: time(10))
        check(reusedStart.isEmpty, "same id changed start is distinct old baseline")

        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [], proxy: snapshot([flow(10)]), corePIDs: [], at: time(1))
        let unknown = ledger.sample(sockets: [], proxy: snapshot([flow(20, owner: app)]), corePIDs: [], at: time(2))
        check(unknown.first?.owner == .unknown, "unknown interval remains unknown on owner discovery")
        let known = ledger.sample(sockets: [], proxy: snapshot([flow(30, owner: other)]), corePIDs: [], at: time(3))
        check(known.first?.owner == app, "ownership upgraded for future and then frozen")
        let changedTuple = TrafficEndpoint(address: "203.0.113.21", port: 443)
        check(ledger.sample(sockets: [], proxy: snapshot([flow(900, owner: other, destination: changedTuple)]), corePIDs: [], at: time(4)).isEmpty, "changed API tuple rebaselines")
        let afterTuple = ledger.sample(sockets: [], proxy: snapshot([flow(910, owner: other, destination: changedTuple)]), corePIDs: [], at: time(5))
        check(afterTuple.first?.owner == app && amount(afterTuple) == 10, "tuple metadata change cannot change established owner")
        ledger = AttributionLedger()
        let pathOwner = TrafficOwner(incarnation: "path-owner", name: "Path app", path: "/Applications/Path.app")
        _ = ledger.sample(sockets: [], proxy: snapshot([flow(10)]), corePIDs: [], at: time(1))
        let beforePath = ledger.sample(sockets: [], proxy: snapshot([flow(20, owner: pathOwner)]), corePIDs: [], at: time(2))
        check(beforePath.first?.owner == .unknown, "path owner upgrade cannot rewrite prior interval")
        let afterPath = ledger.sample(sockets: [], proxy: snapshot([flow(30, owner: app)]), corePIDs: [], at: time(3))
        check(afterPath.first?.owner == pathOwner, "validated path-only owner is established even without PID")

        let loop = TrafficEndpoint(address: "127.0.0.1", port: 7890)
        let client = TrafficEndpoint(address: "127.0.0.1", port: 51000)
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [socket(100, source: client, destination: loop, interface: "lo0"), socket(500, key: "core", owner: core)],
                          proxy: snapshot([flow(100, owner: app, source: client, type: "HTTPS", via: false)]), corePIDs: [900], at: time(1))
        let systemDirect = ledger.sample(sockets: [socket(200, source: client, destination: loop, interface: "lo0"), socket(900, key: "core", owner: core)],
                                         proxy: snapshot([flow(140, owner: app, source: client, type: "HTTPS", via: false)]), corePIDs: [900], at: time(2))
        check(amount(systemDirect) == 40 && systemDirect.first?.viaProxy == false, "system proxy DIRECT counts only API payload")
        check(ledger.sample(sockets: [socket(300, source: client, destination: loop, interface: "en0"), socket(1500, key: "core", owner: core)], proxy: nil, corePIDs: [900], at: time(3)).isEmpty, "no system proxy loopback fallback")

        ledger = AttributionLedger()
        let directLocal = TrafficEndpoint(address: "192.0.2.10", port: 50001)
        let fake = TrafficEndpoint(address: "198.18.0.1", port: 443)
        _ = ledger.sample(sockets: [socket(100), socket(100, key: "direct", source: directLocal), socket(100, key: "utun", interface: "utun5")],
                          proxy: snapshot([flow(100, owner: app, via: false)], tun: true), corePIDs: [], at: time(1))
        let mixed = ledger.sample(sockets: [socket(200), socket(130, key: "direct", source: directLocal), socket(500, key: "utun", interface: "utun5")],
                                  proxy: snapshot([flow(160, owner: app, via: false)], tun: true), corePIDs: [], at: time(2))
        check(amount(mixed) == 90 && mixed.allSatisfy({ $0.owner == app && !$0.viaProxy }), "TUN DIRECT exact dedup plus different direct flow same PID")
        let uncertain = ledger.sample(sockets: [socket(300, destination: fake), socket(160, key: "direct", source: directLocal)],
                                      proxy: snapshot([flow(200, owner: app)], tun: true), corePIDs: [], at: time(3))
        check(amount(uncertain) == 70 && ledger.diagnostics.contains(where: { $0.hasPrefix("tun-source-ambiguous") }), "fake-IP source mismatch prefers API and reports status")
        let tunOutage = ledger.sample(sockets: [socket(220, key: "direct", source: directLocal)], proxy: nil, corePIDs: [], at: time(4))
        check(tunOutage.isEmpty && ledger.diagnostics.contains(where: { $0.hasPrefix("tun-api-unavailable") }), "uncertain TUN outage does not add physical bytes")
        let tunRecovery = ledger.sample(sockets: [socket(250, key: "direct", source: directLocal)], proxy: snapshot([flow(260, owner: app)], tun: true), corePIDs: [], at: time(6))
        check(amount(tunRecovery) == 90 && tunRecovery.contains(where: { $0.rx == 60 && $0.rxRate == 20 }), "TUN recovery averages API gap; direct socket only counts latest interval")

        ledger = AttributionLedger()
        let excluded = [socket(100, key: "ipc", source: client, destination: loop), socket(100, key: "host-ipc", destination: TrafficEndpoint(address: local.address, port: 7000)), socket(100, key: "unbound", source: TrafficEndpoint(address: "0.0.0.0", port: 50001)), socket(100, key: "awdl", interface: "awdl0"), socket(100, key: "lo", interface: "lo0"), socket(100, key: "listen", destination: TrafficEndpoint(address: "*", port: 0)), socket(100, key: "utun", interface: "utun9")]
        _ = ledger.sample(sockets: excluded, proxy: snapshot([]), corePIDs: [], at: time(1))
        let excludedMore = excluded.map { SocketTraffic(key: $0.key, owner: $0.owner, network: $0.network, local: $0.local, remote: $0.remote, interface: $0.interface, rx: 999, tx: 999) }
        check(ledger.sample(sockets: excludedMore, proxy: snapshot([]), corePIDs: [], at: time(2)).isEmpty, "IPC and nonphysical interfaces excluded")
        let reusedPID = TrafficOwner(pid: 101, incarnation: "101@2", name: "New process")
        _ = ledger.sample(sockets: [socket(1000)], proxy: snapshot([]), corePIDs: [], at: time(3))
        check(ledger.sample(sockets: [socket(9000, owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(4)).isEmpty, "PID reuse cannot inherit baseline even if caller key reused")
        check(amount(ledger.sample(sockets: [socket(9030, owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(5))) == 30, "new incarnation counts future bytes")
        _ = ledger.sample(sockets: nil, proxy: snapshot([]), corePIDs: [], at: time(6))
        let socketRecovery = ledger.sample(sockets: [socket(9120, owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(8))
        check(amount(socketRecovery) == 90 && socketRecovery.first?.rxRate == 30, "nettop failure preserves per-flow interval")
        check(ledger.sample(sockets: [socket(1, owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(9)).isEmpty, "socket counter rollback")
        check(ledger.sample(sockets: [socket(2, owner: reusedPID), socket(3, key: "duplicate", owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(10)).isEmpty, "different keys cannot double-count same socket tuple")

        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [socket(10, network: "udp")], proxy: snapshot([flow(10, owner: app)], tun: true), corePIDs: [], at: time(1))
        let differentNetwork = ledger.sample(sockets: [socket(20, network: "udp")], proxy: snapshot([flow(30, owner: app)], tun: true), corePIDs: [], at: time(2))
        check(amount(differentNetwork) == 30, "TUN tuple includes network; unrelated UDP direct is not excluded")
        check(ledger.sample(sockets: [], proxy: snapshot([flow(40), flow(50)]), corePIDs: [], at: time(3)).isEmpty, "duplicate API identities cannot overwrite or double count")
        _ = ledger.sample(sockets: nil, proxy: nil, corePIDs: [], at: time(100000))
        let longRecovery = ledger.sample(sockets: [], proxy: snapshot([flow(130)]), corePIDs: [], at: time(100002))
        check(amount(longRecovery) == 100 && abs((longRecovery.first?.rxRate ?? 0) - 0.001) < 0.0000001, "surviving API baseline is retained even through an outage beyond tombstone TTL")
        _ = ledger.sample(sockets: [], proxy: snapshot([]), corePIDs: [], at: time(200003))
        check(ledger.sample(sockets: [], proxy: snapshot([flow(10000)]), corePIDs: [], at: time(200004)).isEmpty, "expired old tombstone never replays old counters")

        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [socket(10)], proxy: snapshot([]), corePIDs: [], at: time(1))
        let preTun = ledger.sample(sockets: [socket(20)], proxy: nil, corePIDs: [], at: time(2))
        check(amount(preTun) == 10, "known non-TUN API outage preserves unrelated physical direct accounting")
        let modeChanged = ledger.sample(sockets: [socket(30)], proxy: snapshot([flow(500, start: 1.5, owner: app)], tun: true), corePIDs: [], at: time(3))
        check(modeChanged.isEmpty && ledger.diagnostics.contains(where: { $0.hasPrefix("tun-mode-changed-during-outage") }), "TUN enabled invisibly during outage cannot replay already-counted physical history")
        // UU Remote uses sendto/recvfrom: a live peer can legitimately be *:*.
        let wildcard = TrafficEndpoint(address: "*", port: 0)
        func udp(_ count: UInt64, owner: TrafficOwner? = nil, source: TrafficEndpoint? = nil,
                 interface: String = "en0", destination: TrafficEndpoint? = nil) -> SocketTraffic {
            socket(count, owner: owner, source: source, destination: destination ?? wildcard,
                   interface: interface, network: "udp")
        }
        let udpCSV = ",interface,state,bytes_in,bytes_out,\nUURemote.101,,,999999,999999,\nudp4 192.0.2.10:50000<->*:*,en0,,1000,500,\nudp6 [2001:db8::10]:50001<->*.*,en0,,2000,1000,\n"
        let udpParsed = SocketTraffic.parseCSV(udpCSV) { _, _ in app }
        check(udpParsed?.count == 2 && udpParsed?.allSatisfy(\.isUnconnectedUDP) == true, "numeric IPv4/IPv6 unconnected UDP retained, process totals ignored")
        ledger = AttributionLedger()
        check(ledger.sample(sockets: udpParsed, proxy: snapshot([]), corePIDs: [], at: time(1)).isEmpty, "UDP first snapshot is baseline only")
        let udpMore = udpParsed!.map { SocketTraffic(key: $0.key, owner: $0.owner, network: $0.network,
            local: $0.local, remote: $0.remote, interface: $0.interface, rx: $0.rx + 180, tx: $0.tx + 90) }
        let udpDelta = ledger.sample(sockets: udpMore, proxy: snapshot([]), corePIDs: [], at: time(3))
        check(amount(udpDelta) == 360 && udpDelta.allSatisfy { $0.owner == app && $0.rxRate == 90 && $0.tx == 90 }, "physical unconnected UDP counts only per-socket future delta under its real owner")
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(100)], proxy: snapshot([]), corePIDs: [], at: time(3))
        check(ledger.sample(sockets: [udp(1)], proxy: snapshot([]), corePIDs: [], at: time(4)).isEmpty, "UDP rollback rebaselines")
        check(amount(ledger.sample(sockets: [udp(11)], proxy: snapshot([]), corePIDs: [], at: time(5))) == 10, "UDP resumes after rollback")
        ledger.reset(at: time(6))
        check(ledger.sample(sockets: [udp(9999)], proxy: snapshot([]), corePIDs: [], at: time(7)).isEmpty, "UDP reset cannot replay history")
        check(ledger.sample(sockets: [udp(10000, owner: reusedPID)], proxy: snapshot([]), corePIDs: [], at: time(8)).isEmpty, "UDP PID incarnation cannot inherit history")

        ledger = AttributionLedger()
        let unsafeUDP = [udp(100, source: client), udp(100, source: .init(address: "*", port: 50000)),
                         udp(100, source: .init(address: local.address, port: 0)), udp(100, interface: "lo0"),
                         udp(100, interface: "utun4"), udp(100, owner: core)]
        _ = ledger.sample(sockets: unsafeUDP, proxy: snapshot([]), corePIDs: [900], at: time(1))
        let unsafeMore = unsafeUDP.map { SocketTraffic(key: $0.key, owner: $0.owner, network: $0.network,
            local: $0.local, remote: $0.remote, interface: $0.interface, rx: 200, tx: 100) }
        check(ledger.sample(sockets: unsafeMore, proxy: snapshot([]), corePIDs: [900], at: time(2)).isEmpty, "UDP relaxation never admits wildcard local, IPC, virtual interfaces or core bytes")

        func udpAPI(_ count: UInt64, tun: Bool) -> ProxyTrafficSnapshot {
            snapshot([ProxyTraffic(id: "udp-api", start: time(0), network: "udp", type: tun ? "Tun" : "Socks5",
                source: local, destination: remote, owner: app, rx: count, tx: count / 2, viaProxy: true)], tun: tun)
        }
        for tun in [false, true] {
            ledger = AttributionLedger()
            _ = ledger.sample(sockets: [udp(100)], proxy: udpAPI(100, tun: tun), corePIDs: [], at: time(1))
            let covered = ledger.sample(sockets: [udp(200)], proxy: udpAPI(160, tun: tun), corePIDs: [], at: time(2))
            check(amount(covered) == 60 && covered.allSatisfy(\.viaProxy), "UDP API source dedup applies to TUN and explicit proxies")
            check(ledger.sample(sockets: [udp(300)], proxy: nil, corePIDs: [], at: time(3)).isEmpty, "UDP API outage cannot add covered raw counters")
            check(ledger.sample(sockets: [udp(400)], proxy: snapshot([], tun: tun), corePIDs: [], at: time(4)).isEmpty, "UDP API coverage is sticky after flow disappears")
        }
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(10)], proxy: snapshot([flow(10, owner: app)]), corePIDs: [], at: time(1))
        check(amount(ledger.sample(sockets: [udp(40)], proxy: snapshot([flow(30, owner: app)]), corePIDs: [], at: time(2))) == 50, "TCP API source never suppresses independent UDP")

        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(10)], proxy: snapshot([]), corePIDs: [], at: time(1))
        let sibling = ledger.sample(sockets: [udp(100), udp(10, destination: remote)], proxy: snapshot([]), corePIDs: [], at: time(2))
        check(sibling.isEmpty && ledger.diagnostics.contains(where: { $0.hasPrefix("ambiguous-udp-source") }), "wildcard/connected same-source ambiguity cannot double count")
        check(ledger.sample(sockets: [udp(110)], proxy: snapshot([]), corePIDs: [], at: time(3)).isEmpty, "UDP ambiguity gap is not replayed")
        check(amount(ledger.sample(sockets: [udp(120)], proxy: snapshot([]), corePIDs: [], at: time(4))) == 10, "UDP counts again after safe rebaseline")
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(10), udp(20, owner: other)], proxy: snapshot([]), corePIDs: [], at: time(1))
        check(ledger.sample(sockets: [udp(30), udp(40, owner: other)], proxy: snapshot([]), corePIDs: [], at: time(2)).isEmpty, "shared UDP source across owners is not guessed")
        // 原失效序列：明确消失后的同 tuple 是新生命周期，不能永久继承旧 API 覆盖。
        for tun in [false, true] {
            ledger = AttributionLedger()
            _ = ledger.sample(sockets: [udp(100)], proxy: udpAPI(100, tun: tun), corePIDs: [], at: time(1))
            _ = ledger.sample(sockets: [], proxy: snapshot([], tun: tun), corePIDs: [], at: time(2))
            check(ledger.sample(sockets: [udp(1)], proxy: snapshot([], tun: tun), corePIDs: [], at: time(3)).isEmpty, "reused UDP tuple starts a fresh baseline after confirmed absence")
            for (at, count) in [(4.0, UInt64(101)), (5.0, UInt64(201))] {
                let direct = ledger.sample(sockets: [udp(count)], proxy: snapshot([], tun: tun), corePIDs: [], at: time(at))
                check(amount(direct) == 100 && direct.first?.tx == 50 && direct.first?.viaProxy == false, "reused UDP tuple counts 100 each round instead of permanent zero")
            }
            // nil 不是空快照；API 空、失败、计数回退也都不能证明旧 socket 已消失。
            ledger = AttributionLedger()
            _ = ledger.sample(sockets: [udp(100)], proxy: udpAPI(100, tun: tun), corePIDs: [], at: time(1))
            _ = ledger.sample(sockets: nil, proxy: snapshot([], tun: tun), corePIDs: [], at: time(2))
            check(ledger.sample(sockets: [udp(1)], proxy: nil, corePIDs: [], at: time(3)).isEmpty, "unknown socket absence preserves sticky API coverage through rollback")
            check(ledger.sample(sockets: [udp(101)], proxy: snapshot([], tun: tun), corePIDs: [], at: time(4)).isEmpty, "temporary empty API never replays an old covered socket")
            check(amount(ledger.sample(sockets: [udp(201)], proxy: udpAPI(160, tun: tun), corePIDs: [], at: time(5))) == 60, "API recovery only adds the retained API delta")
        }

        func udpFrame(_ count: UInt64, duplicate: Bool = false) -> SocketTrafficSnapshot {
            let row = "udp4 192.0.2.10:50000<->*:*,en0,,\(count),\(count / 2),\n"
            let text = ",interface,state,bytes_in,bytes_out,\np.101,,,9999,9999,\n" + row + (duplicate ? row : "")
            return SocketTraffic.parseSnapshotCSV(text, owner: { _, _ in app })!
        }
        func frameSample(_ frame: SocketTrafficSnapshot, proxy: ProxyTrafficSnapshot?, at: Double) -> [TrafficDelta] {
            ledger.sample(sockets: frame.sockets, proxy: proxy, corePIDs: [], at: time(at),
                          ambiguousSocketIdentities: frame.ambiguousIdentities)
        }
        let ambiguousFrame = udpFrame(200, duplicate: true)
        check(ambiguousFrame.sockets.isEmpty && ambiguousFrame.ambiguousIdentities.count == 1, "parser retains duplicate identity evidence even when all rows are filtered")
        ledger = AttributionLedger()
        _ = frameSample(udpFrame(100), proxy: udpAPI(100, tun: false), at: 1)
        _ = frameSample(ambiguousFrame, proxy: snapshot([]), at: 2)
        check(frameSample(udpFrame(300), proxy: snapshot([]), at: 3).isEmpty, "filtered duplicates cannot clear sticky coverage")
        check(frameSample(udpFrame(400), proxy: snapshot([]), at: 4).isEmpty, "sticky coverage survives duplicate recovery")
        check(amount(frameSample(udpFrame(500), proxy: udpAPI(160, tun: false), at: 5)) == 60, "duplicate recovery never double counts retained API bytes")
        _ = ledger.sample(sockets: [], proxy: snapshot([]), corePIDs: [], at: time(6))
        _ = frameSample(udpFrame(1), proxy: snapshot([]), at: 7)
        check(amount(frameSample(udpFrame(101), proxy: snapshot([]), at: 8)) == 100, "later trusted absence can release formerly ambiguous sticky coverage")
        ledger = AttributionLedger()
        _ = frameSample(udpFrame(100), proxy: snapshot([]), at: 1)
        _ = frameSample(ambiguousFrame, proxy: snapshot([]), at: 2)
        check(frameSample(udpFrame(300), proxy: snapshot([]), at: 3).isEmpty, "direct socket does not replay duplicate ambiguity interval")
        check(amount(frameSample(udpFrame(400), proxy: snapshot([]), at: 4)) == 100, "direct socket resumes after duplicate rebaseline")
        ledger = AttributionLedger()
        _ = frameSample(udpFrame(100), proxy: udpAPI(100, tun: false), at: 1)
        _ = frameSample(ambiguousFrame, proxy: snapshot([]), at: 100002)
        _ = frameSample(udpFrame(300), proxy: snapshot([]), at: 100003)
        check(frameSample(udpFrame(400), proxy: snapshot([]), at: 100004).isEmpty, "observed ambiguous identity retains sticky coverage even beyond tombstone TTL")
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(100)], proxy: udpAPI(100, tun: false), corePIDs: [], at: time(1))
        _ = ledger.sample(sockets: [udp(200), udp(201)], proxy: snapshot([]), corePIDs: [], at: time(2))
        _ = ledger.sample(sockets: [udp(300)], proxy: snapshot([]), corePIDs: [], at: time(3))
        check(ledger.sample(sockets: [udp(400)], proxy: snapshot([]), corePIDs: [], at: time(4)).isEmpty, "caller-supplied duplicates preserve sticky coverage too")
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [udp(100)], proxy: udpAPI(100, tun: false), corePIDs: [], at: time(1))
        _ = ledger.sample(sockets: [udp(200), udp(200, destination: remote)], proxy: snapshot([]), corePIDs: [], at: time(2))
        _ = ledger.sample(sockets: [udp(300)], proxy: snapshot([]), corePIDs: [], at: time(3))
        check(ledger.sample(sockets: [udp(400)], proxy: snapshot([]), corePIDs: [], at: time(4)).isEmpty, "same-source UDP ambiguity cannot discard established sticky coverage")

        // 本轮请求开始后出生、处理完成前未被响应捕获的 flow，下一轮仍可计首段。
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [], proxy: snapshot([flow(100, owner: app)], acquired: 8), corePIDs: [], at: time(10))
        let lateStart = ledger.sample(sockets: [], proxy: snapshot([
            flow(150, owner: app), flow(90, id: "unknown-start", start: nil),
            flow(100, id: "late-born", start: 9, owner: app), flow(9000, id: "old-unseen", start: 7)
        ], acquired: 11), corePIDs: [], at: time(12))
        check(amount(lateStart) == 150 && lateStart.contains { $0.rx == 50 } && lateStart.contains { $0.rx == 100 }, "previous request window counts new first bytes without replaying an established or older flow")
        let unknownStart = ledger.sample(sockets: [], proxy: snapshot([flow(100, id: "unknown-start", start: nil)], acquired: 12.5), corePIDs: [], at: time(13))
        check(amount(unknownStart) == 10, "unknown start is baseline-only then counts future delta")
        let missedWindow = ledger.sample(sockets: [], proxy: snapshot([flow(70, id: "next-window", start: 12.75)], acquired: 13.5), corePIDs: [], at: time(14))
        check(amount(missedWindow) == 70, "each successful request preserves its own missed-birth window")
        _ = ledger.sample(sockets: [], proxy: nil, corePIDs: [], at: time(15))
        check(amount(ledger.sample(sockets: [], proxy: snapshot([flow(80, id: "outage-born", start: 14.5)], acquired: 15.5), corePIDs: [], at: time(16))) == 80, "API failure retains the last successful acquisition boundary")
        ledger.reset(at: time(20))
        check(ledger.sample(sockets: [], proxy: snapshot([flow(9999, id: "pre-reset", start: 19)], acquired: 18), corePIDs: [], at: time(21)).isEmpty, "in-flight pre-reset request cannot replay old bytes")
        let resetWindow = ledger.sample(sockets: [], proxy: snapshot([flow(20, id: "reset-born", start: 20.5), flow(9999, id: "old-after-reset", start: 19.5)], acquired: 21.5), corePIDs: [], at: time(22))
        check(amount(resetWindow) == 20, "request start is clamped at reset without losing post-reset first segment")
        check(ledger.sample(sockets: [], proxy: snapshot([flow(9999, id: "epoch-born", start: 22.5)], epoch: "core-2", acquired: 22), corePIDs: [], at: time(23)).isEmpty, "request window never bypasses epoch rebaseline")
        ledger = AttributionLedger()
        _ = ledger.sample(sockets: [], proxy: snapshot([], acquired: 99), corePIDs: [], at: time(10))
        check(amount(ledger.sample(sockets: [], proxy: snapshot([flow(10, start: 10.5)], acquired: 11), corePIDs: [], at: time(12))) == 10, "invalid future acquisition time falls back to processing boundary")
        print("AttributionSelfTests: passed")
    }
}
