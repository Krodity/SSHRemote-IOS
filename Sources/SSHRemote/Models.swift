import Foundation

/// One button's behaviour. Field names match the Android app's export format
/// (`ExportedCommand`), so a settings export round-trips unchanged.
struct Command: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String?
    var command: String?
    var longPressCommand: String?
    var showOutput: Bool?
    var renderOutputAsMarkdown: Bool?
    /// JSON key "repeat" (a Swift keyword, hence the longer name).
    var repeatWhileHeld: Bool?
    var downCommand: String?
    var upCommand: String?
    var physicalKeyCodes: [Int]?
    /// An in-app action instead of a shell command. iOS-only.
    var action: RemoteAction?
    /// Touchpad tile height in points.
    var padHeight: Double?
    /// Post a notification with the exit status when the command finishes. iOS-only.
    var notify: Bool?
    /// …and put the command's output in it.
    var notifyOutput: Bool?
    /// Hold the key down on the host for as long as the button is held:
    /// press on touch-down, release on lift. iOS-only.
    var hold: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, command, longPressCommand, showOutput, renderOutputAsMarkdown
        case repeatWhileHeld = "repeat"
        case downCommand, upCommand, physicalKeyCodes, action, padHeight, notify, notifyOutput, hold
    }

    init(_ command: String? = nil, name: String? = nil, repeat: Bool = false, showOutput: Bool = false) {
        self.command = command
        self.name = name
        self.repeatWhileHeld = `repeat` ? true : nil
        self.showOutput = showOutput ? true : nil
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = try? c.decode(String.self, forKey: .name)
        command = try? c.decode(String.self, forKey: .command)
        longPressCommand = try? c.decode(String.self, forKey: .longPressCommand)
        showOutput = try? c.decode(Bool.self, forKey: .showOutput)
        renderOutputAsMarkdown = try? c.decode(Bool.self, forKey: .renderOutputAsMarkdown)
        repeatWhileHeld = try? c.decode(Bool.self, forKey: .repeatWhileHeld)
        downCommand = try? c.decode(String.self, forKey: .downCommand)
        upCommand = try? c.decode(String.self, forKey: .upCommand)
        physicalKeyCodes = try? c.decode([Int].self, forKey: .physicalKeyCodes)
        action = try? c.decode(RemoteAction.self, forKey: .action)
        padHeight = try? c.decode(Double.self, forKey: .padHeight)
        notify = try? c.decode(Bool.self, forKey: .notify)
        notifyOutput = try? c.decode(Bool.self, forKey: .notifyOutput)
        hold = try? c.decode(Bool.self, forKey: .hold)
    }

    init(action: RemoteAction) {
        self.action = action
        self.name = action.title
    }

    /// The same button under a new id (ids must be unique for drag-reorder).
    var copied: Command {
        var c = self
        c.id = UUID().uuidString
        return c
    }

    var usesPressRelease: Bool { !(downCommand ?? "").isBlank || !(upCommand ?? "").isBlank }
    var hasTap: Bool { !(command ?? "").isBlank }
    var hasLongPress: Bool { !(longPressCommand ?? "").isBlank }
    var repeats: Bool { repeatWhileHeld == true }

    /// What a held button sends on press and on release. Explicit
    /// press/release commands win; otherwise they're split out of the tap
    /// command. Nil when the button is a plain tap.
    var holdPair: (down: String, up: String)? {
        guard hold == true || usesPressRelease else { return nil }
        let auto = HoldSplit.split(command ?? "")
        let down = downCommand.flatMap { $0.isBlank ? nil : $0 } ?? auto?.down
        let up = upCommand.flatMap { $0.isBlank ? nil : $0 } ?? auto?.up
        guard down != nil || up != nil else { return nil }
        return (down ?? "", up ?? "")
    }
    var wantsOutput: Bool { showOutput == true }

    var displayText: String {
        name.flatMap { $0.isBlank ? nil : $0 } ?? command ?? downCommand ?? upCommand ?? ""
    }

    /// `%s` → the text, single quotes escaped for a '…' shell string. Same
    /// escaping as the Android app, and the same caveat: it is not a sandbox.
    func formatted(text: String) -> String {
        (command ?? "").replacingOccurrences(of: "%s", with: text.replacingOccurrences(of: "'", with: "'\\''"))
    }
}

/// Splits a one-shot key/click command into its press half and release half,
/// so a button can hold the key down on the host. Understands ydotool, yk,
/// xdotool and wtype; anything else (pipes, quotes, scripts) returns nil and
/// needs explicit press/release commands.
enum HoldSplit {
    static func split(_ command: String) -> (down: String, up: String)? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, cmd.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`$'\"\\\n()")) == nil
        else { return nil }
        let t = cmd.split(whereSeparator: \.isWhitespace).map(String.init)
        // Leading VAR=value assignments (DISPLAY=:0 …) ride along on both halves.
        guard let i = t.firstIndex(where: { !($0.contains("=") && !$0.hasPrefix("-")) }), i + 1 < t.count
        else { return nil }
        let prefix = t[...i].joined(separator: " ")
        let tool = t[i].split(separator: "/").last.map(String.init) ?? t[i]
        let args = Array(t[(i + 1)...])
        let pair: (String, String)?
        switch tool {
        case "ydotool": pair = ydotool(args)
        case "yk": pair = yk(args)
        case "xdotool": pair = xdotool(args)
        case "wtype": pair = wtype(args)
        default: pair = nil
        }
        return pair.map { ("\(prefix) \($0.0)", "\(prefix) \($0.1)") }
    }

    /// `key 29:1 20:1 20:0 29:0` → `key 29:1 20:1` / `key 20:0 29:0`;
    /// `click 0xC0` (press+release) → `click 0x40` / `click 0x80`.
    private static func ydotool(_ a: [String]) -> (String, String)? {
        switch a.first {
        case "key":
            var opts: [String] = [], pressed: [String] = []
            var k = 1
            while k < a.count {
                if a[k] == "-d" || a[k] == "--key-delay", k + 1 < a.count { opts += [a[k], a[k + 1]]; k += 2; continue }
                let p = a[k].split(separator: ":")
                guard p.count == 2, let code = Int(p[0]) else { return nil }
                if p[1] == "1", !pressed.contains(String(code)) { pressed.append(String(code)) }
                k += 1
            }
            guard !pressed.isEmpty else { return nil }
            let o = opts.isEmpty ? "" : opts.joined(separator: " ") + " "
            return ("key \(o)" + pressed.map { "\($0):1" }.joined(separator: " "),
                    "key \(o)" + pressed.reversed().map { "\($0):0" }.joined(separator: " "))
        case "click":
            guard let last = a.last, last.lowercased().hasPrefix("0x"),
                  let v = Int(last.dropFirst(2), radix: 16), v & 0xC0 == 0xC0 else { return nil }
            let b = v & 0x0F
            return (String(format: "click 0x%02X", 0x40 + b), String(format: "click 0x%02X", 0x80 + b))
        default:
            return nil
        }
    }

    /// `yk ctrl+shift+t` → `yk hold ctrl+shift+t` / `yk release t+shift+ctrl`;
    /// `yk click right` → `yk mdown right` / `yk mup right`.
    private static func yk(_ a: [String]) -> (String, String)? {
        var a = a
        if a.first == "-d" { a.removeFirst(min(2, a.count)) }
        guard let first = a.first else { return nil }
        if first == "click" {
            let b = a.count > 1 ? a[1] : "left"
            return ("mdown \(b)", "mup \(b)")
        }
        let verbs: Set = ["type", "hold", "release", "dclick", "mdown", "mup", "move", "moveto",
                          "scroll", "panic", "list", "code", "help", "-h", "--help"]
        guard !verbs.contains(first) else { return nil }
        let released = a.reversed().map { $0.split(separator: "+").reversed().joined(separator: "+") }
        return ("hold " + a.joined(separator: " "), "release " + released.joined(separator: " "))
    }

    /// `key ctrl+t` → `keydown ctrl+t` / `keyup ctrl+t`; `click 3` → `mousedown 3` / `mouseup 3`.
    private static func xdotool(_ a: [String]) -> (String, String)? {
        guard let verb = a.first, verb == "key" || verb == "click" else { return nil }
        var plain: [String] = [], k = 1
        while k < a.count {
            if a[k] == "--clearmodifiers" { k += 1; continue }
            if a[k].hasPrefix("--") { k += 2; continue }   // --delay N, --window W, --repeat N
            plain.append(a[k]); k += 1
        }
        guard !plain.isEmpty else { return nil }
        if verb == "click" {
            guard plain.count == 1 else { return nil }
            return ("mousedown \(plain[0])", "mouseup \(plain[0])")
        }
        return ("keydown " + plain.joined(separator: " "), "keyup " + plain.reversed().joined(separator: " "))
    }

    /// `-M ctrl -k t -m ctrl` → `-M ctrl -P t` / `-p t -m ctrl`.
    private static func wtype(_ a: [String]) -> (String, String)? {
        var mods: [String] = [], keys: [String] = [], k = 0
        while k < a.count {
            guard k + 1 < a.count else { return nil }
            switch a[k] {
            case "-M": if !mods.contains(a[k + 1]) { mods.append(a[k + 1]) }
            case "-k", "-P": keys.append(a[k + 1])
            case "-m", "-p", "-s", "-d": break
            default: return nil   // literal text can't be held
            }
            k += 2
        }
        guard !mods.isEmpty || !keys.isEmpty else { return nil }
        let down = mods.map { "-M \($0)" } + keys.map { "-P \($0)" }
        let up = keys.reversed().map { "-p \($0)" } + mods.reversed().map { "-m \($0)" }
        return (down.joined(separator: " "), up.joined(separator: " "))
    }
}

/// Buttons that drive the app rather than the host.
enum RemoteAction: String, Codable, CaseIterable, Identifiable {
    case keyboard, fullscreen, touchpad, spacer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .fullscreen: "Fullscreen"
        case .touchpad: "Touchpad"
        case .spacer: "Blank spot"
        }
    }

    var icon: String {
        switch self {
        case .keyboard: "keyboard"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .touchpad: "rectangle.and.hand.point.up.left"
        case .spacer: "square.dashed"
        }
    }
}

struct RemotePage: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var buttons: [Command] = []

    init(name: String) { self.name = name }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Page"
        buttons = (try? c.decode([Command].self, forKey: .buttons)) ?? []
    }
}

/// The fixed buttons and actions. Raw values are the Android enum names, which
/// is how Gson writes the `remoteCommands` map keys.
enum RemoteKey: String, CaseIterable, Codable {
    case UP, RIGHT, DOWN, LEFT, SELECT
    case VOLUME_DOWN, MUTE, VOLUME_UP, BACK, HOME, MENU, PREVIOUS, PLAY_PAUSE, NEXT
    case MOUSE_MOVE, MOUSE_LEFT_CLICK, MOUSE_RIGHT_CLICK, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP
    case MOUSE_RIGHT_DOWN, MOUSE_RIGHT_UP, MOUSE_PAN_UP, MOUSE_PAN_DOWN, MOUSE_PAN_LEFT, MOUSE_PAN_RIGHT
    case KEYBOARD_TYPE_INPUT, KEYBOARD_KEY_INPUT, KEYBOARD_KEY_DOWN, KEYBOARD_KEY_UP
    case SHARE_TEXT

    var title: String {
        switch self {
        case .UP: "Up"
        case .RIGHT: "Right"
        case .DOWN: "Down"
        case .LEFT: "Left"
        case .SELECT: "Select"
        case .VOLUME_DOWN: "Volume down"
        case .MUTE: "Mute"
        case .VOLUME_UP: "Volume up"
        case .BACK: "Back"
        case .HOME: "Home"
        case .MENU: "Menu"
        case .PREVIOUS: "Previous"
        case .PLAY_PAUSE: "Play/Pause"
        case .NEXT: "Next"
        case .MOUSE_MOVE: "Mouse move (%dx %dy)"
        case .MOUSE_LEFT_CLICK: "Left click"
        case .MOUSE_RIGHT_CLICK: "Right click"
        case .MOUSE_LEFT_DOWN: "Left button down"
        case .MOUSE_LEFT_UP: "Left button up"
        case .MOUSE_RIGHT_DOWN: "Right button down"
        case .MOUSE_RIGHT_UP: "Right button up"
        case .MOUSE_PAN_UP: "Scroll up"
        case .MOUSE_PAN_DOWN: "Scroll down"
        case .MOUSE_PAN_LEFT: "Scroll left"
        case .MOUSE_PAN_RIGHT: "Scroll right"
        case .KEYBOARD_TYPE_INPUT: "Type text (%s)"
        case .KEYBOARD_KEY_INPUT: "Key press (%s name / %d code)"
        case .KEYBOARD_KEY_DOWN: "Key down"
        case .KEYBOARD_KEY_UP: "Key up"
        case .SHARE_TEXT: "Share text (%s)"
        }
    }

    var icon: String {
        switch self {
        case .UP: "chevron.up"
        case .RIGHT: "chevron.right"
        case .DOWN: "chevron.down"
        case .LEFT: "chevron.left"
        case .SELECT: "circle"
        case .VOLUME_DOWN: "speaker.wave.1.fill"
        case .MUTE: "speaker.slash.fill"
        case .VOLUME_UP: "speaker.wave.3.fill"
        case .BACK: "arrow.uturn.backward"
        case .HOME: "house.fill"
        case .MENU: "line.3.horizontal"
        case .PREVIOUS: "backward.end.fill"
        case .PLAY_PAUSE: "playpause.fill"
        case .NEXT: "forward.end.fill"
        default: "command"
        }
    }

    static let remoteTab: [RemoteKey] = [.VOLUME_DOWN, .MUTE, .VOLUME_UP, .BACK, .HOME, .MENU,
                                         .PREVIOUS, .PLAY_PAUSE, .NEXT]
    static let mouseKeys: [RemoteKey] = [.MOUSE_MOVE, .MOUSE_LEFT_CLICK, .MOUSE_RIGHT_CLICK, .MOUSE_LEFT_DOWN,
                                         .MOUSE_LEFT_UP, .MOUSE_RIGHT_DOWN, .MOUSE_RIGHT_UP, .MOUSE_PAN_UP,
                                         .MOUSE_PAN_DOWN, .MOUSE_PAN_LEFT, .MOUSE_PAN_RIGHT]
    static let keyboardKeys: [RemoteKey] = [.KEYBOARD_TYPE_INPUT, .KEYBOARD_KEY_INPUT, .KEYBOARD_KEY_DOWN,
                                            .KEYBOARD_KEY_UP]
}

enum StartScreen: String, Codable { case REMOTE, MOUSE, KEYBOARD, COMMANDS }

struct Host: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var user: String = ""
    /// Offer this app's key. Android's `allowIdentities`.
    var allowIdentities: Bool = true
    /// Accepted host keys, OpenSSH style: "host keytype base64".
    var knownHosts: [String] = []
    var commands: [Command] = [Command("uptime", name: "Uptime", showOutput: true)]
    var remoteCommands: [String: Command]?
    var remoteCustomButtons: [Command]?
    var customPages: [RemotePage]?
    var startScreen: StartScreen?
    /// Tab order by `RemoteTab.key`. iOS-only; Android ignores unknown keys.
    var tabOrder: [String]?
    /// Built-in tabs the user removed — restorable from Edit host → Tabs.
    var hiddenTabs: [String]?

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        hostname = (try? c.decode(String.self, forKey: .hostname)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 22
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        allowIdentities = (try? c.decode(Bool.self, forKey: .allowIdentities)) ?? true
        knownHosts = (try? c.decode([String].self, forKey: .knownHosts)) ?? []
        commands = (try? c.decode([Command].self, forKey: .commands)) ?? []
        remoteCommands = try? c.decode([String: Command].self, forKey: .remoteCommands)
        remoteCustomButtons = try? c.decode([Command].self, forKey: .remoteCustomButtons)
        customPages = try? c.decode([RemotePage].self, forKey: .customPages)
        startScreen = try? c.decode(StartScreen.self, forKey: .startScreen)
        tabOrder = try? c.decode([String].self, forKey: .tabOrder)
        hiddenTabs = try? c.decode([String].self, forKey: .hiddenTabs)
    }

    var title: String { name.isBlank ? "\(user)@\(hostname)" : name }

    func command(_ key: RemoteKey) -> Command? {
        remoteCommands?[key.rawValue].flatMap { $0.hasTap || $0.usesPressRelease ? $0 : nil }
    }

    mutating func setCommand(_ key: RemoteKey, _ cmd: Command?) {
        var m = remoteCommands ?? [:]
        m[key.rawValue] = cmd
        remoteCommands = m
    }

    /// Is `key` (offered by the server for this host) already trusted?
    func trusts(_ keyIdentity: String) -> Bool {
        knownHosts.contains { line in
            let parts = line.split(separator: " ")
            // "host type base64" (known_hosts) or "type base64" (bare key).
            let pair = parts.count >= 3 ? parts[1...2] : parts[...]
            return pair.joined(separator: " ") == keyIdentity
        }
    }

    /// The same host name with a *different* key on file = possible MITM.
    var hasKnownHostKey: Bool { !knownHosts.isEmpty }
}

/// Built-in tabs first, then the user's custom pages — unless `tabOrder`
/// says otherwise.
enum RemoteTab: Hashable {
    case remote, mouse, keyboard, commands, files
    case page(String)

    static let builtIns: [RemoteTab] = [.remote, .mouse, .keyboard, .commands, .files]

    /// Stable id for `Host.tabOrder` / `hiddenTabs`; a page's key is its UUID.
    var key: String {
        switch self {
        case .remote: "remote"
        case .mouse: "mouse"
        case .keyboard: "keyboard"
        case .commands: "commands"
        case .files: "files"
        case .page(let id): id
        }
    }

    var isBuiltIn: Bool { if case .page = self { false } else { true } }
}

extension Host {
    /// Every tab in display order, hidden ones included.
    var orderedTabs: [RemoteTab] {
        let all = RemoteTab.builtIns + (customPages ?? []).map { .page($0.id) }
        let ranked = (tabOrder ?? []).compactMap { k in all.first { $0.key == k } }
        return ranked + all.filter { !ranked.contains($0) }
    }

    var visibleTabs: [RemoteTab] {
        let hidden = hiddenTabs ?? []
        return orderedTabs.filter { !hidden.contains($0.key) }
    }

    var hiddenBuiltInTabs: [RemoteTab] {
        RemoteTab.builtIns.filter { (hiddenTabs ?? []).contains($0.key) }
    }

    func tabTitle(_ t: RemoteTab) -> String {
        switch t {
        case .remote: "Remote"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        case .commands: "Commands"
        case .files: "Files"
        case .page(let id): customPages?.first { $0.id == id }?.name ?? "Page"
        }
    }

    mutating func moveTabs(fromOffsets from: IndexSet, toOffset to: Int) {
        var visible = visibleTabs
        visible.move(fromOffsets: from, toOffset: to)
        tabOrder = (visible + orderedTabs.filter { !visible.contains($0) }).map(\.key)
    }

    /// Built-ins are hidden (restorable); a custom page is deleted with its buttons.
    mutating func removeTab(_ t: RemoteTab) {
        guard visibleTabs.count > 1 else { return }
        if case .page(let id) = t {
            customPages?.removeAll { $0.id == id }
        } else if !(hiddenTabs ?? []).contains(t.key) {
            hiddenTabs = (hiddenTabs ?? []) + [t.key]
        }
    }

    /// Copies any tab into a new custom page right after it. Built-in tabs
    /// become an ordinary, editable grid of the same buttons.
    @discardableResult
    mutating func duplicateTab(_ t: RemoteTab) -> RemotePage {
        var page = RemotePage(name: "\(tabTitle(t)) copy")
        page.buttons = duplicatedButtons(t)
        let visible = visibleTabs
        customPages = (customPages ?? []) + [page]
        var order = visible
        order.insert(.page(page.id), at: (order.firstIndex(of: t) ?? order.count - 1) + 1)
        tabOrder = (order + orderedTabs.filter { !order.contains($0) }).map(\.key)
        return page
    }

    private func duplicatedButtons(_ t: RemoteTab) -> [Command] {
        func key(_ k: RemoteKey, _ label: String) -> Command {
            var c = command(k) ?? Command()
            c.id = UUID().uuidString
            if (c.name ?? "").isBlank { c.name = label }
            return c
        }
        let blank = { Command(action: .spacer) }
        switch t {
        case .remote:
            return [blank(), key(.UP, "▲"), blank(),
                    key(.LEFT, "◀"), key(.SELECT, "OK"), key(.RIGHT, "▶"),
                    blank(), key(.DOWN, "▼"), blank(),
                    key(.VOLUME_DOWN, "Vol −"), key(.MUTE, "Mute"), key(.VOLUME_UP, "Vol +"),
                    key(.BACK, "Back"), key(.HOME, "Home"), key(.MENU, "Menu"),
                    key(.PREVIOUS, "⏮"), key(.PLAY_PAUSE, "⏯"), key(.NEXT, "⏭")]
                + (remoteCustomButtons ?? []).map(\.copied)
        case .mouse:
            return [Command(action: .touchpad), key(.MOUSE_LEFT_CLICK, "Left"), blank(), key(.MOUSE_RIGHT_CLICK, "Right")]
        case .keyboard:
            let template = command(.KEYBOARD_KEY_INPUT)?.command ?? ""
            return [Command(action: .keyboard)] + SpecialKey.all.map { k in
                let cmd = template.contains("%d") ? template.replacingOccurrences(of: "%d", with: String(k.code))
                                                  : template.replacingOccurrences(of: "%s", with: k.name)
                return Command(cmd.isBlank ? nil : cmd, name: k.label)
            }
        case .commands:
            return commands.map(\.copied)
        case .files:
            return []
        case .page(let id):
            return (customPages?.first { $0.id == id }?.buttons ?? []).map(\.copied)
        }
    }

    mutating func restoreTab(_ t: RemoteTab) {
        hiddenTabs?.removeAll { $0 == t.key }
        if hiddenTabs?.isEmpty == true { hiddenTabs = nil }
    }
}

/// Command templates for the common Linux input tools, straight from the
/// Android app's presets.
enum Preset: String, CaseIterable, Identifiable {
    case ydotool, wtype, xdotool
    var id: String { rawValue }

    var commands: [RemoteKey: Command] {
        switch self {
        case .ydotool: [
            .UP: Command("ydotool key 103:1 103:0", repeat: true),
            .RIGHT: Command("ydotool key 106:1 106:0", repeat: true),
            .DOWN: Command("ydotool key 108:1 108:0", repeat: true),
            .LEFT: Command("ydotool key 105:1 105:0", repeat: true),
            .SELECT: Command("ydotool key 28:1 28:0"),
            .VOLUME_DOWN: Command("ydotool key 114:1 114:0", repeat: true),
            .MUTE: Command("ydotool key 113:1 113:0"),
            .VOLUME_UP: Command("ydotool key 115:1 115:0", repeat: true),
            .BACK: Command("ydotool key 158:1 158:0"),
            .HOME: Command("ydotool key 172:1 172:0"),
            .MENU: Command("ydotool key 139:1 139:0"),
            .PREVIOUS: Command("ydotool key 165:1 165:0"),
            .PLAY_PAUSE: Command("ydotool key 164:1 164:0"),
            .NEXT: Command("ydotool key 163:1 163:0"),
            .MOUSE_MOVE: Command("ydotool mousemove -- %dx %dy"),
            .MOUSE_LEFT_CLICK: Command("ydotool click 0xC0"),
            .MOUSE_RIGHT_CLICK: Command("ydotool click 0xC1"),
            .MOUSE_LEFT_DOWN: Command("ydotool click 0x40"),
            .MOUSE_LEFT_UP: Command("ydotool click 0x80"),
            .MOUSE_RIGHT_DOWN: Command("ydotool click 0x41"),
            .MOUSE_RIGHT_UP: Command("ydotool click 0x81"),
            .MOUSE_PAN_UP: Command("ydotool mousemove --wheel -- 0 -1"),
            .MOUSE_PAN_DOWN: Command("ydotool mousemove --wheel -- 0 1"),
            .MOUSE_PAN_LEFT: Command("ydotool mousemove --wheel -- 1 0"),
            .MOUSE_PAN_RIGHT: Command("ydotool mousemove --wheel -- -1 0"),
            .KEYBOARD_TYPE_INPUT: Command("ydotool type '%s'"),
            .KEYBOARD_KEY_INPUT: Command("ydotool key %d:1 %d:0"),
            .KEYBOARD_KEY_DOWN: Command("ydotool key %d:1"),
            .KEYBOARD_KEY_UP: Command("ydotool key %d:0"),
        ]
        case .wtype: [
            .UP: Command("wtype -k Up", repeat: true),
            .RIGHT: Command("wtype -k Right", repeat: true),
            .DOWN: Command("wtype -k Down", repeat: true),
            .LEFT: Command("wtype -k Left", repeat: true),
            .SELECT: Command("wtype -k return"),
            .VOLUME_DOWN: Command("wtype -k XF86AudioLowerVolume", repeat: true),
            .MUTE: Command("wtype -k XF86AudioMute"),
            .VOLUME_UP: Command("wtype -k XF86AudioRaiseVolume", repeat: true),
            .BACK: Command("wtype -k XF86Back"),
            .HOME: Command("wtype -k Home"),
            .MENU: Command("wtype -k Menu"),
            .PREVIOUS: Command("wtype -k XF86AudioPrev"),
            .PLAY_PAUSE: Command("wtype -k XF86AudioPlay"),
            .NEXT: Command("wtype -k XF86AudioNext"),
            .KEYBOARD_TYPE_INPUT: Command("wtype '%s'"),
            .KEYBOARD_KEY_INPUT: Command("wtype -k %s"),
            .KEYBOARD_KEY_DOWN: Command("wtype -P %s"),
            .KEYBOARD_KEY_UP: Command("wtype -p %s"),
        ]
        case .xdotool: [
            .UP: Command("DISPLAY=:0 xdotool key Up", repeat: true),
            .RIGHT: Command("DISPLAY=:0 xdotool key Right", repeat: true),
            .DOWN: Command("DISPLAY=:0 xdotool key Down", repeat: true),
            .LEFT: Command("DISPLAY=:0 xdotool key Left", repeat: true),
            .SELECT: Command("DISPLAY=:0 xdotool key return"),
            .VOLUME_DOWN: Command("DISPLAY=:0 xdotool key XF86AudioLowerVolume", repeat: true),
            .MUTE: Command("DISPLAY=:0 xdotool key XF86AudioMute"),
            .VOLUME_UP: Command("DISPLAY=:0 xdotool key XF86AudioRaiseVolume", repeat: true),
            .BACK: Command("DISPLAY=:0 xdotool key XF86Back"),
            .HOME: Command("DISPLAY=:0 xdotool key Home"),
            .MENU: Command("DISPLAY=:0 xdotool key Menu"),
            .PREVIOUS: Command("DISPLAY=:0 xdotool key XF86AudioPrev"),
            .PLAY_PAUSE: Command("DISPLAY=:0 xdotool key XF86AudioPlay"),
            .NEXT: Command("DISPLAY=:0 xdotool key XF86AudioNext"),
            .MOUSE_MOVE: Command("DISPLAY=:0 xdotool mousemove_relative -- %dx %dy"),
            .MOUSE_LEFT_CLICK: Command("DISPLAY=:0 xdotool click 1"),
            .MOUSE_RIGHT_CLICK: Command("DISPLAY=:0 xdotool click 3"),
            .MOUSE_LEFT_DOWN: Command("DISPLAY=:0 xdotool mousedown 1"),
            .MOUSE_LEFT_UP: Command("DISPLAY=:0 xdotool mouseup 1"),
            .MOUSE_RIGHT_DOWN: Command("DISPLAY=:0 xdotool mousedown 3"),
            .MOUSE_RIGHT_UP: Command("DISPLAY=:0 xdotool mouseup 3"),
            .MOUSE_PAN_UP: Command("DISPLAY=:0 xdotool click 5"),
            .MOUSE_PAN_DOWN: Command("DISPLAY=:0 xdotool click 4"),
            .MOUSE_PAN_LEFT: Command("DISPLAY=:0 xdotool click 7"),
            .MOUSE_PAN_RIGHT: Command("DISPLAY=:0 xdotool click 6"),
            .KEYBOARD_TYPE_INPUT: Command("DISPLAY=:0 xdotool type '%s'"),
            .KEYBOARD_KEY_INPUT: Command("DISPLAY=:0 xdotool key %s"),
            .KEYBOARD_KEY_DOWN: Command("DISPLAY=:0 xdotool keydown %s"),
            .KEYBOARD_KEY_UP: Command("DISPLAY=:0 xdotool keyup %s"),
        ]
        }
    }
}

/// A special key for the Keyboard tab: its X keysym name (wtype/xdotool `%s`)
/// and its Linux input code (ydotool `%d`).
struct SpecialKey: Identifiable {
    let label: String
    let name: String
    let code: Int
    var id: String { name }

    static func named(_ name: String) -> SpecialKey {
        all.first { $0.name == name } ?? .init(label: name, name: name, code: 0)
    }

    static let all: [SpecialKey] = [
        .init(label: "Esc", name: "Escape", code: 1),
        .init(label: "Tab", name: "Tab", code: 15),
        .init(label: "⌫", name: "BackSpace", code: 14),
        .init(label: "⏎", name: "Return", code: 28),
        .init(label: "Del", name: "Delete", code: 111),
        .init(label: "Space", name: "space", code: 57),
        .init(label: "Home", name: "Home", code: 102),
        .init(label: "End", name: "End", code: 107),
        .init(label: "PgUp", name: "Prior", code: 104),
        .init(label: "PgDn", name: "Next", code: 109),
        .init(label: "←", name: "Left", code: 105),
        .init(label: "↑", name: "Up", code: 103),
        .init(label: "↓", name: "Down", code: 108),
        .init(label: "→", name: "Right", code: 106),
        .init(label: "F5", name: "F5", code: 63),
        .init(label: "F11", name: "F11", code: 87),
    ]
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// ── import ───────────────────────────────────────────────────────────────────

/// The Android app's export: plain JSON, or base64 of its gzip (the "export
/// to string" / QR form).
struct ExportedSettings: Decodable {
    var hosts: [Host]?
    var knownHosts: [ExportedKnownHost]?

    struct ExportedKnownHost: Decodable {
        var line: String
    }

    static func parse(_ raw: String) throws -> ExportedSettings {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if !text.hasPrefix("{"),
           let compressed = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
           let json = gunzip(compressed) {
            text = String(decoding: json, as: UTF8.self)
        }
        guard let data = text.data(using: .utf8),
              let s = try? JSONDecoder().decode(ExportedSettings.self, from: data), s.hosts != nil else {
            throw SSHError(message: "That isn't an SSH Remote settings export.")
        }
        return s
    }

    /// gzip = 10-byte header (+ optional fields) + raw DEFLATE + 8-byte trailer.
    /// Apple's `.zlib` algorithm is raw DEFLATE, so strip the wrapper.
    private static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}
