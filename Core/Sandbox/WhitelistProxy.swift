import Foundation
import Network

/// A loopback HTTP proxy that enforces the user's host whitelist.
///
/// Why this exists: the Seatbelt profile language on modern macOS cannot
/// express host-based network rules (the compiler accepts only `*` and
/// `localhost` as network hosts — verified). The sandbox therefore allows
/// loopback traffic only, and this proxy — running unsandboxed in the app —
/// is the sole internet egress for the agent. `pi` and everything it spawns
/// get `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` (plus `NODE_OPTIONS=--use-env-proxy`
/// for node's undici and `GIT_CONFIG_*` for git) pointing here, so every
/// outbound request is checked against the whitelist. Anything that ignores
/// the proxy env simply fails to connect (fail-closed).
///
/// Handles `CONNECT` (HTTPS) and absolute-URI requests (plain HTTP). Non-HTTP
/// traffic is rejected.
public actor WhitelistProxy {
    public enum ProxyError: Error {
        case notStarted
        case startFailed(String)
        case malformedRequest
        case requestTooLarge
        case upstreamFailed(String)
    }

    /// Host whitelist: exact match or any subdomain, case-insensitive.
    /// Entries are normalized to bare lowercase hosts (scheme, port and path
    /// stripped) so a pasted URL like `https://example.com/path` is enforced
    /// as `example.com` — regardless of whether it was cleaned at save time.
    public struct Whitelist: Sendable, Equatable {
        public var hosts: [String]

        public init(hosts: [String]) {
            self.hosts = hosts
                .map(SandboxSettings.normalizeHost)
                .filter { !$0.isEmpty }
        }

        public func allows(_ rawHost: String) -> Bool {
            let host = Self.normalizeHost(rawHost)
            guard !host.isEmpty else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        /// Lowercases and strips a `:port` suffix (or `[v6]:port` brackets).
        /// Bare IPv6 (multiple colons) is left intact.
        static func normalizeHost(_ host: String) -> String {
            var s = host.lowercased()
            if s.hasPrefix("[") {
                if let end = s.firstIndex(of: "]") {
                    s = String(s[s.index(after: s.startIndex)..<end])
                }
            } else if s.filter({ $0 == ":" }).count == 1, let colon = s.lastIndex(of: ":") {
                let after = s[s.index(after: colon)...]
                if !after.isEmpty && after.allSatisfy(\.isNumber) {
                    s = String(s[..<colon])
                }
            }
            return s
        }
    }

    private let whitelist: Whitelist
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var portContinuations: [CheckedContinuation<UInt16, Error>] = []
    private var startError: Error?

    public private(set) var port: UInt16?

    public init(whitelist: Whitelist) {
        self.whitelist = whitelist
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            // The listener may accept on all interfaces; only loopback clients
            // may use the proxy. Anything else is dropped immediately.
            guard let self, Self.isLoopback(connection.endpoint) else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.listenerStateChanged(state) }
        }
        listener.start(queue: .global())
        self.listener = listener
        try await waitForPort()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        port = nil
    }

    /// The bound loopback port, waiting for the listener to become ready.
    public func portValue() async throws -> UInt16 {
        // Actor-isolated: the checks and the registration below are atomic, so
        // either ready/failed already happened (seen above) or will resume the
        // continuation we register.
        if let port { return port }
        if let startError { throw startError }
        return try await withCheckedThrowingContinuation { continuation in
            portContinuations.append(continuation)
        }
    }

    /// The proxy environment to pass to the agent: every major HTTP client
    /// honors these (curl, python, npm, cargo, node-with--use-env-proxy, git).
    public nonisolated func environmentVariables(port: UInt16) -> [String: String] {
        let proxy = "http://127.0.0.1:\(port)"
        return [
            "HTTP_PROXY": proxy, "http_proxy": proxy,
            "HTTPS_PROXY": proxy, "https_proxy": proxy,
            "ALL_PROXY": proxy, "all_proxy": proxy,
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
            // node's undici (fetch/http) only honors proxy env with this flag.
            "NODE_OPTIONS": "--use-env-proxy",
            // git ignores proxy env; inject config via env instead.
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "http.proxy", "GIT_CONFIG_VALUE_0": proxy,
            "GIT_CONFIG_KEY_1": "https.proxy", "GIT_CONFIG_VALUE_1": proxy,
        ]
    }

    // MARK: - Listener

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            let continuations = portContinuations
            portContinuations.removeAll()
            if let port {
                for continuation in continuations {
                    continuation.resume(returning: port)
                }
            }
        case .failed(let error):
            startError = ProxyError.startFailed(error.localizedDescription)
            let continuations = portContinuations
            portContinuations.removeAll()
            for continuation in continuations {
                continuation.resume(throwing: startError!)
            }
        default:
            break
        }
    }

    private func waitForPort() async throws {
        _ = try await portValue()
    }

    /// True when a peer endpoint is on the loopback interface. The whitelist
    /// proxy is the agent's egress; it must not be reachable from the network.
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.rawValue == Data([127, 0, 0, 1])
        case .ipv6(let address):
            return address.rawValue == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        default:
            return false
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .global())
        Task {
            defer {
                connections[id] = nil
                connection.cancel()
            }
            do {
                try await handle(connection)
            } catch {
                connection.cancel()
            }
        }
    }

    private func handle(_ connection: NWConnection) async throws {
        // Read the request head (headers end at CRLFCRLF).
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var head = Data()
        var sawTerminator = false
        while !sawTerminator {
            let (data, complete, error) = try await receive(connection)
            if let data {
                head.append(data)
                if head.range(of: terminator) != nil {
                    sawTerminator = true
                } else if head.count > 64 * 1024 {
                    throw ProxyError.requestTooLarge
                }
            }
            if complete || error != nil { break }
        }

        guard let terminatorRange = head.range(of: terminator) else {
            throw ProxyError.malformedRequest
        }
        let headBytes = head[..<terminatorRange.lowerBound]
        let tail = Data(head[terminatorRange.upperBound...])
        guard let headString = String(data: headBytes, encoding: .utf8),
              let firstLine = headString.split(separator: "\r\n", maxSplits: 1).first else {
            throw ProxyError.malformedRequest
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { throw ProxyError.malformedRequest }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            guard let hostPort = Self.parseHostPort(target) else {
                throw ProxyError.malformedRequest
            }
            guard whitelist.allows(hostPort.host) else {
                try await respondError(connection, status: 403, reason: "Forbidden")
                return
            }
            try await respondConnectOK(connection)
            try await tunnel(connection, to: hostPort)
        } else {
            // Absolute-URI (plain HTTP via proxy): "GET http://host/path HTTP/1.1"
            guard let url = URL(string: target), let host = url.host else {
                throw ProxyError.malformedRequest
            }
            guard whitelist.allows(host) else {
                try await respondError(connection, status: 403, reason: "Forbidden")
                return
            }
            let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
            let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
            let requestLine = "\(method) \(path) HTTP/1.1"

            // Rebuild the head with the request line rewritten to origin-form,
            // then forward any bytes that arrived past the head.
            var lines = headString.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
            if !lines.isEmpty { lines[0] = requestLine }
            var forwarded = Data()
            forwarded.append(contentsOf: lines.joined(separator: "\r\n").utf8)
            forwarded.append(terminator)
            forwarded.append(tail)

            let upstream = try await connect(to: host, port: port)
            let sent = await send(upstream, forwarded)
            guard sent else {
                upstream.cancel()
                throw ProxyError.upstreamFailed("write to upstream failed")
            }
            try await relay(client: connection, upstream: upstream)
        }
    }

    /// Parses "host:port" (CONNECT targets always carry a port).
    private static func parseHostPort(_ target: String) -> (host: String, port: UInt16)? {
        if target.hasPrefix("[") {
            // [::1]:443
            guard let close = target.firstIndex(of: "]") else { return nil }
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = target.lastIndex(of: ":") else { return nil }
        let host = String(target[..<colon])
        guard let port = UInt16(target[target.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    // MARK: - Tunneling

    /// Opens a raw tunnel between the client and the CONNECT target.
    private func tunnel(_ client: NWConnection, to hostPort: (host: String, port: UInt16)) async throws {
        let upstream = try await connect(to: hostPort.host, port: hostPort.port)
        try await relay(client: client, upstream: upstream)
    }

    private func relay(client: NWConnection, upstream: NWConnection) async throws {
        // Two one-way pumps; when either direction completes/errors, tear
        // down both sides.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pump(from: client, to: upstream) }
            group.addTask { await self.pump(from: upstream, to: client) }
            // Keep going until both finish.
            while await group.next() != nil {}
        }
        client.cancel()
        upstream.cancel()
    }

    /// Pumps bytes from one connection to the other, ending the destination
    /// with EOF when the source closes.
    private func pump(from source: NWConnection, to destination: NWConnection) async {
        while true {
            let (data, complete, error) = await receive(source)
            if let data, !data.isEmpty {
                let sent = await send(destination, data)
                if !sent { break }
            }
            if complete || error != nil {
                destination.send(content: nil, completion: .contentProcessed { _ in })
                break
            }
        }
    }

    // MARK: - I/O helpers

    private func connect(to host: String, port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyError.upstreamFailed("invalid port \(port)")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        connection.start(queue: .global())
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume(returning: connection)
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: ProxyError.upstreamFailed(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: ProxyError.upstreamFailed("cancelled"))
                default:
                    break
                }
            }
        }
    }

    private func receive(
        _ connection: NWConnection
    ) async -> (Data?, Bool, NWError?) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                continuation.resume(returning: (data, complete, error))
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// Bare 200 for CONNECT — no body, no length header: the bytes after this
    /// line belong to the raw tunnel, and any extra bytes corrupt TLS.
    private func respondConnectOK(_ connection: NWConnection) async {
        _ = await send(connection, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
    }

    /// HTML error page (403 etc.) — normal HTTP, no tunnel follows.
    private func respondError(_ connection: NWConnection, status: Int, reason: String) async throws {
        let body = "<html><body><h1>\(status) \(reason)</h1><p>This host is not in the agent's allowed list.</p></body></html>\r\n"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let sent = await send(connection, Data(response.utf8))
        if sent {
            connection.send(content: nil, completion: .contentProcessed { _ in })
        }
    }
}
