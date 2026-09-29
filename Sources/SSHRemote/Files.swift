import SwiftUI
import AVKit
import QuickLook
import UIKit
import UniformTypeIdentifiers

// The Files tab. Nothing is installed on the computer: everything is a plain
// shell command over the host's SSH session, so it works on any Linux box
// with coreutils/findutils:
//   list      find -printf, NUL-separated (any filename survives)
//   play/open xdg-open, with the desktop session's env rebuilt (see openOnPC)
//   stream    AVPlayer's byte ranges answered by `dd skip= count=`
//   thumbs    ffmpegthumbnailer / pdftoppm / ImageMagick when installed

struct RemoteFile: Hashable, Identifiable {
    var name: String
    var isDir: Bool
    var size: Int64
    var mtime: Double
    var id: String { name }
}

enum FileKind {
    case dir, image, video, audio, pdf, text, other

    static func of(_ e: RemoteFile) -> FileKind {
        if e.isDir { return .dir }
        let ext = (e.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "avif":
            return .image
        case "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "3gp":
            return .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "alac", "aiff":
            return .audio
        case "pdf":
            return .pdf
        case "txt", "md", "log", "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "sh", "bash",
             "zsh", "fish", "py", "js", "ts", "tsx", "jsx", "kt", "kts", "swift", "c", "h", "cpp",
             "hpp", "rs", "go", "java", "rb", "lua", "css", "html", "htm", "xml", "csv", "sql",
             "service", "desktop", "env", "rules", "lock", "srt", "ass", "vtt":
            return .text
        default:
            return ext.isEmpty ? .text : .other
        }
    }

    var hasThumb: Bool { self == .image || self == .video || self == .pdf }

    var icon: (String, Color) {
        switch self {
        case .dir: ("folder.fill", .orange)
        case .image: ("photo", Theme.purple)
        case .video: ("film", Color(red: 0.6, green: 0.45, blue: 1))
        case .audio: ("music.note", .green)
        case .pdf: ("doc.richtext", .red)
        case .text: ("doc.text", .white)
        case .other: ("doc", .gray)
        }
    }
}

/// A block device with a filesystem, mounted or not.
struct RemoteDrive: Identifiable, Hashable {
    var device: String
    var label: String
    var size: String
    var fstype: String
    var mount: String?
    var removable: Bool
    var id: String { device }

    var title: String {
        if !label.isEmpty { return label }
        if mount == "/" { return "System" }
        return (device as NSString).lastPathComponent
    }
}

enum FilesOpenMode: String {
    case pc, app
    var label: String { self == .pc ? "Play on PC" : "Play in app" }
    var icon: String { self == .pc ? "desktopcomputer" : "iphone" }
}

/// Single-quoted for sh.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum FileSheet: Identifiable {
    case text(String)
    case images([RemoteFile], Int, String)
    case media(RemoteFile, String)
    case preview(URL)
    case share(URL)

    var id: String {
        switch self {
        case .text(let p): "t:\(p)"
        case .images(_, let i, let d): "i:\(d):\(i)"
        case .media(_, let p): "m:\(p)"
        case .preview(let u): "p:\(u.path)"
        case .share(let u): "s:\(u.path)"
        }
    }

    var fullScreen: Bool {
        switch self {
        case .images, .media: true
        default: false
        }
    }
}

// ── model ────────────────────────────────────────────────────────────────────

@MainActor
final class FilesModel: ObservableObject {
    @Published var path: String
    @Published var entries: [RemoteFile] = []
    @Published var loaded = false
    @Published var loading = false
    @Published var error: String?
    @Published var busy: String?
    @Published var sheet: FileSheet?
    @Published var fallback: RemoteFile?
    @Published var showHidden = false
    @Published var home: String?
    @Published var drives: [RemoteDrive]?

    let hostId: String
    weak var app: AppModel?

    /// AVPlayer demuxes these; anything else (MKV, WebM, AVI…) is a black screen.
    static let playable: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "mp3", "m4a", "aac", "flac", "wav", "aiff", "alac", "caf",
    ]
    static let largeFile: Int64 = 200 * 1024 * 1024

    init(hostId: String) {
        self.hostId = hostId
        path = UserDefaults.standard.string(forKey: "filesPath.\(hostId)") ?? "~"
    }

    var visible: [RemoteFile] { showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") } }

    var parent: String? { path == "/" || path == "~" ? nil : ((path as NSString).deletingLastPathComponent) }

    func full(_ e: RemoteFile) -> String { path == "/" ? "/\(e.name)" : "\(path)/\(e.name)" }

    func exec(_ cmd: String, timeout: Int64 = 60) async throws -> CommandResult {
        guard let app else { throw SSHError(message: "Not connected") }
        return try await app.exec(cmd, on: hostId, timeout: timeout)
    }

    func load(_ p: String? = nil) async {
        let target = p ?? path
        loading = true
        defer { loading = false }
        let cd = target == "~" ? "cd" : "cd -- \(shq(target))"
        do {
            let r = try await exec("\(cd) || exit 1; pwd; printf '%s\\n' \"$HOME\"; "
                                   + "find -L . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%f\\0' 2>/dev/null")
            guard r.ok else {
                throw SSHError(message: (r.stderr.isBlank ? "Can't open \(target)" : r.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let lines = r.stdout.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard lines.count >= 2 else { throw SSHError(message: "Unexpected listing") }
            path = String(lines[0])
            home = String(lines[1])
            let body = lines.count > 2 ? lines[2] : ""
            entries = body.split(separator: "\0").compactMap { rec in
                let f = rec.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard f.count == 4, !f[3].isEmpty else { return nil }
                return RemoteFile(name: String(f[3]), isDir: f[0] == "d",
                                  size: Int64(f[1]) ?? 0, mtime: Double(f[2]) ?? 0)
            }
            .sorted { a, b in
                a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            UserDefaults.standard.set(path, forKey: "filesPath.\(hostId)")
            error = nil
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Every filesystem lsblk can see, including plugged-in drives nobody
    /// has mounted yet. Swap, LUKS containers, RAID/LVM members and the
    /// boot/EFI partitions are left out — nothing to browse there.
    func loadDrives() async {
        do {
            let r = try await exec("lsblk -Pno PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM,HOTPLUG")
            let skipFs: Set<String> = ["", "swap", "crypto_LUKS", "LVM2_member", "linux_raid_member", "zfs_member"]
            let skipMounts: Set<String> = ["/boot", "/boot/efi", "/efi", "[SWAP]"]
            let pair = try NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
            drives = r.stdout.split(separator: "\n").compactMap { line in
                let l = String(line)
                var f: [String: String] = [:]
                for m in pair.matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                    guard let k = Range(m.range(at: 1), in: l), let v = Range(m.range(at: 2), in: l) else { continue }
                    f[String(l[k])] = String(l[v])
                }
                guard let dev = f["PATH"], let fs = f["FSTYPE"], !skipFs.contains(fs) else { return nil }
                // A btrfs root lists every subvolume mount; "/" is the drive.
                let mounts = (f["MOUNTPOINTS"] ?? "").components(separatedBy: "\\x0a")
                    .map { $0.replacingOccurrences(of: "\\x20", with: " ") }.filter { !$0.isEmpty }
                if mounts.contains(where: skipMounts.contains) { return nil }
                let mount = mounts.contains("/") ? "/" : mounts.min { $0.count < $1.count }
                return RemoteDrive(device: dev, label: f["LABEL"] ?? "", size: f["SIZE"] ?? "", fstype: fs,
                                   mount: mount, removable: f["RM"] == "1" || f["HOTPLUG"] == "1")
            }
            .sorted { ($0.mount == nil ? 1 : 0, $0.title) < ($1.mount == nil ? 1 : 0, $1.title) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Mounted → browse it. Not mounted → udisks mounts it the way the
    /// desktop's file manager would (under /run/media/$USER), then browse.
    func open(_ d: RemoteDrive) async {
        if let m = d.mount { await load(m); return }
        busy = "Mounting \(d.title)…"
        defer { busy = nil }
        do {
            let r = try await exec("udisksctl mount --no-user-interaction -b \(shq(d.device))", timeout: 60)
            guard r.ok, let at = r.stdout.range(of: " at ") else {
                let why = (r.stderr.isBlank ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSHError(message: why.contains("NotAuthorized")
                               ? "Not allowed to mount \(d.title) over SSH (polkit). Mount it on the PC once, or add a polkit rule."
                               : (why.isEmpty ? "Couldn't mount \(d.title)" : why))
            }
            let mount = r.stdout[at.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            await load(mount)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func tap(_ e: RemoteFile, mode: FilesOpenMode) async {
        if e.isDir { await load(full(e)); return }
        switch mode {
        case .pc: await openOnPC(e)
        case .app: await openInApp(e)
        }
    }

    /// An SSH session has no desktop environment, so a bare `xdg-open`
    /// can't reach Wayland/X or the session bus. Rebuild those from the
    /// user's runtime dir, then detach so the player outlives the channel.
    func openOnPC(_ e: RemoteFile) async {
        let script = """
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        [ -n "$WAYLAND_DISPLAY" ] || WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 -x 'wayland-[0-9]*')
        export WAYLAND_DISPLAY DISPLAY="${DISPLAY:-:0}"
        export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
        command -v xdg-open >/dev/null || { echo 'xdg-open is not installed on this host' >&2; exit 1; }
        setsid -f xdg-open \(shq(full(e))) >/dev/null 2>&1 </dev/null
        """
        busy = "Opening on PC…"
        defer { busy = nil }
        do {
            let r = try await exec(script)
            if r.ok { app?.toast = "Playing \(e.name) on the PC" } else { error = r.stderr }
        } catch { self.error = error.localizedDescription }
    }

    func openInApp(_ e: RemoteFile) async {
        switch FileKind.of(e) {
        case .dir: await load(full(e))
        case .image:
            let imgs = visible.filter { FileKind.of($0) == .image }
            sheet = .images(imgs, imgs.firstIndex(of: e) ?? 0, path)
        case .video, .audio:
            if Self.playable.contains((e.name as NSString).pathExtension.lowercased()) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                sheet = .media(e, full(e))
            } else {
                fallback = e
            }
        case .text: sheet = .text(full(e))
        case .pdf, .other:
            if let url = await download(e) { sheet = .preview(url) }
        }
    }

    func share(_ e: RemoteFile) async {
        if let url = await download(e) { sheet = .share(url) }
    }

    /// One byte range of a file. `dd` with byte-granular skip/count is GNU
    /// coreutils; that's every mainstream Linux.
    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let r = try await exec("dd if=\(shq(path)) bs=1M iflag=skip_bytes,count_bytes "
                               + "skip=\(offset) count=\(length) status=none", timeout: 120)
        guard r.ok else { throw SSHError(message: r.stderr.isBlank ? "Read failed" : r.stderr) }
        return r.data
    }

    /// The whole file into Caches, in 4 MB pieces (one exec channel each, so
    /// a big file never sits in memory at once).
    func download(_ e: RemoteFile) async -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(e.name)
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? h.close() }
        let src = full(e)
        let chunk = 4 * 1024 * 1024
        var off: Int64 = 0
        defer { busy = nil }
        do {
            repeat {
                busy = e.size > 0 ? "Downloading \(e.name)… \(Int(Double(off) / Double(e.size) * 100))%"
                                  : "Downloading \(e.name)…"
                let d = try await read(src, offset: off, length: chunk)
                try h.write(contentsOf: d)
                off += Int64(d.count)
                if d.count < chunk { break }
            } while true
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

// ── thumbnails / images ──────────────────────────────────────────────────────

@MainActor
final class RemoteImages {
    static let shared = RemoteImages()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private static let native: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]

    private func cached(_ key: String, _ make: @escaping () async -> UIImage?) async -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let t = inflight[key] { return await t.value }
        let t = Task { await make() }
        inflight[key] = t
        let img = await t.value
        inflight[key] = nil
        if let img {
            cache.setObject(img, forKey: key as NSString,
                            cost: Int(img.size.width * img.scale * img.size.height * img.scale * 4))
        }
        return img
    }

    func thumb(_ fm: FilesModel, _ e: RemoteFile, path: String) async -> UIImage? {
        await cached("t:\(fm.hostId):\(path):\(e.mtime)") {
            let f = shq(path)
            let ext = (e.name as NSString).pathExtension.lowercased()
            let cmd: String
            switch FileKind.of(e) {
            case .video: cmd = "ffmpegthumbnailer -i \(f) -o - -c jpeg -s 256 2>/dev/null"
            case .pdf: cmd = "pdftoppm -jpeg -f 1 -l 1 -scale-to 256 \(f) 2>/dev/null"
            default:
                // Small photos come over as-is; big ones are shrunk on the host.
                cmd = Self.native.contains(ext) && e.size <= 1_500_000 ? "cat \(f)"
                    : "(magick \(shq(path + "[0]")) -thumbnail 256x256 jpg:- || convert \(shq(path + "[0]")) -thumbnail 256x256 jpg:-) 2>/dev/null"
            }
            guard let r = try? await fm.exec(cmd), !r.data.isEmpty else { return nil }
            return await Self.decode(r.data, max: 256)
        }
    }

    /// The original when the phone can decode it and it isn't huge (sharp
    /// zoom); otherwise a 2048 px render from the host.
    func full(_ fm: FilesModel, _ e: RemoteFile, path: String) async -> UIImage? {
        await cached("f:\(fm.hostId):\(path):\(e.mtime)") {
            let ext = (e.name as NSString).pathExtension.lowercased()
            if Self.native.contains(ext) && e.size <= 40 * 1024 * 1024,
               let r = try? await fm.exec("cat \(shq(path))", timeout: 180), !r.data.isEmpty,
               let img = await Self.decode(r.data, max: 4096) {
                return img
            }
            let p = shq(path + "[0]")
            guard let r = try? await fm.exec("(magick \(p) -resize '2048x2048>' jpg:- || convert \(p) -resize '2048x2048>' jpg:-) 2>/dev/null",
                                             timeout: 120), !r.data.isEmpty else { return nil }
            return await Self.decode(r.data, max: 2048)
        }
    }

    /// Downsampled at decode, so a 50 MP photo never becomes a 200 MB bitmap.
    nonisolated static func decode(_ data: Data, max: Int) async -> UIImage? {
        await Task.detached {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// ── the tab ──────────────────────────────────────────────────────────────────

struct FilesTabView: View {
    @EnvironmentObject var model: AppModel
    let hostId: String
    @StateObject private var fm: FilesModel
    @AppStorage("filesOpenMode") private var modeRaw = FilesOpenMode.app.rawValue
    @AppStorage("filesGrid") private var grid = false
    @State private var pickingDrive = false

    init(hostId: String) {
        self.hostId = hostId
        _fm = StateObject(wrappedValue: FilesModel(hostId: hostId))
    }

    private var mode: FilesOpenMode { FilesOpenMode(rawValue: modeRaw) ?? .app }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            pathBar
            Divider()
            ZStack {
                if let err = fm.error, !fm.loaded {
                    VStack(spacing: 10) {
                        Text(err).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Retry") { Task { await fm.load() } }
                    }.padding()
                } else if !fm.loaded {
                    ProgressView()
                } else if grid {
                    gridView
                } else {
                    listView
                }
                if let b = fm.busy {
                    HStack(spacing: 10) { ProgressView(); Text(b).font(.footnote) }
                        .padding(14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .task {
            fm.app = model
            if !fm.loaded { await fm.load() }
        }
        .onChange(of: fm.error) { _, e in
            // Once a folder is showing, errors are transient — toast them.
            if let e, fm.loaded { model.toast = e.trimmingCharacters(in: .whitespacesAndNewlines); fm.error = nil }
        }
        .sheet(item: sheetBinding(fullScreen: false)) { s in
            switch s {
            case .text(let p): RemoteTextView(fm: fm, path: p)
            case .preview(let u): QuickLookView(url: u).ignoresSafeArea()
            case .share(let u): ShareSheet(items: [u]).presentationDetents([.medium, .large])
            default: EmptyView()
            }
        }
        .fullScreenCover(item: sheetBinding(fullScreen: true)) { s in
            switch s {
            case .images(let list, let i, let dir): RemoteImageViewer(fm: fm, entries: list, index: i, dir: dir)
            case .media(let e, let p): RemoteMediaPlayer(fm: fm, file: e, path: p).ignoresSafeArea()
            default: EmptyView()
            }
        }
        .sheet(isPresented: $pickingDrive) {
            DrivePicker(fm: fm) { d in
                pickingDrive = false
                Task { await fm.open(d) }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Can't play .\(((fm.fallback?.name ?? "") as NSString).pathExtension) on iPhone",
                            isPresented: Binding(get: { fm.fallback != nil }, set: { if !$0 { fm.fallback = nil } }),
                            titleVisibility: .visible, presenting: fm.fallback) { e in
            Button("Play on PC") { Task { await fm.openOnPC(e) } }
            Button("Download & open with… (\(sizeLabel(e.size)))") { Task { await fm.share(e) } }
        } message: { _ in
            Text("iPhone can only stream MP4/MOV and common audio. VLC and similar apps can play it once downloaded.")
        }
    }

    private func sheetBinding(fullScreen: Bool) -> Binding<FileSheet?> {
        Binding(get: { fm.sheet.flatMap { $0.fullScreen == fullScreen ? $0 : nil } },
                set: { if $0 == nil { fm.sheet = nil } })
    }

    // ── chrome ───────────────────────────────────────────────────────────────
    private var toolbar: some View {
        HStack(spacing: 16) {
            Button { Task { if let p = fm.parent { await fm.load(p) } } } label: { Image(systemName: "arrow.up") }
                .disabled(fm.parent == nil)
            Menu {
                ForEach(places, id: \.1) { p in Button(p.0) { Task { await fm.load(p.1) } } }
            } label: { Image(systemName: "star") }
            Button { pickingDrive = true } label: { Image(systemName: "externaldrive") }
            Button { Task { await fm.load() } } label: { Image(systemName: "arrow.clockwise") }
            Spacer()
            Button { modeRaw = (mode == .pc ? FilesOpenMode.app : .pc).rawValue } label: {
                Label(mode.label, systemImage: mode.icon).font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.purple.opacity(0.25), in: Capsule())
                    .overlay(Capsule().stroke(Theme.purple))
            }
            Menu {
                Button { grid.toggle() } label: {
                    Label(grid ? "List view" : "Grid view", systemImage: grid ? "list.bullet" : "square.grid.2x2")
                }
                Button { fm.showHidden.toggle() } label: {
                    Label(fm.showHidden ? "Hide dotfiles" : "Show dotfiles", systemImage: "eye")
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.title3)
        .foregroundStyle(Theme.purple)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var places: [(String, String)] {
        let h = fm.home ?? "~"
        return [("Home", h), ("Downloads", "\(h)/Downloads"), ("Videos", "\(h)/Videos"),
                ("Music", "\(h)/Music"), ("Pictures", "\(h)/Pictures"), ("Desktop", "\(h)/Desktop"),
                ("Root (/)", "/")]
    }

    private var pathBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let parts = crumbs(fm.path)
                    ForEach(parts.indices, id: \.self) { i in
                        Button(parts[i].0) { Task { await fm.load(parts[i].1) } }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(i == parts.count - 1 ? .white : .gray)
                            .id(i)
                        if i > 0 && i < parts.count - 1 { Text("/").font(.system(size: 12, design: .monospaced)).foregroundStyle(.gray.opacity(0.6)) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: fm.path) { _, p in proxy.scrollTo(crumbs(p).count - 1, anchor: .trailing) }
        }
        .background(Theme.surface)
    }

    private func crumbs(_ path: String) -> [(String, String)] {
        var out: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/\(part)"
            out.append((String(part), acc))
        }
        return out
    }

    // ── listings ─────────────────────────────────────────────────────────────
    private var listView: some View {
        List {
            ForEach(fm.visible) { e in
                Button { Task { await fm.tap(e, mode: mode) } } label: { FileRow(fm: fm, entry: e) }
                    .listRowBackground(Color.black)
                    .contextMenu { actions(e) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await fm.load() }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 12) {
                ForEach(fm.visible) { e in
                    Button { Task { await fm.tap(e, mode: mode) } } label: { FileTile(fm: fm, entry: e) }
                        .contextMenu { actions(e) }
                }
            }
            .padding(12)
        }
        .refreshable { await fm.load() }
    }

    @ViewBuilder
    private func actions(_ e: RemoteFile) -> some View {
        if e.isDir {
            Button { Task { await fm.openOnPC(e) } } label: { Label("Open folder on PC", systemImage: "desktopcomputer") }
        } else {
            Button { Task { await fm.openOnPC(e) } } label: { Label("Play on PC", systemImage: "desktopcomputer") }
            Button { Task { await fm.openInApp(e) } } label: { Label("Play in app", systemImage: "iphone") }
            Button { Task { await fm.share(e) } } label: { Label("Open with… / Save", systemImage: "square.and.arrow.up") }
        }
        Button { UIPasteboard.general.string = fm.full(e) } label: { Label("Copy path", systemImage: "doc.on.clipboard") }
    }
}

func sizeLabel(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

private let thisYear: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f }()
private let otherYear: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d yyyy"; return f }()

private func formatDate(_ t: Double) -> String {
    let d = Date(timeIntervalSince1970: t)
    return (Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? thisYear : otherYear).string(from: d)
}

private struct FileThumb: View {
    @ObservedObject var fm: FilesModel
    let entry: RemoteFile
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        let kind = FileKind.of(entry)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped()
                if kind == .video {
                    Image(systemName: "play.circle.fill").font(.system(size: size * 0.3))
                        .foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
                }
            } else {
                Image(systemName: kind.icon.0).font(.system(size: size * 0.42)).foregroundStyle(kind.icon.1)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: fm.full(entry)) {
            guard kind.hasThumb else { return }
            image = await RemoteImages.shared.thumb(fm, entry, path: fm.full(entry))
        }
    }
}

private struct FileRow: View {
    @ObservedObject var fm: FilesModel
    let entry: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            FileThumb(fm: fm, entry: entry, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 15)).foregroundStyle(entry.isDir ? .orange : .white)
                    .lineLimit(1).truncationMode(.middle)
                Text(entry.isDir ? formatDate(entry.mtime) : "\(sizeLabel(entry.size)) · \(formatDate(entry.mtime))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
            }
            Spacer()
            if entry.isDir { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.gray) }
        }
        .padding(.vertical, 2)
    }
}

private struct FileTile: View {
    @ObservedObject var fm: FilesModel
    let entry: RemoteFile

    var body: some View {
        VStack(spacing: 6) {
            FileThumb(fm: fm, entry: entry, size: 100)
            Text(entry.name).font(.caption).foregroundStyle(entry.isDir ? .orange : .white)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 30, alignment: .top)
        }
    }
}

private struct DrivePicker: View {
    @ObservedObject var fm: FilesModel
    let pick: (RemoteDrive) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let drives = fm.drives {
                    let mounted = drives.filter { $0.mount != nil }
                    let unmounted = drives.filter { $0.mount == nil }
                    if !mounted.isEmpty {
                        Section("Mounted") { ForEach(mounted) { row($0) } }
                    }
                    if !unmounted.isEmpty {
                        Section {
                            ForEach(unmounted) { row($0) }
                        } header: { Text("Connected, not mounted") } footer: {
                            Text("Tap to mount (udisks, like the file manager does) and open it.")
                        }
                    }
                    if drives.isEmpty { Text("No drives found").foregroundStyle(.secondary) }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Drives")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await fm.loadDrives() }
        }
        .task { await fm.loadDrives() }
    }

    private func row(_ d: RemoteDrive) -> some View {
        Button { pick(d) } label: {
            HStack(spacing: 12) {
                Image(systemName: d.removable ? "externaldrive.fill" : (d.mount == "/" ? "internaldrive.fill" : "internaldrive"))
                    .font(.title2).foregroundStyle(d.mount == nil ? .gray : Theme.purple).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).foregroundStyle(.white)
                    Text("\(d.size) · \(d.fstype) · \(d.mount ?? d.device)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray).lineLimit(1)
                }
                Spacer()
                if d.mount == nil { Text("Mount").font(.caption.bold()).foregroundStyle(Theme.purple) }
            }
        }
    }
}

// ── viewers ──────────────────────────────────────────────────────────────────

/// Read-only: the first 2 MB.
struct RemoteTextView: View {
    @ObservedObject var fm: FilesModel
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var text: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .overlay { if text == nil { ProgressView() } }
            .background(Color.black)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            let r = try? await fm.exec("head -c 2000000 \(shq(path))")
            text = r.map { String(decoding: $0.data, as: UTF8.self) } ?? "Couldn't read the file"
        }
    }
}

/// Full-screen pager through the folder's images; pinch or double-tap to zoom.
struct RemoteImageViewer: View {
    @ObservedObject var fm: FilesModel
    @Environment(\.dismiss) private var dismiss
    let entries: [RemoteFile]
    @State var index: Int
    let dir: String
    @State private var chrome = true

    init(fm: FilesModel, entries: [RemoteFile], index: Int, dir: String) {
        self.fm = fm
        self.entries = entries
        _index = State(initialValue: index)
        self.dir = dir
    }

    private func path(_ e: RemoteFile) -> String { dir == "/" ? "/\(e.name)" : "\(dir)/\(e.name)" }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(entries.indices, id: \.self) { i in
                    ImagePage(fm: fm, entry: entries[i], path: path(entries[i])) { chrome.toggle() }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chrome, entries.indices.contains(index) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title3) }
                    VStack(alignment: .leading) {
                        Text(entries[index].name).font(.subheadline).lineLimit(1)
                        Text("\(index + 1) of \(entries.count)").font(.caption).foregroundStyle(.gray)
                    }
                    Spacer()
                    Button {
                        let e = entries[index]
                        Task { await fm.openOnPC(e) }
                    } label: { Image(systemName: "desktopcomputer") }
                }
                .foregroundStyle(.white)
                .padding()
                .background(.black.opacity(0.55))
            }
        }
    }
}

private struct ImagePage: View {
    @ObservedObject var fm: FilesModel
    let entry: RemoteFile
    let path: String
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, onTap: onTap)
            } else if failed {
                Text("Couldn't load \(entry.name)").foregroundStyle(.gray)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: path) {
            image = await RemoteImages.shared.full(fm, entry, path: path)
            failed = image == nil
        }
    }
}

/// UIScrollView zoom: it only claims horizontal drags while zoomed in, so
/// swiping between pages keeps working at 1×.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.maximumZoomScale = 8
        sv.minimumZoomScale = 1
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .black
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
            iv.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = iv
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        sv.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        sv.addGestureRecognizer(single)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTap() { onTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let s: CGFloat = 2.5
                let w = sv.bounds.width / s, h = sv.bounds.height / s
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}

// ── video / audio over SSH ───────────────────────────────────────────────────

/// AVPlayer on a made-up `sshfile://` URL: AVFoundation can't fetch it, so
/// it asks the resource loader for byte ranges, and each range becomes a
/// `dd` over the SSH session. Seeking just asks for a different range.
struct RemoteMediaPlayer: UIViewControllerRepresentable {
    let fm: FilesModel
    let file: RemoteFile
    let path: String

    func makeCoordinator() -> SSHMediaLoader {
        let ext = (file.name as NSString).pathExtension
        return SSHMediaLoader(size: file.size,
                              contentType: UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier) {
            [fm, path] off, len in try await fm.read(path, offset: off, length: len)
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        var comps = URLComponents()
        comps.scheme = "sshfile"
        comps.host = "file"
        comps.path = "/" + file.name
        let asset = AVURLAsset(url: comps.url ?? URL(string: "sshfile://file/media")!)
        asset.resourceLoader.setDelegate(context.coordinator, queue: context.coordinator.queue)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        vc.player = player
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: SSHMediaLoader) {
        vc.player?.pause()
        coordinator.cancelAll()
    }
}

final class SSHMediaLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "sshremote.media")
    private let size: Int64
    private let contentType: String
    private let read: (Int64, Int) async throws -> Data
    /// Touched only on `queue`.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// 1 MiB per exec: small enough to start fast, big enough that the
    /// per-command round trip isn't the bottleneck. Two are kept in flight.
    private let chunk = 1 << 20

    init(size: Int64, contentType: String, read: @escaping (Int64, Int) async throws -> Data) {
        self.size = size
        self.contentType = contentType
        self.read = read
    }

    func resourceLoader(_ loader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        if let info = req.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dr = req.dataRequest else { req.finishLoading(); return true }
        let start = dr.currentOffset != 0 ? dr.currentOffset : dr.requestedOffset
        let end = dr.requestsAllDataToEndOfResource ? size : min(size, dr.requestedOffset + Int64(dr.requestedLength))
        let key = ObjectIdentifier(req)
        let chunk = self.chunk, read = self.read, queue = self.queue
        tasks[key] = Task {
            var off = start
            func fetch(_ at: Int64) -> Task<Data, Error>? {
                guard at < end else { return nil }
                let n = Int(min(Int64(chunk), end - at))
                return Task { try await read(at, n) }
            }
            var pending = fetch(off)
            do {
                while let current = pending, !Task.isCancelled {
                    let next = fetch(off + Int64(chunk))
                    let d = try await current.value
                    if d.isEmpty { next?.cancel(); break }
                    queue.sync { if !req.isCancelled { dr.respond(with: d) } }
                    off += Int64(d.count)
                    pending = next
                }
                queue.async { if !req.isCancelled && !req.isFinished { req.finishLoading() } }
            } catch {
                queue.async { if !req.isCancelled && !req.isFinished { req.finishLoading(with: error) } }
            }
            queue.async { self.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(req))?.cancel()
    }

    func cancelAll() {
        queue.async {
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
        }
    }
}

// ── everything else ──────────────────────────────────────────────────────────

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
