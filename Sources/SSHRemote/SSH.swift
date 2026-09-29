import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

struct SSHError: LocalizedError {
    let message: String
    var isConnectionError = false
    /// False for failures a retry can't fix (rejected host key, bad
    /// credentials) — auto-reconnect stops instead of looping on them.
    var retryable = true
    var errorDescription: String? { message }
}

/// The result of one command: what it printed, and how it exited.
struct CommandResult {
    var stdout: String
    var stderr: String
    var exitStatus: Int?
    /// stdout as raw bytes — file reads and thumbnails aren't text.
    var data = Data()

    var ok: Bool { exitStatus == nil || exitStatus == 0 }

    /// Laid out the way the Android app shows it: stderr lines tagged.
    var combined: String {
        var s = stdout
        if !stderr.isEmpty {
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            s += stderr.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "[ERROR] \($0)" }.joined(separator: "\n")
        }
        return s
    }
}

/// How to prove who we are. Tried in order: key first, then password.
struct Credentials {
    var username: String
    var privateKey: NIOSSHPrivateKey?
    var password: String?
}

/// Asked on the main actor whether an unknown or changed host key is trusted.
typealias HostKeyDecider = @MainActor (_ key: NIOSSHPublicKey, _ fingerprint: String) async -> Bool

/// One authenticated SSH connection; each command gets its own exec channel,
/// exactly as the Android app's `executeCommand` does.
final class SSHConnection {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let channel: Channel

    private init(channel: Channel) {
        self.channel = channel
    }

    var isActive: Bool { channel.isActive }

    /// Called once when the TCP connection closes, for whatever reason.
    func onClose(_ handler: @escaping () -> Void) {
        channel.closeFuture.whenComplete { _ in handler() }
    }

    static func connect(
        host: String,
        port: Int,
        credentials: Credentials,
        decideHostKey: @escaping HostKeyDecider
    ) async throws -> SSHConnection {
        let authDone = group.next().makePromise(of: Void.self)
        let userAuth = AuthDelegate(credentials: credentials)
        let serverAuth = HostKeyDelegate(decide: decideHostKey)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                                      inboundChildChannelInitializer: nil),
                        AuthWatcher(promise: authDone),
                    ])
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            authDone.fail(error)
            throw SSHError(message: "Can't connect to \(host):\(port) — \(describe(error))", isConnectionError: true)
        }
        do {
            // Resolves on the server's USERAUTH_SUCCESS, fails on a rejected
            // host key, exhausted auth methods, or a dropped connection.
            try await authDone.futureResult.get()
        } catch {
            try? await channel.close()
            if serverAuth.rejected {
                throw SSHError(message: "Host key not trusted — connection cancelled", isConnectionError: true,
                               retryable: false)
            }
            if userAuth.exhausted {
                throw SSHError(message: "Authentication failed for \(credentials.username)@\(host). "
                                + (credentials.privateKey != nil ? "Is this app's public key in ~/.ssh/authorized_keys? " : "")
                                + (credentials.password == nil ? "No password is saved for this host." : "Check the password."),
                               isConnectionError: true, retryable: false)
            }
            throw SSHError(message: "SSH handshake failed: \(describe(error))", isConnectionError: true)
        }
        return SSHConnection(channel: channel)
    }

    func close() async {
        try? await channel.close()
    }

    /// Runs one command in its own exec channel and collects its output.
    func run(_ command: String, timeout: TimeAmount = .seconds(60)) async throws -> CommandResult {
        guard channel.isActive else {
            throw SSHError(message: "SSH session is not active. Reconnect.", isConnectionError: true)
        }
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let done = channel.eventLoop.makePromise(of: CommandResult.self)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)

        let schedule = channel.eventLoop.scheduleTask(in: timeout) {
            done.fail(SSHError(message: "Command timed out"))
        }
        defer { schedule.cancel() }

        channel.eventLoop.execute {
            handler.createChannel(childPromise, channelType: .session) { child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(SSHError(message: "Unexpected channel type"))
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, done: done))
                }
            }
        }
        do {
            let child = try await childPromise.futureResult.get()
            defer { child.close(promise: nil) }
            return try await done.futureResult.get()
        } catch let e as SSHError {
            throw e
        } catch {
            done.fail(error)
            throw SSHError(message: "Execution failed: \(Self.describe(error))", isConnectionError: !channel.isActive)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SSHError { return e.message }
        if let e = error as? NIOConnectionError {
            if let dns = e.dnsAAAAError ?? e.dnsAError { return "can't resolve host (\(dns))" }
            return e.connectionErrors.first.map { "\($0.error)" } ?? "connection failed"
        }
        if error is ChannelError { return "connection closed" }
        return String(describing: error)
    }
}

// ── keys ─────────────────────────────────────────────────────────────────────

enum Keys {
    /// OpenSSH `authorized_keys` form: "ssh-ed25519 AAAA… comment".
    static func openSSH(_ key: NIOSSHPublicKey, comment: String? = nil) -> String {
        let s = String(openSSHPublicKey: key)
        return comment.map { "\(s) \($0)" } ?? s
    }

    /// "SHA256:…" as `ssh-keygen -lf` prints it.
    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let parts = String(openSSHPublicKey: key).split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = SHA256.hash(data: blob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:\(b64)"
    }

    /// The "type base64" part of a key, for comparing against stored lines.
    static func identity(_ key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key).split(separator: " ").prefix(2).joined(separator: " ")
    }
}

// ── NIO plumbing ─────────────────────────────────────────────────────────────

/// Offers the key, then the password, then gives up.
private final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let credentials: Credentials
    private var triedKey = false
    private var triedPassword = false
    private(set) var exhausted = false

    init(credentials: Credentials) {
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !triedKey, let key = credentials.privateKey, availableMethods.contains(.publicKey) {
            triedKey = true
            nextChallengePromise.succeed(.init(username: credentials.username, serviceName: "",
                                               offer: .privateKey(.init(privateKey: key))))
            return
        }
        if !triedPassword, let pw = credentials.password, !pw.isEmpty, availableMethods.contains(.password) {
            triedPassword = true
            nextChallengePromise.succeed(.init(username: credentials.username, serviceName: "",
                                               offer: .password(.init(password: pw))))
            return
        }
        exhausted = true
        nextChallengePromise.fail(SSHError(message: "No accepted authentication method"))
    }
}

/// Hands the host key to the app (known-hosts check, or a prompt) and waits.
private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let decide: HostKeyDecider
    private(set) var rejected = false

    init(decide: @escaping HostKeyDecider) {
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = Keys.fingerprint(hostKey)
        Task { @MainActor in
            if await self.decide(hostKey, fp) {
                validationCompletePromise.succeed(())
            } else {
                self.rejected = true
                validationCompletePromise.fail(SSHError(message: "Host key rejected"))
            }
        }
    }
}

/// Completes `promise` once the server accepts our credentials.
private final class AuthWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(SSHError(message: "Connection closed", isConnectionError: true))
        context.fireChannelInactive()
    }
}

/// Sends one exec request and gathers stdout, stderr and the exit status.
private final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let done: EventLoopPromise<CommandResult>
    private var stdout = ByteBuffer()
    private var stderr = ByteBuffer()
    private var exitStatus: Int?

    init(command: String, done: EventLoopPromise<CommandResult>) {
        self.command = command
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Without this the child closes on the server's EOF before the
        // exit-status request that follows it arrives.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                                         promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            // Arrives after EOF; the server's CHANNEL_CLOSE follows it, and
            // that close is what ends the command — not the EOF.
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = data.data else { return }
        switch data.type {
        case .channel: stdout.writeBuffer(&bytes)
        case .stdErr: stderr.writeBuffer(&bytes)
        default: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        done.succeed(CommandResult(stdout: String(buffer: stdout), stderr: String(buffer: stderr),
                                   exitStatus: exitStatus, data: Data(stdout.readableBytesView)))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
        context.close(promise: nil)
    }
}
