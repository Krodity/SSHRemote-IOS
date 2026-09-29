import SwiftUI

struct HostEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var password = ""
    @State private var portText = ""
    @State private var editingKey: RemoteKey?
    @State private var confirmPreset: Preset?

    init(host: Host) {
        _host = State(initialValue: host)
        _password = State(initialValue: Store.password(for: host.id) ?? "")
        _portText = State(initialValue: String(host.port))
    }

    private var isNew: Bool { model.host(host.id) == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                    TextField("User", text: $host.user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("Use this device's key", isOn: $host.allowIdentities)
                    SecureField("Password (optional)", text: $password)
                } header: { Text("Authentication") } footer: {
                    Text("The key is tried first, then the password. The password is stored in the Keychain on this device only.")
                }

                Section {
                    ForEach(RemoteKey.allCases.filter { $0 != .SHARE_TEXT }, id: \.self) { key in
                        Button { editingKey = key } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.title).foregroundStyle(.primary)
                                Text(host.command(key)?.command ?? host.command(key)?.downCommand ?? "not set")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(host.command(key) == nil ? .tertiary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Remote commands")
                        Spacer()
                        Menu("Presets") {
                            ForEach(Preset.allCases) { p in Button(p.rawValue) { confirmPreset = p } }
                        }
                        .font(.caption).textCase(nil)
                    }
                } footer: {
                    Text("ydotool works everywhere (it needs ydotoold). wtype is Wayland-only; xdotool is X11.")
                }

                Section {
                    NavigationLink {
                        TabsEditor(host: $host)
                    } label: {
                        LabeledContent("Arrange tabs", value: "\(host.visibleTabs.count) shown")
                    }
                    ForEach(host.hiddenBuiltInTabs, id: \.self) { t in
                        Button { host.restoreTab(t) } label: {
                            Label("Add back \(host.tabTitle(t))", systemImage: "plus.circle.fill")
                        }
                    }
                } header: { Text("Tabs") } footer: {
                    Text("Reorder or remove tabs. Built-in tabs you remove can be added back here.")
                }

                if !knownHostsEmpty {
                    Section("Trusted host keys") {
                        ForEach(host.knownHosts, id: \.self) { line in
                            Text(line).font(.system(.caption2, design: .monospaced)).lineLimit(2)
                        }
                        .onDelete { host.knownHosts.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle(isNew ? "New host" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(host.hostname.isBlank || host.user.isBlank)
                }
            }
            .sheet(item: $editingKey) { key in
                CommandEditor(title: key.title, command: host.command(key) ?? Command(), pressRelease: true) { cmd in
                    host.setCommand(key, cmd)
                }
            }
            .confirmationDialog("Replace all remote commands with the \(confirmPreset?.rawValue ?? "") preset?",
                                isPresented: Binding(get: { confirmPreset != nil }, set: { if !$0 { confirmPreset = nil } }),
                                titleVisibility: .visible) {
                if let p = confirmPreset {
                    Button("Apply \(p.rawValue)", role: .destructive) {
                        host.remoteCommands = Dictionary(uniqueKeysWithValues: p.commands.map { ($0.key.rawValue, $0.value) })
                    }
                }
            }
            .onAppear {
                // A brand-new host starts with the tool that works on any
                // Linux session, so the remote does something out of the box.
                if isNew && host.remoteCommands == nil {
                    host.remoteCommands = Dictionary(uniqueKeysWithValues: Preset.ydotool.commands.map { ($0.key.rawValue, $0.value) })
                }
            }
        }
    }

    private var knownHostsEmpty: Bool { host.knownHosts.isEmpty }

    private func save() {
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.user = host.user.trimmingCharacters(in: .whitespaces)
        host.port = Int(portText) ?? 22
        let old = model.host(host.id)
        // Anything that changes who/where we connect to invalidates the session.
        if let old, old.hostname != host.hostname || old.port != host.port || old.user != host.user
            || old.allowIdentities != host.allowIdentities || Store.password(for: host.id) != (password.isEmpty ? nil : password) {
            Task { await model.disconnect(host.id) }
        }
        Store.setPassword(password, for: host.id)
        model.update(host)
        dismiss()
    }
}

extension RemoteKey: Identifiable {
    public var id: String { rawValue }
}

/// Edits one button: tap / long-press commands, or press-and-release pair.
struct CommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var command: Command
    var pressRelease = false
    var allowOutput = true
    var onDelete: (() -> Void)?
    let onSave: (Command?) -> Void

    init(title: String, command: Command, pressRelease: Bool = false, allowOutput: Bool = true,
         onDelete: (() -> Void)? = nil, onSave: @escaping (Command?) -> Void) {
        self.title = title
        _command = State(initialValue: command)
        self.pressRelease = pressRelease
        self.allowOutput = allowOutput
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Button label (optional)", text: bind(\.name))
                }
                Section {
                    field("Command", bind(\.command))
                    field("Long-press command (optional)", bind(\.longPressCommand))
                    Toggle("Repeat while held", isOn: flag(\.repeatWhileHeld))
                    if allowOutput { Toggle("Show output", isOn: flag(\.showOutput)) }
                } header: { Text("On tap") }
                if pressRelease {
                    Section {
                        field("On press", bind(\.downCommand))
                        field("On release", bind(\.upCommand))
                    } header: { Text("Press & release (replaces tap)") } footer: {
                        Text("For holding a key or button down, e.g. ydotool key 42:1 / 42:0.")
                    }
                }
                if let onDelete {
                    Section {
                        Button("Delete button", role: .destructive) { onDelete(); dismiss() }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let empty = !command.hasTap && !command.usesPressRelease && !command.hasLongPress
                        onSave(empty ? nil : command)
                        dismiss()
                    }
                }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        TextField(label, text: text, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func bind(_ kp: WritableKeyPath<Command, String?>) -> Binding<String> {
        Binding(get: { command[keyPath: kp] ?? "" },
                set: { command[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func flag(_ kp: WritableKeyPath<Command, Bool?>) -> Binding<Bool> {
        Binding(get: { command[keyPath: kp] == true }, set: { command[keyPath: kp] = $0 ? true : nil })
    }
}
