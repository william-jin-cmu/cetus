import CetusRemoteKit
import Foundation

/// Last-seen replies from the Mac, kept on disk so screens draw at once and
/// then refresh (stale-while-revalidate): the chat list and folder layout, and
/// each opened chat's `conversations.get` snapshot. Per paired Mac, under
/// Caches (iOS may purge it; everything here can be fetched again).
enum SnapshotCache {
    /// Chats kept; the least recently opened go first.
    private static let maxChats = 40

    private static var root: URL {
        URL.cachesDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
    }

    private static func folder(_ host: String) -> URL {
        root.appending(path: host, directoryHint: .isDirectory)
    }

    private static func chatFile(_ host: String, _ id: String) -> URL {
        folder(host).appending(path: "chats", directoryHint: .isDirectory)
            .appending(path: "\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id).json")
    }

    // MARK: List and folders (small; read on the main thread)

    static func list(host: String) -> JSON? { read(folder(host).appending(path: "list.json")) }
    static func sidebar(host: String) -> JSON? { read(folder(host).appending(path: "sidebar.json")) }
    static func saveList(_ rows: JSON, host: String) { write(rows, to: folder(host).appending(path: "list.json")) }
    static func saveSidebar(_ j: JSON, host: String) { write(j, to: folder(host).appending(path: "sidebar.json")) }

    // MARK: Chats (can be large; decoded off the main thread)

    static func chat(host: String, id: String) async -> JSON? {
        let url = chatFile(host, id)
        return await Task.detached(priority: .userInitiated) { read(url) }.value
    }

    /// The open turn's live events are dropped: a cached copy of a run that
    /// has since ended would show it still working.
    static func saveChat(_ snapshot: JSON, host: String, id: String) {
        guard var o = snapshot.object else { return }
        o["liveEvents"] = nil
        o["liveSeq"] = nil
        let url = chatFile(host, id)
        let dir = url.deletingLastPathComponent()
        let value = JSON.object(o)
        Task.detached(priority: .utility) {
            write(value, to: url)
            prune(dir)
        }
    }

    /// The cached copy was saved after the chat last changed.
    static func isFresh(host: String, id: String, updatedAt: Date) -> Bool {
        let url = chatFile(host, id)
        guard let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        return saved >= updatedAt
    }

    static func forget(host: String) {
        try? FileManager.default.removeItem(at: folder(host))
    }

    private static func read(_ url: URL) -> JSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    private static func write(_ value: JSON, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
            files.count > maxChats
        else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maxChats) {
            try? fm.removeItem(at: url)
        }
    }
}
