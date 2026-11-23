import CetusRemoteKit
import CryptoKit
import Network
import Observation
import SwiftUI
import UIKit

/// The desktop sidebar's folder layout, pushed by the Mac's webview.
struct SidebarLayout {
    var defaultDir = ""
    var dirs: [String] = []
    var hidden: Set<String> = []
    var collapsed: Set<String> = []
    /// Chats the Mac's sidebar leaves out (Cetus coordinator sessions).
    var hiddenChats: Set<String> = []
    /// Colors / emoji the user picked for folders on the Mac, by dir.
    var avatars: [String: FolderStyle] = [:]
}

/// A folder avatar the user chose on the Mac: a palette color, an emoji
/// instead of the initial, or both.
struct FolderStyle: Equatable {
    var color: UInt32?
    var emoji: String?

    init?(_ j: JSON) {
        if let hex = j["color"].string, hex.hasPrefix("#") { color = UInt32(hex.dropFirst(), radix: 16) }
        emoji = j["emoji"].string.flatMap { $0.isEmpty ? nil : $0 }
        if color == nil && emoji == nil { return nil }
    }
}

/// One folder section of the chat list (or the global Pinned section).
struct ChatGroup: Identifiable {
    var id: String { dir }
    let dir: String
    let name: String
    let items: [Conversation]
    var isPinned = false
    var isDefault = false
}

/// The model and effort last picked for a runtime on this phone. New chats
/// start with it. "" = the runtime's own default.
struct TuningChoice: Equatable {
    var model = ""
    var effort = ""

    static func load(_ backend: String) -> TuningChoice {
        let d = UserDefaults.standard
        return TuningChoice(
            model: d.string(forKey: "tuning.\(backend).model") ?? "",
            effort: d.string(forKey: "tuning.\(backend).effort") ?? "")
    }

    func save(_ backend: String) {
        let d = UserDefaults.standard
        d.set(model, forKey: "tuning.\(backend).model")
        d.set(effort, forKey: "tuning.\(backend).effort")
    }

    /// This choice with anything the catalog doesn't list reset to default,
    /// for a pick remembered from another Mac or an older catalog.
    func valid(in tuning: RuntimeTuning) -> TuningChoice {
        let m = tuning.models.contains { $0.id == model } ? model : ""
        let e = tuning.efforts(forModel: m).contains { $0.id == effort } ? effort : ""
        return TuningChoice(model: m, effort: e)
    }
}

/// A folder suggestion from the Mac.
struct DirHit: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let display: String
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case unpaired
}

/// App-wide state: paired Macs, the live encrypted connection to the selected
/// one, and the conversation list it streams.
@MainActor
@Observable
final class RemoteStore {
    private(set) var hosts: [PairedHost] = []
    var selectedHostId: String? {
        didSet {
            UserDefaults.standard.set(selectedHostId, forKey: "selectedHost")
            if oldValue != selectedHostId {
                tunings = [:]
                loadedArchiveMode = nil
                conversations = []
                sidebar = SidebarLayout()
                restoreCached()
                reconnect()
            }
        }
    }
    private(set) var state: ConnectionState = .idle
    private(set) var conversations: [Conversation] = []
    private var loadedArchiveMode: Bool?
    var hasLoadedList: Bool { loadedArchiveMode == showArchived }
    private(set) var running: Set<String> = []
    private(set) var sidebar = SidebarLayout()
    /// Model and effort catalogs by runtime, as the selected Mac reports them.
    private(set) var tunings: [String: RuntimeTuning] = [:]
    private var tuningLoads: Set<String> = []
    /// Repo icons of git folders (an icon file from the repo, or its GitHub
    /// owner's avatar), by dir. Kept on disk so they show before the Mac answers.
    private(set) var folderIcons: [String: UIImage] = [:]
    private var iconVersions: [String: String] = [:]
    private var iconTask: Task<Void, Never>?
    var showArchived = false {
        didSet { Task { await refreshList() } }
    }

    /// Follow-ups typed while a chat's agent runs, per conversation. The next
    /// one goes out when the run ends; Steer sends one right away.
    private(set) var queued: [String: [QueuedMessage]] = [:]

    /// The chat on screen, fed this connection's events.
    weak var activeChat: ChatModel?
    /// The last draft edit the Mac sent (DraftStore); open composers follow it.
    var remoteDraft: RemoteDraft?
    @ObservationIgnored var draftPushes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    @ObservationIgnored private let networkMonitor = NWPathMonitor()
    private var hadNetwork: Bool?
    private var limitPrefetch = false
    private var connection: RemoteConnection?
    private var eventTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var attempt = 0

    let deviceId: String = {
        if let d = Keychain.data("deviceId"), let s = String(data: d, encoding: .utf8) { return s }
        let id = UUID().uuidString
        Keychain.set(Data(id.utf8), for: "deviceId")
        return id
    }()

    #if DEBUG
    /// `-demoList <file>`: a fake paired Mac with a canned chat list, sidebar
    /// and model catalog, for screenshots without a Mac.
    private var demoReplies: [String: JSON] = [:]
    let demoList = UserDefaults.standard.string(forKey: "demoList")
    #endif

    init() {
        #if DEBUG
        if let path = demoList, let data = FileManager.default.contents(atPath: path), let j = try? JSON.parse(data) {
            demoReplies = j["replies"].object ?? [:]
            let name = j["host"]["macName"].string ?? "Mac"
            let raw = #"{"sid":"demo","publicKey":"","relay":"","macName":"\#(name)","deviceToken":"","pairedAt":0}"#
            hosts = (try? JSONDecoder().decode(PairedHost.self, from: Data(raw.utf8))).map { [$0] } ?? []
            selectedHostId = hosts.first?.sid
            applySidebar(j["sidebar"])
            applyConversations(j["conversations"])
            for (k, v) in j["tunings"].object ?? [:] { tunings[k] = RuntimeTuning(v) }
            state = j["offline"].bool == true ? .failed("No connection") : .connected
            return
        }
        #endif
        if let d = Keychain.data("hosts"), let h = try? JSONDecoder().decode([PairedHost].self, from: d) {
            hosts = h
        }
        let saved = UserDefaults.standard.string(forKey: "selectedHost")
        selectedHostId = hosts.first { $0.sid == saved }?.sid ?? hosts.first?.sid
        restoreCached()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "dev.cetus.mobile.network"))
    }

    deinit { networkMonitor.cancel() }

    private func networkChanged(_ path: NWPath) {
        let available = path.status == .satisfied
        let recovered = hadNetwork == false && available
        hadNetwork = available
        limitPrefetch = !available || path.isConstrained || path.isExpensive
        if limitPrefetch { prefetchTask?.cancel() }
        if recovered, state != .unpaired { reconnect() }
    }

    /// Draw the selected Mac's chat list as last seen; the Mac's answer
    /// replaces it once connected.
    private func restoreCached() {
        guard let host = selectedHostId else { return }
        if !showArchived, let rows = SnapshotCache.list(host: host) { applyConversations(rows, live: false) }
        if let j = SnapshotCache.sidebar(host: host) { applySidebar(j) }
    }

    var selectedHost: PairedHost? { hosts.first { $0.sid == selectedHostId } }

    private func saveHosts() {
        if let d = try? JSONEncoder().encode(hosts) { Keychain.set(d, for: "hosts") }
    }

    // MARK: Pairing

    func pair(with offer: PairingOffer) async throws {
        let c = RemoteConnection()
        try await c.connect(relay: offer.relay, direct: offer.direct, sid: offer.sid, publicKey: offer.pk)
        let hello = try await c.hello(
            deviceId: deviceId, deviceName: UIDevice.current.name, token: nil, pairingSecret: offer.ps)
        await c.close()
        guard let token = hello.deviceToken else { throw RemoteError.handshakeFailed }
        let host = PairedHost(offer: offer, macName: hello.macName, deviceToken: token)
        hosts.removeAll { $0.sid == host.sid }
        hosts.append(host)
        saveHosts()
        if selectedHostId == host.sid {
            reconnect()
        } else {
            selectedHostId = host.sid
        }
    }

    func forget(_ host: PairedHost) {
        hosts.removeAll { $0.sid == host.sid }
        saveHosts()
        SnapshotCache.forget(host: host.sid)
        UserDefaults.standard.removeObject(forKey: "openChat.\(host.sid)")
        if selectedHostId == host.sid {
            selectedHostId = hosts.first?.sid
            if hosts.isEmpty { disconnect(); state = .idle; conversations = [] }
        }
    }

    // MARK: Connection

    func ensureConnected() {
        switch state {
        case .connected, .connecting, .unpaired: return
        default: reconnect()
        }
    }

    func reconnect() {
        #if DEBUG
        if demoList != nil { return }
        #endif
        disconnect()
        loadCachedIcons()
        guard let host = selectedHost else { state = .idle; return }
        state = .connecting
        retryTask = Task { await connect(host) }
    }

    private func disconnect() {
        prefetchTask?.cancel()
        iconTask?.cancel()
        retryTask?.cancel()
        eventTask?.cancel()
        let old = connection
        connection = nil
        Task { await old?.close() }
    }

    private func connect(_ host: PairedHost) async {
        let c = RemoteConnection()
        do {
            try await c.connect(relay: host.relay, direct: host.direct, sid: host.sid, publicKey: host.publicKey)
            let hello = try await c.hello(
                deviceId: deviceId, deviceName: UIDevice.current.name, token: host.deviceToken, pairingSecret: nil)
            guard !Task.isCancelled, host.sid == selectedHostId else { await c.close(); return }
            if hello.macName != host.macName, let i = hosts.firstIndex(where: { $0.sid == host.sid }) {
                hosts[i].macName = hello.macName
                saveHosts()
            }
            connection = c
            state = .connected
            attempt = 0
            eventTask = Task { [weak self] in
                for await e in c.events { self?.handle(e) }
                await self?.connectionDropped(c)
            }
            await refreshAfterConnect()
        } catch RemoteError.unpaired {
            await c.close()
            guard !Task.isCancelled, host.sid == selectedHostId else { return }
            state = .unpaired
        } catch {
            await c.close()
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    private func connectionDropped(_ c: RemoteConnection) async {
        let reason = await c.closeReason
        guard connection === c else { return }
        connection = nil
        state = .failed((reason ?? .closed).localizedDescription)
        scheduleRetry()
    }

    private func scheduleRetry() {
        attempt += 1
        let delay = min(30, pow(2, Double(min(attempt, 5))))
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let host = selectedHost else { return }
            state = .connecting
            await connect(host)
        }
    }

    func request(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        #if DEBUG
        if let reply = demoReplies[method] {
            try await Task.sleep(for: .milliseconds(reply["delayMs"].int ?? 0))
            for event in reply["events"].array ?? [] { handle(event) }
            return reply["result"]
        }
        #endif
        guard let connection else { throw RemoteError.closed }
        return try await connection.request(method, params)
    }

    // MARK: Conversations

    private func refreshAfterConnect() async {
        async let list: Void = refreshList()
        await activeChat?.load()
        await list
    }

    func refreshList() async {
        async let layout: Void = refreshSidebar()
        await refreshConversations()
        await layout
    }

    private func refreshSidebar() async {
        guard let host = selectedHostId, let j = try? await request("workspaces.list"),
              host == selectedHostId else { return }
        applySidebar(j)
        SnapshotCache.saveSidebar(j, host: host)
        refreshIcons()
    }

    private func applySidebar(_ j: JSON) {
        let strings = { (key: String) in (j[key].array ?? []).compactMap(\.string) }
        sidebar = SidebarLayout(
            defaultDir: j["defaultWorkspace"].string ?? "",
            dirs: strings("dirs"),
            hidden: Set(strings("hidden")),
            collapsed: Set(strings("collapsed")),
            hiddenChats: Set(strings("hiddenChats")),
            avatars: (j["avatars"].object ?? [:]).compactMapValues(FolderStyle.init)
        )
    }

    // MARK: Folder icons

    private var iconsKey: String { "folderIcons.\(selectedHostId ?? "")" }

    private func iconFile(_ dir: String) -> URL {
        let name = SHA256.hash(data: Data("\(selectedHostId ?? "")\u{0}\(dir)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let folder = URL.cachesDirectory.appending(path: "folder-icons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    private func loadCachedIcons() {
        iconVersions = UserDefaults.standard.dictionary(forKey: iconsKey) as? [String: String] ?? [:]
        folderIcons = [:]
        for dir in iconVersions.keys {
            if let image = UIImage(contentsOfFile: iconFile(dir).path) { folderIcons[dir] = image }
        }
    }

    /// Ask the Mac which folders have a repo icon and fetch the ones the
    /// cache lacks. A Mac too old to know the call just leaves the initials.
    private func refreshIcons() {
        iconTask?.cancel()
        iconTask = Task {
            guard let listing = try? await request("workspaces.icons").object, !Task.isCancelled else { return }
            for dir in iconVersions.keys where listing[dir] == nil {
                iconVersions[dir] = nil
                folderIcons[dir] = nil
                try? FileManager.default.removeItem(at: iconFile(dir))
            }
            for (dir, info) in listing {
                guard let v = info["v"].string else { continue }
                if iconVersions[dir] == v, folderIcons[dir] != nil { continue }
                guard let data = await fetchIcon(dir, fallback: info["url"].string), !Task.isCancelled,
                      let image = UIImage(data: data) else { continue }
                try? data.write(to: iconFile(dir), options: .atomic)
                folderIcons[dir] = image
                iconVersions[dir] = v
            }
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(iconVersions, forKey: iconsKey)
        }
    }

    private func fetchIcon(_ dir: String, fallback: String?) async -> Data? {
        let j = try? await request("workspaces.icon", ["dir": .string(dir)])
        if let b64 = j?["data"].string, let data = Data(base64Encoded: b64) { return data }
        // The Mac couldn't reach GitHub; maybe the phone can.
        guard let url = (j?["url"].string ?? fallback).flatMap(URL.init(string:)) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    func isDefaultFolder(_ dir: String) -> Bool {
        dir.isEmpty || dir == sidebar.defaultDir
    }

    func folderName(_ dir: String) -> String {
        dir.isEmpty || dir == sidebar.defaultDir ? "Chat" : dir.folderName
    }

    /// Chats grouped the way the Mac's sidebar draws them: Pinned first, then
    /// the default "Chat" folder and the user's folders in their order;
    /// folders the user removed on the Mac stay hidden here too.
    var groups: [ChatGroup] {
        var order: [String] = []
        var map: [String: [Conversation]] = [:]
        func ensure(_ dir: String) {
            guard map[dir] == nil, !sidebar.hidden.contains(dir) || dir == sidebar.defaultDir else { return }
            map[dir] = []
            order.append(dir)
        }
        if !sidebar.defaultDir.isEmpty { ensure(sidebar.defaultDir) }
        sidebar.dirs.forEach(ensure)
        let listed = conversations.filter { !$0.archived && !sidebar.hiddenChats.contains($0.id) }
        for c in listed {
            ensure(c.workspaceDir)
            if !c.pinned { map[c.workspaceDir]?.append(c) }
        }
        var out = order.map { ChatGroup(dir: $0, name: folderName($0), items: map[$0] ?? [], isDefault: isDefaultFolder($0)) }
        let pinned = listed.filter { $0.pinned && !sidebar.hidden.contains($0.workspaceDir) }
        if !pinned.isEmpty {
            out.insert(ChatGroup(dir: "\u{0}pinned", name: "Pinned", items: pinned, isPinned: true), at: 0)
        }
        return out
    }

    /// Folders a new chat can go in, in sidebar order.
    var folders: [String] {
        groups.filter { !$0.isPinned }.map(\.dir)
    }

    func addFolder(_ dir: String) async throws {
        let j = try await request("workspaces.add", ["dir": .string(dir)])
        applySidebar(j)
        if let host = selectedHostId { SnapshotCache.saveSidebar(j, host: host) }
    }

    func searchDirs(_ query: String) async throws -> [DirHit] {
        let j = try await request("fs.searchDirs", ["query": .string(query)])
        return (j.array ?? []).compactMap { h in
            h["path"].string.map { DirHit(path: $0, display: h["display"].string ?? $0) }
        }
    }

    func makeFolder(in parent: String, named name: String) async throws -> String {
        let j = try await request("fs.mkdir", ["parent": .string(parent), "name": .string(name)])
        guard let path = j["path"].string else { throw RemoteError.server("Couldn't create the folder.") }
        return path
    }

    private func refreshConversations() async {
        let archived = showArchived
        guard let host = selectedHostId, let rows = try? await request("conversations.list", ["archived": .bool(archived)]) else { return }
        // A toggle while the request was out asks for the other list.
        guard archived == showArchived, host == selectedHostId else { return }
        if !archived { SnapshotCache.saveList(rows, host: host) }
        applyConversations(rows)
        if !archived { prefetchChats() }
    }

    /// Chats fetched ahead so their first open draws at once.
    private static let prefetchCount = 6

    /// Fetch the most recent chats whose cached copy is older than their last
    /// change, one at a time (the Mac's uplink can be slow), so the next open
    /// draws from the cache. Running chats are skipped: their snapshot is
    /// outdated within seconds, and the open turn isn't cached anyway.
    private func prefetchChats() {
        guard !limitPrefetch, let host = selectedHostId else { return }
        let wanted = conversations
            .filter { !running.contains($0.id) && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.prefetchCount)
            .filter { !SnapshotCache.isFresh(host: host, id: $0.id, updatedAt: $0.updatedAt) }
            .map(\.id)
        guard !wanted.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            for id in wanted {
                guard let self, !Task.isCancelled, self.selectedHostId == host, self.state == .connected else { return }
                // The open chat fetches its own.
                if self.activeChat?.conversationId == id { continue }
                guard let snapshot = try? await self.request("conversations.get", ["id": .string(id)]) else { return }
                guard !Task.isCancelled, self.selectedHostId == host else { return }
                SnapshotCache.saveChat(snapshot, host: host, id: id)
            }
        }
    }

    /// `live: false` for a cached list, whose run states are old news.
    private func applyConversations(_ rows: JSON, live: Bool = true) {
        loadedArchiveMode = showArchived
        var list = (rows.array ?? []).compactMap(Conversation.init)
        if showArchived { list = list.filter(\.archived) }
        conversations = list.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
        guard live else { return }
        let observed = Set(list.map(\.id))
        running.subtract(observed)
        running.formUnion(list.filter { $0.runState == "running" }.map(\.id))
        // A run may have ended while the app was away from the events.
        for id in queued.keys where observed.contains(id) && !running.contains(id) { drainQueue(id) }
    }

    // MARK: Follow-up queue

    func enqueue(_ text: String, images: [OutgoingImage], for id: String) {
        queued[id, default: []].append(QueuedMessage(text: text, images: images))
    }

    func removeQueued(_ itemId: UUID, from id: String) {
        queued[id]?.removeAll { $0.id == itemId }
        if queued[id]?.isEmpty == true { queued[id] = nil }
    }

    /// Deliver a queued message now: pi and Claude Code inject it into the
    /// current run, Codex interrupts and resumes.
    func steerQueued(_ itemId: UUID, in id: String) {
        guard let item = queued[id]?.first(where: { $0.id == itemId }) else { return }
        removeQueued(itemId, from: id)
        deliver(item, to: id)
    }

    private func drainQueue(_ id: String) {
        guard !running.contains(id), let next = queued[id]?.first else { return }
        removeQueued(next.id, from: id)
        running.insert(id)
        deliver(next, to: id)
    }

    private func deliver(_ item: QueuedMessage, to id: String) {
        if activeChat?.conversationId == id { activeChat?.echo(item) }
        Task {
            do {
                try await send(item.text, images: item.images, to: id)
            } catch {
                // Put it back at the front so nothing typed is lost.
                queued[id, default: []].insert(item, at: 0)
                if activeChat?.conversationId == id { activeChat?.error = error.localizedDescription }
            }
        }
    }

    /// Fetch a runtime's model and effort catalog. The last answer stays on
    /// screen while a newer one loads. A Mac too old to know the method leaves
    /// the catalog missing, and the picker hidden.
    func loadTuning(_ backend: String) async {
        guard !tuningLoads.contains(backend) else { return }
        tuningLoads.insert(backend)
        defer { tuningLoads.remove(backend) }
        let host = selectedHostId
        guard let j = try? await request("runtimes.tuning", ["backend": .string(backend)]),
              host == selectedHostId else { return }
        tunings[backend] = RuntimeTuning(j)
    }

    /// Request fields that set a chat's model and effort. The built-in runtime
    /// takes a concrete pair, the CLI runtimes take "" for their own default.
    func tuningParams(_ choice: TuningChoice, backend: String) -> [String: JSON] {
        guard let tuning = tunings[backend], !tuning.isEmpty else { return [:] }
        if backend == Runtime.pi.rawValue {
            guard let model = tuning.model(for: choice.model),
                  let effort = tuning.effort(for: choice.effort, model: choice.model) else { return [:] }
            return ["model": ["model": .string(model.id), "reasoning": .string(effort.id)]]
        }
        return ["cliModel": .string(choice.model), "cliEffort": .string(choice.effort)]
    }

    func createConversation(runtime: Runtime, workspaceDir: String?, tuning: TuningChoice = TuningChoice()) async throws -> Conversation {
        var params: [String: JSON] = ["backend": .string(runtime.rawValue)]
        params.merge(tuningParams(tuning, backend: runtime.rawValue)) { _, new in new }
        if let workspaceDir { params["workspaceDir"] = .string(workspaceDir) }
        let r = try await request("conversations.create", .object(params))
        guard let c = Conversation(r) else { throw RemoteError.server("Couldn't create the chat.") }
        if c.archived == showArchived, !conversations.contains(where: { $0.id == c.id }) {
            conversations.insert(c, at: 0)
        }
        return c
    }

    func update(_ id: String, _ patch: [String: JSON]) async throws {
        var params = patch
        params["id"] = .string(id)
        let r = try await request("conversations.update", .object(params))
        // Show the change at once; the list refresh below reorders if needed.
        if let c = Conversation(r) {
            if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = c }
            activeChat?.conversationChanged(c)
        }
        await refreshList()
    }

    private func handle(_ envelope: JSON) {
        switch envelope["type"].string {
        case "conversation_updated", "conversation_created":
            if let c = Conversation(envelope["conversation"]) {
                if let i = conversations.firstIndex(where: { $0.id == c.id }) {
                    conversations[i] = c
                } else if c.archived == showArchived {
                    conversations.insert(c, at: 0)
                }
                activeChat?.conversationChanged(c)
            }
        case "draft_updated":
            receiveDraft(envelope)
        case "conversation_deleted":
            conversations.removeAll { $0.id == envelope["id"].string }
        case "resync":
            Task { await refreshAfterConnect() }
        case "pi_error":
            // The runtime's own complaint about the run on screen.
            if let id = envelope["conversationId"].string, activeChat?.conversationId == id,
               let message = envelope["message"].string
            {
                activeChat?.error = message
            }
        case "pi_event":
            guard let id = envelope["conversationId"].string else { return }
            let e = envelope["event"]
            // A run that retries by itself is still running; `agent_settled`
            // is what ends it.
            let ended = (e["type"].string == "agent_end" && e["willRetry"].bool != true)
                || (e["type"].string == "agent_settled" && running.contains(id))
            if e["type"].string == "agent_start" { running.insert(id) }
            if ended { running.remove(id) }
            if activeChat?.conversationId == id { activeChat?.apply(e, seq: envelope["seq"].int) }
            if ended { drainQueue(id) }
        default:
            break
        }
    }
}
