import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers

/// What an action button (Keyboard / Fullscreen) does — set by RemoteView,
/// which owns that state.
private struct RemoteActionKey: EnvironmentKey {
    static let defaultValue: (RemoteAction) -> Void = { _ in }
}

extension EnvironmentValues {
    var remoteAction: (RemoteAction) -> Void {
        get { self[RemoteActionKey.self] }
        set { self[RemoteActionKey.self] = newValue }
    }
}

struct RemoteView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    @State private var tab: RemoteTab = .remote
    @State private var editMode = false
    @State private var editingHost: Host?
    @State private var arrangingTabs: Host?
    @State private var pagePrompt: PagePrompt?
    @State private var pageToDelete: String?
    @State private var fullscreen = false
    @State private var keyboardUp = false

    private var host: Host? { model.host(hostId) }

    var body: some View {
        if let host {
            VStack(spacing: 0) {
                if !fullscreen {
                    statusBar(host)
                    tabBar(host)
                    Divider()
                }
                Group {
                    switch tab {
                    case .remote: RemoteTabView(hostId: hostId, editMode: editMode)
                    case .mouse: MouseTabView(hostId: hostId)
                    case .keyboard: KeyboardTabView(hostId: hostId)
                    case .commands: CommandsTabView(hostId: hostId, editMode: editMode)
                    case .files: FilesTabView(hostId: hostId)
                    case .page(let id): CustomPageView(hostId: hostId, pageId: id, editMode: editMode)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .background(Color.black)
            .background {
                DirectKeyboard(isActive: $keyboardUp) { model.direct($0, on: hostId) }
                    .frame(width: 1, height: 1).opacity(0)
            }
            .overlay { if fullscreen { fullscreenControls(host) } }
            .environment(\.remoteAction) { perform($0) }
            .navigationTitle(host.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(fullscreen)
            .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
            .toolbar { toolbar(host) }
            .task {
                let start: RemoteTab = switch host.startScreen {
                case .MOUSE: .mouse
                case .KEYBOARD: .keyboard
                case .COMMANDS: .commands
                default: .remote
                }
                let tabs = host.visibleTabs
                tab = tabs.contains(start) ? start : (tabs.first ?? .remote)
            }
            .onAppear { model.watch(hostId) }
            .onDisappear { model.unwatch(hostId) }
            // The current tab was removed (here, or from Edit host → Tabs).
            .onChange(of: host.visibleTabs) { _, tabs in
                if !tabs.contains(tab) { tab = tabs.first ?? .remote }
            }
            .sheet(item: $editingHost) { HostEditView(host: $0) }
            .sheet(item: $arrangingTabs) { ArrangeTabsSheet(host: $0) }
            .alert(pagePrompt?.title ?? "", isPresented: Binding(get: { pagePrompt != nil },
                                                                 set: { if !$0 { pagePrompt = nil } })) {
                TextField("Page name", text: Binding(get: { pagePrompt?.name ?? "" }, set: { pagePrompt?.name = $0 }))
                Button("Cancel", role: .cancel) { pagePrompt = nil }
                Button("Save") { commitPage() }
            }
            .confirmationDialog("Delete this page and its buttons?",
                                isPresented: Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete page", role: .destructive) { if let id = pageToDelete { removeTab(.page(id)) } }
            }
        } else {
            Text("Host not found").foregroundStyle(.secondary)
        }
    }

    private func perform(_ action: RemoteAction) {
        switch action {
        case .keyboard: keyboardUp.toggle()
        case .fullscreen: withAnimation { fullscreen.toggle() }
        case .touchpad, .spacer: break  // drawn, never tapped
        }
    }

    // ── chrome ───────────────────────────────────────────────────────────────
    private func statusBar(_ host: Host) -> some View {
        let s = model.state(of: hostId)
        return HStack(spacing: 8) {
            switch s {
            case .connected:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Connected").foregroundStyle(.secondary)
            case .connecting:
                ProgressView().scaleEffect(0.6)
                Text("Connecting…").foregroundStyle(.secondary)
            case .disconnected:
                Circle().fill(.gray).frame(width: 7, height: 7)
                Text("Disconnected").foregroundStyle(.secondary)
            case .failed(let why):
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(why).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if s != .connected && s != .connecting {
                Button("Connect") { model.userConnect(hostId) }.font(.caption.bold())
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.surface)
    }

    private func tabBar(_ host: Host) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(host.visibleTabs, id: \.self) { t in tabButton(host, t) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func tabButton(_ host: Host, _ t: RemoteTab) -> some View {
        Button { tab = t } label: {
            Text(host.tabTitle(t)).font(.subheadline.weight(tab == t ? .bold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(tab == t ? Theme.purple : Theme.panel, in: Capsule())
                .foregroundStyle(.white)
        }
        .contextMenu {
            Button { arrangingTabs = host } label: { Label("Arrange tabs…", systemImage: "arrow.left.arrow.right") }
            if editMode && t != .files {
                Button { duplicateTab(t) } label: { Label("Duplicate as new page", systemImage: "plus.square.on.square") }
            }
            if case .page(let id) = t {
                Button { pagePrompt = PagePrompt(title: "Rename page", name: host.tabTitle(t), pageId: id) } label: {
                    Label("Rename page", systemImage: "pencil")
                }
            }
            if host.visibleTabs.count > 1 {
                if case .page(let id) = t {
                    Button(role: .destructive) { pageToDelete = id } label: { Label("Delete page", systemImage: "trash") }
                } else {
                    Button(role: .destructive) { removeTab(t) } label: { Label("Remove tab", systemImage: "minus.circle") }
                }
            }
        }
    }

    /// Fullscreen hides every bar; these two sit in the top corner, beside
    /// the Dynamic Island, where the status bar was.
    private func fullscreenControls(_ host: Host) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(host.visibleTabs, id: \.self) { t in
                    Button { tab = t } label: {
                        if tab == t { Label(host.tabTitle(t), systemImage: "checkmark") } else { Text(host.tabTitle(t)) }
                    }
                }
                Divider()
                Button { keyboardUp.toggle() } label: { Label(keyboardUp ? "Hide keyboard" : "Keyboard", systemImage: "keyboard") }
                Button { withAnimation { editMode.toggle() } } label: {
                    Label(editMode ? "Done editing" : "Edit", systemImage: "pencil")
                }
            } label: { cornerIcon("ellipsis") }
            Button { withAnimation { fullscreen = false } } label: { cornerIcon("arrow.down.right.and.arrow.up.left") }
        }
        .padding(.trailing, 14)
        .padding(.top, Self.topInset > 30 ? 12 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .ignoresSafeArea(edges: .top)
    }

    private func cornerIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(Theme.panel.opacity(0.85), in: Circle())
            .foregroundStyle(.white.opacity(0.8))
    }

    private static var topInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
    }

    @ToolbarContentBuilder
    private func toolbar(_ host: Host) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { withAnimation { fullscreen = true } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode ? "Done" : "Edit") { withAnimation { editMode.toggle() } }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { pagePrompt = PagePrompt(title: "Add page", name: "", pageId: nil) } label: {
                    Label("Add page", systemImage: "plus.rectangle.on.rectangle")
                }
                if case .page(let id) = tab, let p = host.customPages?.first(where: { $0.id == id }) {
                    Button { pagePrompt = PagePrompt(title: "Rename page", name: p.name, pageId: id) } label: {
                        Label("Rename page", systemImage: "pencil")
                    }
                }
                Button { arrangingTabs = host } label: { Label("Arrange tabs…", systemImage: "arrow.left.arrow.right") }
                Button { keyboardUp.toggle() } label: { Label("Keyboard", systemImage: "keyboard") }
                Divider()
                Button { editingHost = host } label: { Label("Edit host & commands", systemImage: "slider.horizontal.3") }
                Button { installKey() } label: { Label("Install key on host", systemImage: "key") }
                Button {
                    Task { await model.disconnect(hostId); model.userConnect(hostId) }
                } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // ── pages ────────────────────────────────────────────────────────────────
    private func commitPage() {
        guard var h = host, let p = pagePrompt else { return }
        let name = p.name.trimmingCharacters(in: .whitespaces)
        pagePrompt = nil
        guard !name.isEmpty else { return }
        var pages = h.customPages ?? []
        if let id = p.pageId, let i = pages.firstIndex(where: { $0.id == id }) {
            pages[i].name = name
        } else {
            let page = RemotePage(name: name)
            pages.append(page)
            tab = .page(page.id)
            editMode = true
        }
        h.customPages = pages
        model.update(h)
    }

    private func duplicateTab(_ t: RemoteTab) {
        guard var h = host else { return }
        let page = h.duplicateTab(t)
        model.update(h)
        tab = .page(page.id)
        model.toast = "Made \"\(page.name)\" — long-press its tab to rename"
    }

    private func removeTab(_ t: RemoteTab) {
        guard var h = host else { return }
        h.removeTab(t)
        model.update(h)
    }

    /// Appends this device's key to ~/.ssh/authorized_keys, once. Needs a
    /// working login already (normally the password).
    private func installKey() {
        let line = Store.publicKeyLine
        let q = "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "(grep -qxF \(q) ~/.ssh/authorized_keys || echo \(q) >> ~/.ssh/authorized_keys) && echo installed"
        Task {
            if let r = await model.run(cmd, on: hostId), r.ok {
                model.toast = "Key installed — the password is no longer needed"
            }
        }
    }
}

struct PagePrompt {
    var title: String
    var name: String
    var pageId: String?
}

// ── tabs editor ──────────────────────────────────────────────────────────────

/// Reorder / remove tabs. Built-ins are hidden (and listed under "Removed
/// tabs" to add back); custom pages are deleted with their buttons.
struct TabsEditor: View {
    @Binding var host: Host

    var body: some View {
        List {
            Section {
                ForEach(host.visibleTabs, id: \.self) { t in
                    Label(host.tabTitle(t), systemImage: t.icon)
                        .deleteDisabled(host.visibleTabs.count <= 1)
                }
                .onMove { host.moveTabs(fromOffsets: $0, toOffset: $1) }
                .onDelete { idx in
                    let tabs = host.visibleTabs
                    for i in idx { host.removeTab(tabs[i]) }
                }
            } footer: {
                Text("Drag to reorder. Removing a built-in tab hides it — add it back below. Deleting a custom page deletes its buttons.")
            }
            if !host.hiddenBuiltInTabs.isEmpty {
                Section("Removed tabs") {
                    ForEach(host.hiddenBuiltInTabs, id: \.self) { t in
                        Button { withAnimation { host.restoreTab(t) } } label: {
                            Label("Add \(host.tabTitle(t))", systemImage: "plus.circle.fill")
                        }
                        .moveDisabled(true).deleteDisabled(true)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tabs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The ⋯ / long-press "Arrange tabs" sheet. Cancel throws the edits away.
private struct ArrangeTabsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: Host

    init(host: Host) { _draft = State(initialValue: host) }

    var body: some View {
        NavigationStack {
            TabsEditor(host: $draft)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if var h = model.host(draft.id) {
                                h.tabOrder = draft.tabOrder
                                h.hiddenTabs = draft.hiddenTabs
                                h.customPages = draft.customPages
                                model.update(h)
                            }
                            dismiss()
                        }
                    }
                }
        }
    }
}

extension RemoteTab {
    var icon: String {
        switch self {
        case .remote: "av.remote"
        case .mouse: "cursorarrow"
        case .keyboard: "keyboard"
        case .commands: "terminal"
        case .files: "folder"
        case .page: "square.grid.2x2"
        }
    }
}

// ── direct keyboard ──────────────────────────────────────────────────────────

/// An invisible first responder: the system keyboard types straight into the
/// host, one keystroke at a time, with no text field in between.
struct DirectKeyboard: UIViewRepresentable {
    @Binding var isActive: Bool
    let send: (AppModel.DirectInput) -> Void

    func makeUIView(context: Context) -> KeyCatcher { KeyCatcher() }

    func updateUIView(_ v: KeyCatcher, context: Context) {
        v.send = send
        v.onResign = { if isActive { isActive = false } }
        if isActive != v.isFirstResponder {
            DispatchQueue.main.async {
                if isActive { _ = v.becomeFirstResponder() } else { _ = v.resignFirstResponder() }
            }
        }
    }
}

final class KeyCatcher: UIView, UIKeyInput {
    var send: (AppModel.DirectInput) -> Void = { _ in }
    var onResign: () -> Void = {}

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        if done { onResign() }
        return done
    }

    // Always "has text", so backspace keeps firing on an empty buffer.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { send(.key(.named("Return"))) } else { send(.text(text.asciiPunctuation)) }
    }

    func deleteBackward() { send(.key(.named("BackSpace"))) }

    // Raw keystrokes: nothing may rewrite what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    private lazy var accessory: UIView = {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 4
        for (title, key) in [("Esc", "Escape"), ("Tab", "Tab"), ("←", "Left"), ("↑", "Up"), ("↓", "Down"), ("→", "Right")] {
            bar.addArrangedSubview(accessoryButton(title) { [weak self] in self?.send(.key(.named(key))) })
        }
        bar.addArrangedSubview(accessoryButton(nil, image: "keyboard.chevron.compact.down") { [weak self] in
            _ = self?.resignFirstResponder()
        })
        let wrap = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))
        wrap.backgroundColor = UIColor(white: 0.08, alpha: 1)
        bar.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            bar.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            bar.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        return wrap
    }()

    override var inputAccessoryView: UIView? { accessory }

    private func accessoryButton(_ title: String?, image: String? = nil, action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title
        c.image = image.flatMap { UIImage(systemName: $0) }
        c.baseBackgroundColor = UIColor(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255, alpha: 1)
        c.baseForegroundColor = .white
        c.cornerStyle = .medium
        return UIButton(configuration: c, primaryAction: UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        })
    }
}

// ── buttons ──────────────────────────────────────────────────────────────────

/// A remote button with the Android app's semantics: tap, long-press,
/// repeat-while-held, or a press/release pair.
struct RemoteButton<Label: View>: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.remoteAction) private var remoteAction
    let hostId: String
    let command: Command?
    var editMode = false
    var onEdit: (() -> Void)?
    @ViewBuilder let label: () -> Label

    @State private var pressed = false
    @State private var pressStart = Date()
    @State private var timer: Timer?
    @State private var fired = false
    /// The in-flight press of a held button; its release waits on it, so a
    /// quick tap can't land the key-up before the key-down.
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        // A real Button (not a zero-distance DragGesture) so a swipe that
        // starts on a button still scrolls the page: the ScrollView cancels
        // the press and `tapped` never runs.
        Button(action: tapped) {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // An unassigned button is see-through: just a faint glyph.
                .background(pressed ? Theme.purple.opacity(0.75) : (command == nil && !editMode ? Color.clear : Theme.purple),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if editMode {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .foregroundStyle(command == nil && !editMode ? Color.white.opacity(0.15) : .white)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressReportingStyle { $0 ? down() : up() })
        // Leaving the page mid-hold must still let go of the key.
        .onDisappear { up() }
    }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    private func down() {
        guard !pressed else { return }
        pressed = true
        pressStart = Date()
        fired = false
        if editMode { return }
        guard let c = command else { return }
        haptic()
        if c.action != nil { return }
        if let pair = c.holdPair {
            holdTask = Task { await model.run(pair.down, on: hostId) }
            return
        }
        if c.repeats {
            fire(c)
            // Android's cadence: a pause, then a steady repeat.
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                Task { @MainActor in
                    timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                        Task { @MainActor in fire(c) }
                    }
                }
            }
        } else if c.hasLongPress {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                Task { @MainActor in
                    fired = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await model.run(c.longPressCommand ?? "", on: hostId, title: c.displayText,
                                           showOutput: c.wantsOutput, notifying: c) }
                }
            }
        }
    }

    /// Finger lifted *or* the press was cancelled by a scroll.
    private func up() {
        guard pressed else { return }
        pressed = false
        timer?.invalidate()
        timer = nil
        if editMode { return }
        if let c = command, let pair = c.holdPair {
            let press = holdTask
            holdTask = Task {
                await press?.value
                await model.run(pair.up, on: hostId)
            }
        }
    }

    /// Only a completed tap — never a touch that turned into a scroll.
    private func tapped() {
        if editMode { onEdit?(); return }
        if let a = command?.action { remoteAction(a); return }
        guard let c = command, c.holdPair == nil, !c.repeats, !fired else { return }
        fire(c)
    }

    private func fire(_ c: Command) {
        Task { await model.run(c, on: hostId) }
    }
}

/// Reports press/release (including a scroll cancelling the press) without
/// drawing anything — RemoteButton draws its own pressed state.
private struct PressReportingStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in onPressChange(isPressed) }
    }
}

/// Custom-button grid: 3 per row, a "+" tile in edit mode. A touchpad takes
/// a whole row of its own.
struct ButtonGrid: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    let buttons: [Command]
    let editMode: Bool
    let onChange: ([Command]) -> Void
    @State private var editing: EditTarget?
    @State private var editingAction: Int?
    /// The button being dragged in edit mode (its Command id).
    @State private var dragging: String?

    struct EditTarget: Identifiable {
        let id = UUID()
        let index: Int?
        let command: Command
        /// A new button goes here instead of the end.
        var insertAt: Int? = nil
    }

    private enum Item: Identifiable {
        case button(Int, Command)
        case add
        var id: String {
            switch self {
            case .button(_, let c): c.id
            case .add: "+"
            }
        }
        var isWide: Bool { if case .button(_, let c) = self { c.action == .touchpad } else { false } }
    }

    private struct Row: Identifiable {
        var items: [Item]
        var id: String { items.map(\.id).joined(separator: "|") }
    }

    private var rows: [Row] {
        var items = buttons.enumerated().map { Item.button($0.offset, $0.element) }
        if editMode { items.append(.add) }
        var rows: [Row] = []
        var current: [Item] = []
        for item in items {
            if item.isWide {
                if !current.isEmpty { rows.append(Row(items: current)); current = [] }
                rows.append(Row(items: [item]))
            } else {
                current.append(item)
                if current.count == 3 { rows.append(Row(items: current)); current = [] }
            }
        }
        if !current.isEmpty { rows.append(Row(items: current)) }
        return rows
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                if row.items.count == 1, row.items[0].isWide, case .button(let i, let b) = row.items[0] {
                    touchpad(i, b)
                } else {
                    HStack(spacing: 10) {
                        ForEach(row.items) { cell($0) }
                        // Keep a short last row on the same 3-column grid.
                        ForEach(row.items.count..<3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                    .frame(height: 56)
                }
            }
        }
        .sheet(item: $editing) { t in
            CommandEditor(title: t.index == nil ? "New button" : "Edit button", command: t.command,
                          pressRelease: true,
                          onDelete: t.index.map { i in { remove(i) } }) { cmd in
                var list = buttons
                if let i = t.index {
                    if let cmd { list[i] = cmd } else { list.remove(at: i) }
                } else if let cmd {
                    list.insert(cmd, at: min(t.insertAt ?? list.count, list.count))
                }
                onChange(list)
            }
        }
        .onChange(of: editMode) { _, _ in dragging = nil }
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
        .confirmationDialog(editingActionTitle,
                            isPresented: Binding(get: { editingAction != nil }, set: { if !$0 { editingAction = nil } }),
                            titleVisibility: .visible) {
            if let i = editingAction, buttons.indices.contains(i) {
                if buttons[i].action == .touchpad {
                    ForEach(TouchpadSize.allCases) { size in
                        Button(size.title) { var l = buttons; l[i].padHeight = size.height; onChange(l) }
                    }
                }
                ForEach(ButtonKind.all.filter { $0 != ButtonKind(buttons[i]) }) { k in
                    Button("Change to \(k.title)") { change(i, to: k) }
                }
                Button("Delete", role: .destructive) { remove(i) }
            }
        }
    }

    /// Every kind of grid button, as offered by "+", Insert before and Change type.
    struct ButtonKind: Hashable, Identifiable {
        let action: RemoteAction?
        var id: String { action?.rawValue ?? "command" }
        var title: String { action.map { $0.title } ?? "Command button" }
        var icon: String { action?.icon ?? "terminal" }
        static let all = [ButtonKind(action: nil)] + RemoteAction.allCases.map { ButtonKind(action: $0) }
        init(action: RemoteAction?) { self.action = action }
        init(_ c: Command) { action = c.action }
    }

    @ViewBuilder
    private func kindButtons(except: ButtonKind? = nil, _ pick: @escaping (ButtonKind) -> Void) -> some View {
        ForEach(ButtonKind.all.filter { $0 != except }) { k in
            Button { pick(k) } label: { Label(k.title, systemImage: k.icon) }
        }
    }

    /// New button of kind `k` at `index` (the end when nil). A command
    /// button opens the editor first; cancelling it adds nothing.
    private func insert(_ k: ButtonKind, at index: Int?) {
        let at = min(index ?? buttons.count, buttons.count)
        if let a = k.action {
            var l = buttons
            l.insert(Command(action: a), at: at)
            onChange(l)
        } else {
            editing = EditTarget(index: nil, command: Command(), insertAt: at)
        }
    }

    /// Swap button `i` for kind `k` in the same slot. To a command button,
    /// the editor opens and the old button stays until Save.
    private func change(_ i: Int, to k: ButtonKind) {
        if let a = k.action {
            var l = buttons
            l[i] = Command(action: a)
            onChange(l)
        } else {
            editing = EditTarget(index: i, command: Command())
        }
    }

    private var editingActionTitle: String {
        guard let i = editingAction, buttons.indices.contains(i) else { return "" }
        return "\(buttons[i].action?.title ?? "") button"
    }

    private func remove(_ i: Int) {
        var l = buttons
        l.remove(at: i)
        onChange(l)
    }

    private func edit(_ i: Int, _ b: Command) {
        if b.action != nil { editingAction = i } else { editing = EditTarget(index: i, command: b) }
    }

    @ViewBuilder
    private func cell(_ item: Item) -> some View {
        switch item {
        case .button(let i, let b) where b.action == .spacer:
            // Holds a grid slot. Only visible (and deletable/movable) in edit mode.
            if editMode {
                Button { edit(i, b) } label: {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                        .foregroundStyle(.white.opacity(0.3))
                        .overlay { Image(systemName: "square.dashed").foregroundStyle(.white.opacity(0.4)) }
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu { arrangeItems(i, b) }
                .modifier(reorderable(b))
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        case .button(let i, let b):
            RemoteButton(hostId: hostId, command: b, editMode: editMode, onEdit: { edit(i, b) }) {
                if let a = b.action {
                    VStack(spacing: 2) {
                        Image(systemName: a.icon).font(.title3)
                        if !(b.name ?? "").isBlank && b.name != a.title { Text(b.displayText).font(.caption2) }
                    }
                } else {
                    Text(b.displayText).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.center).padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(EditMenu(enabled: editMode) { arrangeItems(i, b) })
                .modifier(reorderable(b))
        case .add:
            Menu {
                if let c = model.copiedButton {
                    Button { paste(c, at: buttons.count) } label: { Label("Paste \"\(c.displayText)\"", systemImage: "doc.on.clipboard") }
                    Divider()
                }
                kindButtons { insert($0, at: nil) }
            } label: {
                Image(systemName: "plus").font(.title2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func reorderable(_ b: Command) -> Reorderable {
        Reorderable(id: b.id, enabled: editMode, buttons: buttons, dragging: $dragging, onChange: onChange)
    }

    @ViewBuilder
    private func arrangeItems(_ i: Int, _ b: Command) -> some View {
        Button { edit(i, b) } label: { Label(b.action == nil ? "Edit" : "Options", systemImage: "pencil") }
        if editMode {
            Button { model.copiedButton = b } label: { Label("Copy", systemImage: "doc.on.doc") }
            if let c = model.copiedButton {
                Button { paste(c, at: i) } label: { Label("Paste before", systemImage: "arrow.left.doc.on.clipboard") }
                Button { paste(c, at: i + 1) } label: { Label("Paste after", systemImage: "doc.on.clipboard") }
            }
            if i > 0 {
                Button { move(i, by: -1) } label: { Label("Move left", systemImage: "arrow.left") }
            }
            if i < buttons.count - 1 {
                Button { move(i, by: 1) } label: { Label("Move right", systemImage: "arrow.right") }
            }
            Menu {
                kindButtons { insert($0, at: i) }
            } label: { Label("Insert before", systemImage: "arrow.left.to.line") }
            Menu {
                kindButtons(except: ButtonKind(b)) { change(i, to: $0) }
            } label: { Label("Change type", systemImage: "arrow.triangle.2.circlepath") }
        }
        Button(role: .destructive) { remove(i) } label: { Label("Delete", systemImage: "trash") }
    }

    private func paste(_ c: Command, at i: Int) {
        var l = buttons
        l.insert(c.copied, at: min(i, l.count))
        onChange(l)
    }

    private func move(_ i: Int, by d: Int) {
        var l = buttons
        l.swapAt(i, i + d)
        onChange(l)
    }

    private func touchpad(_ i: Int, _ b: Command) -> some View {
        TouchpadTile(hostId: hostId)
            .frame(height: b.padHeight ?? TouchpadSize.medium.height)
            .overlay {
                if editMode {
                    // In edit mode the pad is a button: resize or delete.
                    Button { edit(i, b) } label: {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .foregroundStyle(.white.opacity(0.6))
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                            .overlay { Label("Touchpad — tap to resize or delete", systemImage: "pencil").font(.caption) }
                    }
                    .foregroundStyle(.white)
                    .contextMenu { arrangeItems(i, b) }
                .modifier(reorderable(b))
                }
            }
    }
}

/// A long-press menu only while editing. Outside edit mode a hold must be a
/// plain held key (repeat, long-press command, press/release), and any
/// context menu would swallow it.
private struct EditMenu<Items: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        if enabled { content.contextMenu { items() } } else { content }
    }
}

/// Edit-mode drag to reorder: hold a button, drag it, and the others shift
/// into the gap live as it passes over them.
private struct Reorderable: ViewModifier {
    let id: String
    let enabled: Bool
    let buttons: [Command]
    @Binding var dragging: String?
    let onChange: ([Command]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(dragging == id ? 0.35 : 1)
                .onDrag {
                    dragging = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [.text], delegate: Drop(target: id, buttons: buttons, dragging: $dragging, onChange: onChange))
        } else {
            content
        }
    }

    private struct Drop: DropDelegate {
        let target: String
        let buttons: [Command]
        @Binding var dragging: String?
        let onChange: ([Command]) -> Void

        func dropEntered(info: DropInfo) {
            guard let d = dragging, d != target,
                  let from = buttons.firstIndex(where: { $0.id == d }),
                  let to = buttons.firstIndex(where: { $0.id == target }) else { return }
            var l = buttons
            l.insert(l.remove(at: from), at: to)
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) { onChange(l) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }
}

enum TouchpadSize: Double, CaseIterable, Identifiable {
    case small = 160, medium = 240, large = 340, huge = 460
    var id: Double { rawValue }
    var height: Double { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .huge: "Extra large"
        }
    }
}

/// The Mouse tab's trackpad as a tile for any page.
struct TouchpadTile: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    @AppStorage("padHints") private var padHints = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Theme.surface)
            Pad(model: model, hostId: hostId)
            if padHints {
                Text("tap click · two-finger tap right-click · two fingers scroll")
                    .font(.caption2).foregroundStyle(.gray).multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// ── tabs ─────────────────────────────────────────────────────────────────────

struct RemoteTabView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    let editMode: Bool
    @State private var editingKey: RemoteKey?

    var body: some View {
        let host = model.host(hostId)
        ScrollView {
            VStack(spacing: 18) {
                dpad(host)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(RemoteKey.remoteTab) { key in
                        keyButton(host, key) {
                            Image(systemName: key.icon).font(.title3)
                        }
                        .frame(height: 56)
                    }
                }
                ButtonGrid(hostId: hostId, buttons: host?.remoteCustomButtons ?? [], editMode: editMode) { list in
                    guard var h = model.host(hostId) else { return }
                    h.remoteCustomButtons = list
                    model.update(h)
                }
                if editMode {
                    Text("Tap a button to edit it. Hold and drag a custom button to move it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .sheet(item: $editingKey) { key in
            CommandEditor(title: key.title, command: host?.command(key) ?? Command(), pressRelease: true) { cmd in
                guard var h = model.host(hostId) else { return }
                h.setCommand(key, cmd)
                model.update(h)
            }
        }
    }

    private func keyButton<L: View>(_ host: Host?, _ key: RemoteKey, @ViewBuilder label: @escaping () -> L) -> some View {
        RemoteButton(hostId: hostId, command: host?.command(key), editMode: editMode,
                     onEdit: { editingKey = key }, label: label)
    }

    private func dpad(_ host: Host?) -> some View {
        let size: CGFloat = 72
        return VStack(spacing: 8) {
            keyButton(host, .UP) { Image(systemName: "chevron.up").font(.title) }.frame(width: size, height: size)
            HStack(spacing: 8) {
                keyButton(host, .LEFT) { Image(systemName: "chevron.left").font(.title) }.frame(width: size, height: size)
                keyButton(host, .SELECT) { Text("OK").font(.headline) }.frame(width: size, height: size)
                keyButton(host, .RIGHT) { Image(systemName: "chevron.right").font(.title) }.frame(width: size, height: size)
            }
            keyButton(host, .DOWN) { Image(systemName: "chevron.down").font(.title) }.frame(width: size, height: size)
        }
    }
}

struct CustomPageView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    let pageId: String
    let editMode: Bool

    var body: some View {
        let page = model.host(hostId)?.customPages?.first { $0.id == pageId }
        ScrollView {
            VStack(spacing: 12) {
                if (page?.buttons ?? []).isEmpty && !editMode {
                    Text("No buttons yet — tap Edit, then +.").foregroundStyle(.secondary).padding(.top, 40)
                }
                ButtonGrid(hostId: hostId, buttons: page?.buttons ?? [], editMode: editMode) { list in
                    guard var h = model.host(hostId), let i = h.customPages?.firstIndex(where: { $0.id == pageId }) else { return }
                    h.customPages?[i].buttons = list
                    model.update(h)
                }
            }
            .padding(16)
        }
    }
}

struct CommandsTabView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    let editMode: Bool
    @State private var adHoc = ""
    @State private var editing: ButtonGrid.EditTarget?

    var body: some View {
        let cmds = model.host(hostId)?.commands ?? []
        List {
            Section {
                HStack {
                    TextField("Run a command…", text: $adHoc)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(runAdHoc)
                    Button(action: runAdHoc) { Image(systemName: "play.fill") }.disabled(adHoc.isBlank)
                }
            }
            Section {
                ForEach(Array(cmds.enumerated()), id: \.element.id) { i, c in
                    Button {
                        if editMode { editing = .init(index: i, command: c) }
                        else { Task { await model.run(c, on: hostId) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayText).foregroundStyle(.primary)
                            if c.name != nil {
                                Text(c.command ?? "").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { idx in save(cmds.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                .onMove { from, to in var l = cmds; l.move(fromOffsets: from, toOffset: to); save(l) }
                Button { editing = .init(index: nil, command: Command(showOutput: true)) } label: {
                    Label("Add command", systemImage: "plus")
                }
            }
        }
        .environment(\.editMode, .constant(editMode ? .active : .inactive))
        .sheet(item: $editing) { t in
            CommandEditor(title: t.index == nil ? "New command" : "Edit command", command: t.command) { cmd in
                var l = cmds
                if let i = t.index { if let cmd { l[i] = cmd } else { l.remove(at: i) } }
                else if let cmd { l.append(cmd) }
                save(l)
            }
        }
    }

    private func runAdHoc() {
        let c = adHoc
        guard !c.isBlank else { return }
        Task { await model.run(c, on: hostId, title: c, showOutput: true) }
    }

    private func save(_ list: [Command]) {
        guard var h = model.host(hostId) else { return }
        h.commands = list
        model.update(h)
    }
}

struct KeyboardTabView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Type text to send…", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .padding(12)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        // iOS smart punctuation would otherwise send curly quotes.
                        model.type(text.asciiPunctuation, on: hostId)
                        text = ""
                    } label: {
                        Image(systemName: "paperplane.fill").frame(width: 46, height: 46)
                            .background(Theme.purple, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                    .disabled(text.isEmpty)
                }
                Text("KEYS").font(.caption2.bold()).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(SpecialKey.all) { k in
                        Button { model.key(k, on: hostId) } label: {
                            Text(k.label).font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background(Theme.purple, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

extension String {
    /// Undo iOS smart punctuation: curly quotes, long dashes, the ellipsis.
    var asciiPunctuation: String {
        var out = self
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                           ("\u{2013}", "-"), ("\u{2014}", "--"), ("\u{2026}", "...")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }
}

// ── mouse ────────────────────────────────────────────────────────────────────

struct MouseTabView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    @AppStorage("mouseSensitivity") private var sensitivity = 1.5
    @AppStorage("padHints") private var padHints = true

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(String(format: "Speed %.1f×", sensitivity)).font(.caption).foregroundStyle(.secondary)
                Slider(value: $sensitivity, in: 0.5...5, step: 0.1)
            }
            .padding(.horizontal, 16)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Theme.surface)
                Pad(model: model, hostId: hostId)
                if padHints {
                    Text("drag to move · tap to click · two-finger tap right-click · two fingers to scroll")
                        .font(.caption2).foregroundStyle(.gray).multilineTextAlignment(.center)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(10)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            HStack(spacing: 10) {
                RemoteButton(hostId: hostId, command: model.host(hostId)?.command(.MOUSE_LEFT_CLICK)) { Text("Left") }
                RemoteButton(hostId: hostId, command: model.host(hostId)?.command(.MOUSE_RIGHT_CLICK)) { Text("Right") }
            }
            .frame(height: 56)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .padding(.top, 10)
    }
}

private struct Pad: UIViewRepresentable {
    let model: AppModel
    let hostId: String
    @AppStorage("mouseSensitivity") private var sensitivity = 1.5
    @AppStorage("scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage("naturalScrolling") private var naturalScrolling = true

    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.model = model
        v.hostId = hostId
        return v
    }

    func updateUIView(_ v: PadView, context: Context) {
        v.sensitivity = sensitivity
        v.scrollSensitivity = scrollSensitivity
        v.naturalScrolling = naturalScrolling
    }
}

/// Raw touches, like PC Remote's trackpad: move, tap, two-finger tap, and
/// two-finger scroll mapped onto the host's mouse commands.
final class PadView: UIView {
    weak var model: AppModel?
    var hostId = ""
    var sensitivity = 1.5
    /// Wheel clicks per 14 pt of two-finger travel.
    var scrollSensitivity = 1.0
    /// Content follows the fingers (macOS/iOS style); off = classic wheel.
    var naturalScrolling = true

    private var downAt = Date()
    private var moved: CGFloat = 0
    private var maxTouches = 0
    private var scrollAcc: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        // Touches arrive through a recognizer, not touchesBegan: a pad on a
        // scrolling page must claim the drag before the ScrollView does.
        addGestureRecognizer(PadGesture(pad: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    fileprivate func active(_ e: UIEvent?) -> [UITouch] {
        (e?.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    fileprivate func began(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let n = active(event).count
        if n == touches.count { downAt = Date(); moved = 0; maxTouches = 0; scrollAcc = 0 }
        maxTouches = max(maxTouches, n)
    }

    fileprivate func moved(_ event: UIEvent?) {
        let act = active(event)
        maxTouches = max(maxTouches, act.count)
        guard let model, let host = model.host(hostId) else { return }
        if act.count >= 2 {
            let dy = act.map { $0.location(in: self).y - $0.previousLocation(in: self).y }.reduce(0, +) / CGFloat(act.count)
            scrollAcc += dy
            moved += abs(dy)
            let step = 14 / CGFloat(max(scrollSensitivity, 0.1))
            while abs(scrollAcc) >= step {
                let down = scrollAcc > 0
                scrollAcc -= down ? step : -step
                let up = down == naturalScrolling
                if let c = host.command(up ? .MOUSE_PAN_UP : .MOUSE_PAN_DOWN)?.command {
                    Task { await model.run(c, on: hostId) }
                }
            }
        } else if let t = act.first {
            let dx = t.location(in: self).x - t.previousLocation(in: self).x
            let dy = t.location(in: self).y - t.previousLocation(in: self).y
            moved += abs(dx) + abs(dy)
            model.mouseMove(dx: Double(dx) * sensitivity * 2, dy: Double(dy) * sensitivity * 2, on: hostId)
        }
    }

    fileprivate func ended(_ event: UIEvent?) {
        guard active(event).isEmpty, let model, let host = model.host(hostId) else { return }
        guard Date().timeIntervalSince(downAt) < 0.25, moved < 8 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let key: RemoteKey = maxTouches >= 2 ? .MOUSE_RIGHT_CLICK : .MOUSE_LEFT_CLICK
        if let c = host.command(key)?.command { Task { await model.run(c, on: hostId) } }
    }
}

/// Recognises on the first touch and makes an enclosing ScrollView's pan
/// wait for it — so dragging on the pad moves the mouse, never the page.
private final class PadGesture: UIGestureRecognizer {
    private weak var pad: PadView?

    init(pad: PadView) {
        self.pad = pad
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        pad?.began(touches, event)
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        pad?.moved(event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        pad?.ended(event)
        if pad?.active(event).isEmpty ?? true { state = .ended } else { state = .changed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
