//
//  DMBAppearanceSync.swift
//  DarkModeBuddyCore
//
//  Created by Michel Storms on 22/11/2026.
//

import Cocoa
import Combine
import Network
import os.log

/// Shares the host's Light/Dark appearance with DarkModeBuddy running in client mode inside virtual machines.
///
/// Wire format, one JSON object per line:
/// - client → host, once after connecting: `{"token":"…"}`
/// - host → client, once the token checks out and on every change after that: `{"appearance":"dark"}` or `{"appearance":"light"}`
enum DMBAppearanceSyncProtocol {
    static let serviceType = "_darkmodebuddy._tcp"
    static let defaultPort: UInt16 = 52891

    /// TCP keepalive, so a host or client that vanishes (VM suspended, host asleep) is noticed within about 25 seconds.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    static func encode(_ message: [String: String]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Splits complete lines off the front of `buffer` and decodes each as a message.
    static func takeMessages(from buffer: inout Data) -> [[String: String]] {
        var messages = [[String: String]]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: String] {
                messages.append(message)
            }
        }
        return messages
    }

    static let maximumBufferSize = 4096
}

public enum DMBVirtualMachine {
    /// Whether this Mac is a guest running under a hypervisor.
    public static var isRunningInVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}

private extension DMBSystemAppearanceSwitcher.Appearance {
    var wireValue: String { self == .dark ? "dark" : "light" }

    init?(wireValue: String) {
        switch wireValue {
        case "dark": self = .dark
        case "light": self = .light
        default: return nil
        }
    }
}

// MARK: - Host

/// Listens for clients and pushes every system appearance change to them, whatever made the change.
public final class DMBAppearanceSyncHost {

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        var isAuthenticated = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let log = OSLog(subsystem: kDarkModeBuddyCoreSubsystemName, category: String(describing: DMBAppearanceSyncHost.self))

    private let token: String
    private var listener: NWListener?
    private var peers = [ObjectIdentifier: Peer]()
    private var themeObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    private var isRunning = false

    /// Clients must send `token` before they get any updates. An empty token lets any client on a private network in.
    public init(token: String) {
        self.token = token
    }

    deinit {
        stop()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.broadcastCurrentAppearance()
        }

        startListener()
    }

    public func stop() {
        isRunning = false

        restartWorkItem?.cancel()
        restartWorkItem = nil

        if let themeObserver = themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        themeObserver = nil

        listener?.cancel()
        listener = nil

        peers.values.forEach { $0.connection.cancel() }
        peers.removeAll()
    }

    private func startListener() {
        guard isRunning else { return }

        do {
            let listener = try NWListener(using: DMBAppearanceSyncProtocol.parameters(),
                                          on: NWEndpoint.Port(rawValue: DMBAppearanceSyncProtocol.defaultPort)!)
            listener.service = NWListener.Service(name: Host.current().localizedName, type: DMBAppearanceSyncProtocol.serviceType)

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self = self, let listener = listener, listener === self.listener else { return }

                switch state {
                case .ready:
                    os_log("Sharing appearance on port %{public}d", log: self.log, type: .info, Int(DMBAppearanceSyncProtocol.defaultPort))
                case .failed(let error):
                    os_log("Listener failed: %{public}@", log: self.log, type: .error, String(describing: error))
                    self.scheduleListenerRestart()
                default:
                    break
                }
            }

            self.listener = listener
            listener.start(queue: .main)
        } catch {
            os_log("Couldn't create listener: %{public}@", log: log, type: .error, String(describing: error))
            scheduleListenerRestart()
        }
    }

    /// The port may still be held by a previous instance, so keep trying.
    private func scheduleListenerRestart() {
        listener?.cancel()
        listener = nil

        let workItem = DispatchWorkItem { [weak self] in self?.startListener() }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isPrivateNetwork(connection.endpoint) else {
            os_log("Refusing connection from %{public}@", log: log, type: .info, String(describing: connection.endpoint))
            connection.cancel()
            return
        }

        let peer = Peer(connection: connection)
        let id = ObjectIdentifier(peer)
        peers[id] = peer

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.peers[id] = nil
            default:
                break
            }
        }

        connection.start(queue: .main)
        receive(from: peer)

        // Drop clients that never identify themselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak peer] in
            guard let peer = peer, !peer.isAuthenticated else { return }
            peer.connection.cancel()
        }
    }

    private func receive(from peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self = self, let peer = peer else { return }

            if let data = data {
                peer.buffer.append(data)

                for message in DMBAppearanceSyncProtocol.takeMessages(from: &peer.buffer) {
                    self.handle(message, from: peer)
                }

                if peer.buffer.count > DMBAppearanceSyncProtocol.maximumBufferSize {
                    peer.connection.cancel()
                    return
                }
            }

            guard !isComplete, error == nil else {
                peer.connection.cancel()
                return
            }

            self.receive(from: peer)
        }
    }

    private func handle(_ message: [String: String], from peer: Peer) {
        guard !peer.isAuthenticated else { return }

        guard token.isEmpty || message["token"] == token else {
            os_log("Refusing client with the wrong token", log: log, type: .info)
            peer.connection.cancel()
            return
        }

        peer.isAuthenticated = true
        send(DMBSystemAppearanceSwitcher.Appearance.current, to: peer)
    }

    private func broadcastCurrentAppearance() {
        let appearance = DMBSystemAppearanceSwitcher.Appearance.current

        os_log("Sending %{public}@ appearance to clients", log: log, type: .debug, appearance.description)

        peers.values.filter(\.isAuthenticated).forEach { send(appearance, to: $0) }
    }

    private func send(_ appearance: DMBSystemAppearanceSwitcher.Appearance, to peer: Peer) {
        guard let data = DMBAppearanceSyncProtocol.encode(["appearance": appearance.wireValue]) else { return }
        peer.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Loopback, link-local and private (RFC 1918 / ULA) addresses only, which covers VM NAT and host-only networks.
    static func isPrivateNetwork(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        switch host {
        case .ipv4(let address):
            return isPrivate(address)
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return isPrivate(mapped) }
            if address.isLoopback || address.isLinkLocal { return true }
            return (address.rawValue.first ?? 0) & 0xFE == 0xFC
        default:
            return false
        }
    }

    private static func isPrivate(_ address: IPv4Address) -> Bool {
        if address.isLoopback || address.isLinkLocal { return true }

        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }

        switch (bytes[0], bytes[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

}

// MARK: - Client

/// Follows the appearance pushed by a host. Reads no sensors and sits idle on its socket between messages.
public final class DMBAppearanceSyncClient: ObservableObject {

    private let log = OSLog(subsystem: kDarkModeBuddyCoreSubsystemName, category: String(describing: DMBAppearanceSyncClient.self))

    @Published public private(set) var status = "Not Connected"

    private var hostAddress = ""
    private var token = ""
    private var isRunning = false

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()

    private var retryDelay: TimeInterval = 1
    private var retryWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    /// Set when we turned macOS' Auto appearance off, so it can be turned back on when we quit.
    private var didDisableAutomaticSwitching = false

    public init() { }

    deinit {
        stop()
    }

    /// Connects to `hostAddress` ("host" or "host:port"), or to the first host found with Bonjour when it's empty.
    /// Calling it again restarts with the new settings.
    public func start(hostAddress: String, token: String) {
        stop()

        self.hostAddress = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token
        isRunning = true
        retryDelay = 1

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconnectNow()
        }

        connect()
    }

    public func stop() {
        isRunning = false

        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil

        retryWorkItem?.cancel()
        retryWorkItem = nil

        tearDown()
        status = "Not Connected"
    }

    /// Turns macOS' Auto appearance back on if following the host turned it off.
    public func restoreAutomaticSwitching() {
        guard didDisableAutomaticSwitching else { return }
        didDisableAutomaticSwitching = false

        SLSSetAppearanceThemeSwitchesAutomatically(true)
    }

    private func tearDown() {
        browser?.cancel()
        browser = nil

        connection?.cancel()
        connection = nil

        buffer.removeAll()
    }

    private func reconnectNow() {
        guard isRunning else { return }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryDelay = 1

        tearDown()
        connect()
    }

    private func connect() {
        guard isRunning else { return }

        if hostAddress.isEmpty {
            browse()
        } else {
            connect(to: manualEndpoint, name: hostAddress)
        }
    }

    private var manualEndpoint: NWEndpoint {
        var host = hostAddress
        var port = DMBAppearanceSyncProtocol.defaultPort

        // "host:port" or "[ipv6]:port"; a bare IPv6 address has more than one colon and no port.
        if hostAddress.hasPrefix("["), let close = hostAddress.firstIndex(of: "]") {
            host = String(hostAddress[hostAddress.index(after: hostAddress.startIndex)..<close])
            let rest = hostAddress[hostAddress.index(after: close)...]
            if rest.hasPrefix(":"), let parsedPort = UInt16(rest.dropFirst()) {
                port = parsedPort
            }
        } else {
            let parts = hostAddress.split(separator: ":")
            if parts.count == 2, let parsedPort = UInt16(parts[1]) {
                host = String(parts[0])
                port = parsedPort
            }
        }

        return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    private func browse() {
        status = "Looking for a Host…"

        let browser = NWBrowser(for: .bonjour(type: DMBAppearanceSyncProtocol.serviceType, domain: nil), using: .tcp)

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self = self, let browser = browser, browser === self.browser else { return }
            guard let result = results.first else { return }

            var name = "Host"
            if case .service(let serviceName, _, _, _) = result.endpoint {
                name = serviceName
            }

            browser.cancel()
            self.browser = nil

            self.connect(to: result.endpoint, name: name)
        }

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self = self, let browser = browser, browser === self.browser else { return }

            if case .failed(let error) = state {
                os_log("Browsing failed: %{public}@", log: self.log, type: .error, String(describing: error))
                self.connectionDidEnd()
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        status = "Connecting to \(name)…"

        let connection = NWConnection(to: endpoint, using: DMBAppearanceSyncProtocol.parameters())

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, connection === self.connection else { return }

            switch state {
            case .ready:
                os_log("Connected to %{public}@", log: self.log, type: .info, name)

                self.retryDelay = 1
                self.status = "Connected to \(name)"

                if let hello = DMBAppearanceSyncProtocol.encode(["token": self.token]) {
                    connection.send(content: hello, completion: .contentProcessed { _ in })
                }

                self.receive(on: connection)
            case .waiting(let error), .failed(let error):
                // Our own backoff instead of NWConnection's, which waits for a network change.
                os_log("Connection to %{public}@ ended: %{public}@", log: self.log, type: .info, name, String(describing: error))
                self.connectionDidEnd()
            default:
                break
            }
        }

        self.connection = connection
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection, connection === self.connection else { return }

            if let data = data {
                self.buffer.append(data)

                for message in DMBAppearanceSyncProtocol.takeMessages(from: &self.buffer) {
                    self.handle(message)
                }

                if self.buffer.count > DMBAppearanceSyncProtocol.maximumBufferSize {
                    self.connectionDidEnd()
                    return
                }
            }

            guard !isComplete, error == nil else {
                self.connectionDidEnd()
                return
            }

            self.receive(on: connection)
        }
    }

    private func handle(_ message: [String: String]) {
        guard let value = message["appearance"],
              let appearance = DMBSystemAppearanceSwitcher.Appearance(wireValue: value) else { return }

        // macOS' own Auto appearance would undo what the host asks for.
        if SLSGetAppearanceThemeSwitchesAutomatically() {
            SLSSetAppearanceThemeSwitchesAutomatically(false)
            didDisableAutomaticSwitching = true
        }

        guard appearance != .current else { return }

        os_log("Host asked for %{public}@ appearance", log: log, type: .info, appearance.description)

        SLSSetAppearanceThemeLegacy(appearance.rawValue)
    }

    private func connectionDidEnd() {
        tearDown()

        guard isRunning else { return }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)

        status = "Not Connected, Retrying in \(Int(delay))s"

        let workItem = DispatchWorkItem { [weak self] in self?.connect() }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

}
