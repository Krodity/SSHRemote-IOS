import Foundation
import SwiftUI
import NIOSSH
import NIOCore
import Network

enum ConnState: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// A host key the user has to rule on before the connection can continue.
struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let hostId: String
    let hostname: String
    let fingerprint: String
    let keyLine: String
    /// A *different* key is already trusted for this host.
    let changed: Bool
    let resolve: (Bool) -> Void
}

struct OutputSheet: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let result: CommandResult
}

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [Host] = Store.loadHosts() {
        didSet { Store.saveHosts(hosts) }
    }
    @Published private(set) var state: [String: ConnState] = [:]
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var output: OutputSheet?
    /// Edit-mode Copy → Paste, across pages and hosts. In-memory only.
    @Published var copiedButton: Command?
    @Published var toast: String?

    private var connections: [String: SSHConnection] = [:]
    private var connecting: [String: Task<SSHConnection, Error>] = [:]

    // ── auto-reconnect ───────────────────────────────────────────────────────
    /// Hosts whose remote screen is open (a count: the edit sheet can stack
    /// a second one). Only these are kept connected.
    private var watched: [String: Int] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    /// Last failure can't be fixed by retrying (bad key/password, rejected host key).
    private var fatal: Set<String> = []
    private var inBackground = false
    private let pathMonitor = NWPathMonitor()
    private var lastPath: NWPath.Status?

    init() {
        // Wi-Fi ↔ cellular, VPN up/down, network back after a dead zone: the
        // old TCP connection is often silently dead, so re-check.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sshremote.path"))
    }

    // Mouse deltas pile up while a move command is in flight and go out as
    // one, so a slow link lags a little instead of queueing seconds of moves.
    private var pendingDx: Double = 0
    private var pendingDy: Double = 0
    private var moving = false
    private var directQueue: [DirectInput] = []
    private var directDraining = false

    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }

    func update(_ host: Host) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
    }

    func delete(_ host: Host) {
        Task { await disconnect(host.id) }
        Store.setPassword(nil, for: host.id)
        hosts.removeAll { $0.id == host.id }
    }

    // ── connection ───────────────────────────────────────────────────────────
    func state(of id: String) -> ConnState { state[id] ?? .disconnected }

    @discardableResult
    func connect(_ id: String) async -> SSHConnection? {
        if let c = connections[id], c.isActive { return c }
        guard let host = host(id) else { return nil }
        if let t = connecting[id] { return try? await t.value }

        state[id] = .connecting
        let creds = Credentials(username: host.user,
                                privateKey: host.allowIdentities ? Store.identityKey : nil,
                                password: Store.password(for: id))
        let task = Task { () throws -> SSHConnection in
            try await SSHConnection.connect(host: host.hostname, port: host.port, credentials: creds) { key, fp in
                await self.decideHostKey(hostId: id, key: key, fingerprint: fp)
            }
        }
        connecting[id] = task
        defer { connecting[id] = nil }
        do {
            let c = try await task.value
            connections[id] = c
            state[id] = .connected
            fatal.remove(id)
            c.onClose { [weak self] in Task { @MainActor in self?.dropped(id, c) } }
            return c
        } catch {
            state[id] = .failed(SSHConnection.describe(error))
            if (error as? SSHError)?.retryable == false { fatal.insert(id) }
            return nil
        }
    }

    func disconnect(_ id: String) async {
        reconnectTasks.removeValue(forKey: id)?.cancel()
        // Forget it first, so its close isn't mistaken for a drop.
        let c = connections.removeValue(forKey: id)
        state[id] = .disconnected
        await c?.close()
    }

    func disconnectAll() {
        for id in connections.keys { Task { await disconnect(id) } }
    }

    /// A remote screen for `id` opened / closed.
    func watch(_ id: String) {
        watched[id, default: 0] += 1
        keepAlive(id)
    }

    func unwatch(_ id: String) {
        guard let n = watched[id] else { return }
        if n > 1 { watched[id] = n - 1; return }
        watched[id] = nil
        reconnectTasks.removeValue(forKey: id)?.cancel()
    }

    /// The Connect button: clears a "don't retry" failure (the user may have
    /// just fixed the password) and starts over.
    func userConnect(_ id: String) {
        fatal.remove(id)
        reconnectTasks.removeValue(forKey: id)?.cancel()
        keepAlive(id)
    }

    /// Multitasking away. Connections are left open on purpose: after a
    /// quick app switch the socket is usually still alive, and the remote
    /// should just keep working with no reconnect at all.
    func appEnteredBackground() {
        inBackground = true
        for t in reconnectTasks.values { t.cancel() }
        reconnectTasks.removeAll()
    }

    /// Back in the app: check each on-screen host's connection. A dead one
    /// (iOS suspended us long enough for the socket to die) is replaced
    /// right away, so the remote never sits on "Disconnected".
    func appBecameActive() {
        guard inBackground else { return }
        inBackground = false
        for id in watched.keys { Task { await verify(id) } }
    }

    private func dropped(_ id: String, _ c: SSHConnection) {
        guard connections[id] === c else { return }   // replaced or closed on purpose
        connections[id] = nil
        state[id] = .disconnected
        keepAlive(id)
    }

    private func networkChanged(_ path: NWPath) {
        defer { lastPath = path.status }
        guard path.status == .satisfied, lastPath != nil else { return }
        for id in watched.keys { Task { await verify(id) } }
    }

    /// A connection that looks open may be dead (network changed under it):
    /// run a no-op, and on silence close it — which reconnects.
    private func verify(_ id: String) async {
        guard let c = connections[id], c.isActive else { keepAlive(id); return }
        do {
            _ = try await c.run("true", timeout: .seconds(3))
        } catch {
            await c.close()   // → dropped → keepAlive
        }
    }

    /// Keep a watched host connected: connect now, and on failure retry with
    /// backoff (1, 2, 4, 8, 16, then every 30 s) until it works, the screen
    /// closes, the app backgrounds, or the failure can't be fixed by retrying.
    private func keepAlive(_ id: String) {
        guard !inBackground, watched[id] != nil, reconnectTasks[id] == nil, !fatal.contains(id) else { return }
        if let c = connections[id], c.isActive { return }
        reconnectTasks[id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if await self.connect(id) != nil || self.fatal.contains(id) { break }
                let delay = min(30, 1 << min(attempt, 5))
                attempt += 1
                if case .failed(let why) = self.state(of: id) {
                    self.state[id] = .failed("\(why) — retrying in \(delay)s")
                }
                try? await Task.sleep(for: .seconds(delay))
            }
            self?.reconnectTasks[id] = nil
        }
    }

    private func decideHostKey(hostId: String, key: NIOSSHPublicKey, fingerprint: String) async -> Bool {
        guard var host = host(hostId) else { return false }
        let identity = Keys.identity(key)
        if host.trusts(identity) { return true }
        let accepted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            hostKeyPrompt = HostKeyPrompt(hostId: hostId, hostname: host.hostname, fingerprint: fingerprint,
                                          keyLine: identity, changed: host.hasKnownHostKey) { ok in
                cont.resume(returning: ok)
            }
        }
        hostKeyPrompt = nil
        if accepted {
            // A changed key replaces the old one rather than piling up beside it.
            if host.hasKnownHostKey { host.knownHosts.removeAll() }
            host.knownHosts.append("\(host.hostname) \(identity)")
            update(host)
        }
        return accepted
    }

    // ── running commands ─────────────────────────────────────────────────────
    /// Runs `command` on the host, reconnecting once if the session died.
    @discardableResult
    func run(_ command: String, on id: String, title: String? = nil, showOutput: Bool = false) async -> CommandResult? {
        guard !command.isBlank else { return nil }
        for attempt in 0..<2 {
            guard let c = await connect(id) else {
                if case .failed(let why) = state(of: id) { toast = why }
                return nil
            }
            do {
                let r = try await c.run(command)
                if showOutput {
                    output = OutputSheet(title: title ?? command, command: command, result: r)
                } else if !r.ok {
                    let err = r.stderr.isBlank ? r.stdout : r.stderr
                    toast = "Exit \(r.exitStatus ?? -1): \(err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
                }
                return r
            } catch let e as SSHError where e.isConnectionError && attempt == 0 {
                connections[id] = nil
                continue
            } catch {
                toast = SSHConnection.describe(error)
                return nil
            }
        }
        return nil
    }

    /// A command for the Files tab: no toasts, no output sheet, throws on
    /// failure, reconnects once. Capped at a few at a time — OpenSSH allows
    /// only 10 channels per connection (MaxSessions), and a thumbnail grid
    /// plus a video stream would otherwise starve the remote's buttons.
    func exec(_ command: String, on id: String, timeout: Int64 = 60) async throws -> CommandResult {
        await fileSlots.acquire()
        defer { Task { await fileSlots.release() } }
        for attempt in 0..<2 {
            guard let c = await connect(id) else {
                if case .failed(let why) = state(of: id) { throw SSHError(message: why) }
                throw SSHError(message: "Not connected")
            }
            do {
                return try await c.run(command, timeout: .seconds(timeout))
            } catch let e as SSHError where e.isConnectionError && attempt == 0 {
                connections[id] = nil
            }
        }
        throw SSHError(message: "Not connected")
    }

    private let fileSlots = AsyncSemaphore(6)

    func run(_ cmd: Command, on id: String) async {
        await run(cmd.command ?? "", on: id, title: cmd.displayText, showOutput: cmd.wantsOutput)
    }

    func mouseMove(dx: Double, dy: Double, on id: String) {
        guard let template = host(id)?.command(.MOUSE_MOVE)?.command else { return }
        pendingDx += dx
        pendingDy += dy
        guard !moving else { return }
        moving = true
        Task {
            defer { moving = false }
            while Int(pendingDx) != 0 || Int(pendingDy) != 0 {
                let cx = Int(pendingDx), cy = Int(pendingDy)
                pendingDx -= Double(cx)
                pendingDy -= Double(cy)
                let cmd = template.replacingOccurrences(of: "%dx", with: String(cx))
                    .replacingOccurrences(of: "%dy", with: String(cy))
                await run(cmd, on: id)
            }
        }
    }

    /// A Keyboard-tab key: `%d` gets the Linux keycode (ydotool), anything
    /// else gets the X keysym name via `%s` (wtype, xdotool).
    func key(_ key: SpecialKey, on id: String) {
        guard let cmd = keyCommand(key, on: id) else { return }
        Task { await run(cmd, on: id) }
    }

    func type(_ text: String, on id: String) {
        guard !text.isEmpty, let cmd = typeCommand(text, on: id) else { return }
        Task { await run(cmd, on: id) }
    }

    private func keyCommand(_ key: SpecialKey, on id: String) -> String? {
        guard let t = host(id)?.command(.KEYBOARD_KEY_INPUT)?.command else {
            toast = "Set a Key press command for this host (Edit → Remote commands)"
            return nil
        }
        return t.contains("%d") ? t.replacingOccurrences(of: "%d", with: String(key.code))
                                : t.replacingOccurrences(of: "%s", with: key.name)
    }

    private func typeCommand(_ text: String, on id: String) -> String? {
        guard let t = host(id)?.command(.KEYBOARD_TYPE_INPUT) else {
            toast = "Set a Type text command for this host (Edit → Remote commands)"
            return nil
        }
        return t.formatted(text: text)
    }

    enum DirectInput {
        case text(String)
        case key(SpecialKey)
    }

    /// Live keystrokes from the pop-up keyboard. Runs one command at a time
    /// so they land in order, and merges text typed while the previous
    /// command was in flight into a single `type`.
    func direct(_ input: DirectInput, on id: String) {
        directQueue.append(input)
        guard !directDraining else { return }
        directDraining = true
        Task {
            defer { directDraining = false }
            while !directQueue.isEmpty {
                let next = directQueue.removeFirst()
                let cmd: String?
                switch next {
                case .text(var s):
                    while case .text(let more)? = directQueue.first {
                        s += more
                        directQueue.removeFirst()
                    }
                    cmd = typeCommand(s, on: id)
                case .key(let k):
                    cmd = keyCommand(k, on: id)
                }
                guard let cmd else { directQueue.removeAll(); return }
                await run(cmd, on: id)
            }
        }
    }

    // ── import ───────────────────────────────────────────────────────────────
    /// Adds or replaces hosts from an Android export. Returns how many.
    func importSettings(_ raw: String) throws -> Int {
        let s = try ExportedSettings.parse(raw)
        let globalKnown = (s.knownHosts ?? []).map(\.line)
        var n = 0
        for var h in s.hosts ?? [] {
            // Carry over any global known_hosts lines that name this host.
            for line in globalKnown where !h.knownHosts.contains(line) {
                let names = line.split(separator: " ").first.map { String($0) } ?? ""
                if names.split(separator: ",").contains(where: {
                    $0 == h.hostname || $0 == "[\(h.hostname)]:\(h.port)"
                }) {
                    h.knownHosts.append(line)
                }
            }
            update(h)
            n += 1
        }
        return n
    }
}

/// Counting semaphore for async code.
actor AsyncSemaphore {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { free = count }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}
