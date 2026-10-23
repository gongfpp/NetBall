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

    // nil means unusable output, not a successful empty snapshot. Process totals
    // are deliberately ignored. Duplicate indistinguishable rows are all omitted.
    static func parseCSV(_ text: String, owner: (Int, String) -> TrafficOwner) -> [SocketTraffic]? {
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
                      record[interfaceIndex].isEmpty, record[stateIndex].isEmpty,
                      csvCounter(rxText) != nil, csvCounter(txText) != nil else { return nil }
                currentOwner = owner(pid, String(label[..<dot]))
            }
        }
        guard header != nil else { return nil }
        return parsed.filter { frequencies[$0.key] == 1 }
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

    init(epoch: String, flows: [ProxyTraffic], tunEnabled: Bool) {
        self.epoch = epoch
        self.flows = flows
        self.tunEnabled = tunEnabled
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
    }

    private var socketBaselines: [String: Baseline] = [:]
    private var proxyBaselines: [ProxyKey: Baseline] = [:]
    private var proxyEpoch: String?
    private var lastHealthyProxyAt: Date?
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
        lastHealthyProxyAt = nil
        resetAt = at
        lastProxyTuples.removeAll()
        lastProxySources.removeAll()
        lastTunEnabled = false
        proxyWasUnavailable = false
        diagnostics = []
    }

    mutating func sample(sockets: [SocketTraffic]?, proxy: ProxyTrafficSnapshot?,
                         corePIDs: Set<Int>, at: Date) -> [TrafficDelta] {
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
            let newFlowBoundary = epochChanged || uncertainTunTransition ? nil : (lastHealthyProxyAt ?? resetAt)
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
            lastHealthyProxyAt = at
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
            // A duplicate row or caller-supplied key collision cannot silently
            // overwrite another connection's baseline.
            let identityCounts = Dictionary(grouping: sockets, by: socketIdentity).mapValues(\.count)
            let keyCounts = Dictionary(grouping: sockets, by: socketBaselineKey).mapValues(\.count)
            var ambiguousSource = false
            for socket in sockets.sorted(by: { socketBaselineKey($0) < socketBaselineKey($1) }) {
                let key = socketBaselineKey(socket)
                guard identityCounts[socketIdentity(socket)] == 1, keyCounts[key] == 1 else {
                    diagnostics.append("ambiguous-socket-identity: duplicate rows excluded")
                    continue
                }
                guard isDirectCandidate(socket, corePIDs: corePIDs) else { continue }
                let tuple = Tuple(network: socket.network, source: socket.local, destination: socket.remote)
                let source = Source(network: socket.network, endpoint: socket.local)
                let exactMatch = apiTuples.contains(tuple)
                let sourceMatch = tunEnabled && apiSources.contains(source)
                if sourceMatch && !exactMatch { ambiguousSource = true }
                let suppress = exactMatch || sourceMatch || (tunEnabled && proxy == nil)
                if var baseline = socketBaselines[key], baseline.tuple == tuple {
                    // Coverage is sticky for this socket incarnation: an API flow
                    // may disappear and later reappear with its cumulative counter.
                    baseline.coveredByAPI = baseline.coveredByAPI || exactMatch || sourceMatch
                    if !suppress && !baseline.coveredByAPI {
                        appendDelta(rx: socket.rx, tx: socket.tx, baseline: baseline,
                                    at: at, viaProxy: false, into: &result)
                    }
                    baseline.rx = socket.rx; baseline.tx = socket.tx; baseline.at = at
                    socketBaselines[key] = baseline
                } else {
                    socketBaselines[key] = Baseline(rx: socket.rx, tx: socket.tx, at: at, owner: socket.owner,
                                                   tuple: tuple, coveredByAPI: exactMatch || sourceMatch)
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
        guard ["tcp", "udp"].contains(socket.network), socket.interface.hasPrefix("en"),
              !socket.interface.dropFirst(2).isEmpty,
              socket.interface.dropFirst(2).utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !socket.local.isLoopback, !socket.remote.isLoopback,
              !socket.local.isUnspecified, !socket.remote.isUnspecified,
              socket.local.address != socket.remote.address,
              (1...65535).contains(socket.remote.port),
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
        func snapshot(_ flows: [ProxyTraffic], epoch: String = "core-1", tun: Bool = false) -> ProxyTrafficSnapshot {
            ProxyTrafficSnapshot(epoch: epoch, flows: flows, tunEnabled: tun)
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
        print("AttributionSelfTests: passed")
    }
}
