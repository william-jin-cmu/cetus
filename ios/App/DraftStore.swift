import CetusRemoteKit
import Foundation
import UIKit

/// Unsent composer drafts, keyed like the desktop's draft-store
/// (`chat:<conversationId>`, `chat:new` for the New chat screen), so a
/// half-typed message survives leaving the chat, the app going to the
/// background, and a relaunch. Text lives in UserDefaults; photos are JPEG
/// files under Application Support/Drafts/<key>/.
enum DraftStore {
    static func key(for conversationId: String?) -> String {
        conversationId.map { "chat:\($0)" } ?? "chat:new"
    }

    private static let defaults = UserDefaults.standard
    private static func textKey(_ key: String) -> String { "draft.text.\(key)" }
    private static func atKey(_ key: String) -> String { "draft.at.\(key)" }

    static func text(_ key: String) -> String {
        defaults.string(forKey: textKey(key)) ?? ""
    }

    /// When the text was last edited (ms since 1970), here or on the Mac.
    static func editedAt(_ key: String) -> Int64 {
        Int64(defaults.double(forKey: atKey(key)))
    }

    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func setText(_ text: String, for key: String, at: Int64 = nowMs) {
        if text.isEmpty {
            defaults.removeObject(forKey: textKey(key))
        } else {
            defaults.set(text, forKey: textKey(key))
        }
        defaults.set(Double(at), forKey: atKey(key))
    }

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true)
    }

    private static func folder(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    static func images(_ key: String) -> [OutgoingImage] {
        let dir = folder(key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".jpg") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in
                (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap(OutgoingImage.init(jpeg:))
            }
    }

    /// Photos change rarely (pick, remove, send), so each change rewrites the
    /// folder; the JPEGs are already downscaled.
    static func setImages(_ images: [OutgoingImage], for key: String) {
        let dir = folder(key)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        guard !images.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, image) in images.enumerated() {
            try? image.jpeg.write(to: dir.appendingPathComponent("\(i).jpg"), options: .atomic)
        }
    }

    static func clear(_ key: String) {
        setText("", for: key)
        setImages([], for: key)
    }
}

/// A draft edit that came from the Mac (the desktop composer, or another phone).
struct RemoteDraft: Equatable {
    let key: String
    let text: String
    let updatedAt: Int64
}

/// The text of each draft is shared with the Mac (`drafts.get` / `drafts.set`,
/// pushed back as `draft_updated`), so a message started on one device can be
/// finished on the other. The newest edit wins. Photos stay on the phone.
extension RemoteStore {
    /// Send this draft's text to the Mac once typing pauses.
    func scheduleDraftPush(_ key: String) {
        draftPushes[key]?.cancel()
        draftPushes[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.draftPushes[key] = nil
            await self.pushDraft(key)
        }
    }

    func pushDraft(_ key: String) async {
        _ = try? await request("drafts.set", [
            "key": .string(key),
            "text": .string(DraftStore.text(key)),
            "updatedAt": .number(Double(DraftStore.editedAt(key))),
        ])
    }

    /// Reconcile with the Mac's copy. Returns the Mac's text when it is newer
    /// (already saved locally); pushes ours when ours is newer.
    func pullDraft(_ key: String) async -> String? {
        guard draftPushes[key] == nil,
              let remote = try? await request("drafts.get", ["key": .string(key)])
        else { return nil }
        let at = Int64(remote["updatedAt"].number ?? 0)
        let local = DraftStore.editedAt(key)
        // Typed while the request was out: ours is newer.
        guard draftPushes[key] == nil else { return nil }
        if at > local {
            let text = remote["text"].string ?? ""
            DraftStore.setText(text, for: key, at: at)
            return text
        }
        if local > at { await pushDraft(key) }
        return nil
    }

    /// `draft_updated` from the Mac.
    func receiveDraft(_ envelope: JSON) {
        guard let key = envelope["key"].string else { return }
        let at = Int64(envelope["updatedAt"].number ?? 0)
        guard at > DraftStore.editedAt(key), draftPushes[key] == nil else { return }
        let text = envelope["text"].string ?? ""
        DraftStore.setText(text, for: key, at: at)
        remoteDraft = RemoteDraft(key: key, text: text, updatedAt: at)
    }
}

extension OutgoingImage {
    /// A photo restored from a saved draft (already downscaled).
    init?(jpeg: Data) {
        guard let image = UIImage(data: jpeg) else { return nil }
        self.init(preview: image, jpeg: jpeg)
    }
}
