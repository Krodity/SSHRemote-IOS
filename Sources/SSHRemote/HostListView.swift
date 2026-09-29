import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    /// The fork's AMOLED purple.
    static let purple = Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)
    static let surface = Color(white: 0.08)
    static let panel = Color(white: 0.13)
}

@main
struct SSHRemoteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HostListView()
                .preferredColorScheme(.dark)
                .tint(Theme.purple)
                .alert(item: $model.hostKeyPrompt) { p in
                    Alert(
                        title: Text(p.changed ? "⚠️ Host key changed" : "Trust this host?"),
                        message: Text((p.changed
                            ? "The key for \(p.hostname) is DIFFERENT from the one you trusted. This can mean someone is intercepting the connection.\n\n"
                            : "First connection to \(p.hostname).\n\n") + p.fingerprint),
                        primaryButton: p.changed ? .destructive(Text("Trust new key")) { p.resolve(true) }
                                                 : .default(Text("Trust")) { p.resolve(true) },
                        secondaryButton: .cancel { p.resolve(false) }
                    )
                }
                .sheet(item: $model.output) { OutputView(sheet: $0) }
                .overlay(alignment: .bottom) { Toast() }
                // Last, so it also covers the overlay and alert above: a view
                // outside its scope that reads @EnvironmentObject traps at
                // launch — which is exactly how the first build crashed.
                .environmentObject(model)
        }
        .onChange(of: phase) { _, now in
            // Background drops every connection; coming back reconnects any
            // remote that's on screen (AppModel's auto-reconnect).
            if now == .background { model.appEnteredBackground() }
            if now == .active { model.appBecameActive() }
        }
    }
}

struct Toast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.toast {
            Text(t).font(.footnote).padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 30).padding(.horizontal)
                .onTapGesture { model.toast = nil }
                .task(id: t) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.toast == t { model.toast = nil }
                }
        }
    }
}

struct HostListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Host?
    @State private var importing = false
    @State private var pasting = false
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            List {
                if model.hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No hosts yet").font(.headline)
                        Text("Add one with +, or import the settings you exported from SSH Remote on Android (Settings → Export).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(model.hosts) { h in
                    NavigationLink(value: h.id) {
                        HStack {
                            Circle().fill(dot(model.state(of: h.id))).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(h.title)
                                Text("\(h.user)@\(h.hostname)\(h.port == 22 ? "" : ":\(h.port)")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.delete(h) } label: { Label("Delete", systemImage: "trash") }
                        Button { editing = h } label: { Label("Edit", systemImage: "pencil") }.tint(Theme.purple)
                    }
                }
            }
            .navigationTitle("SSH Remote")
            .navigationDestination(for: String.self) { id in RemoteView(hostId: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showKey = true } label: { Label("This device's SSH key", systemImage: "key") }
                        Button { importing = true } label: { Label("Import settings file", systemImage: "square.and.arrow.down") }
                        Button { pasting = true } label: { Label("Paste settings", systemImage: "doc.on.clipboard") }
                    } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Host() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { h in HostEditView(host: h) }
            .sheet(isPresented: $showKey) { PublicKeyView() }
            .sheet(isPresented: $pasting) { PasteImportView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { r in
                guard case .success(let url) = r else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let n = try model.importSettings(text)
                    model.toast = "Imported \(n) host\(n == 1 ? "" : "s")"
                } catch {
                    model.toast = error.localizedDescription
                }
            }
        }
    }

    private func dot(_ s: ConnState) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

struct PasteImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 200)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } footer: {
                    Text("Paste the JSON export, or the compact string from Android's Settings → Export.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Paste settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let n = try model.importSettings(text)
                            model.toast = "Imported \(n) host\(n == 1 ? "" : "s")"
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(text.isBlank)
                }
            }
            .onAppear { if let s = UIPasteboard.general.string, text.isEmpty { text = s } }
        }
    }
}

/// Shows the key to paste into ~/.ssh/authorized_keys, with one-tap copy and
/// share. The private half never leaves the Keychain.
struct PublicKeyView: View {
    @Environment(\.dismiss) private var dismiss
    private let line = Store.publicKeyLine

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(line).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                } footer: {
                    Text("Add this line to ~/.ssh/authorized_keys on each computer. Or add a password to the host once and use “Install key on host” from its remote screen.")
                }
                Section {
                    Button { UIPasteboard.general.string = line } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: line) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("This device's key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct OutputView: View {
    let sheet: OutputSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(sheet.result.combined.isEmpty ? "(no output)" : sheet.result.combined)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if !sheet.result.ok {
                    Text("Exit status \(sheet.result.exitStatus ?? -1)").font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(8).background(Theme.surface)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { UIPasteboard.general.string = sheet.result.combined } label: { Image(systemName: "doc.on.doc") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
