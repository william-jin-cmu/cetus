import CetusRemoteKit
import QuickLook
import SwiftUI

/// A failed send or run, at the end of the transcript where the reply would
/// have been, with a Retry that rolls the last turn back and runs it again.
struct MessageErrorRow: View {
    let message: String
    let retrying: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button(action: onRetry) {
                    HStack(spacing: 5) {
                        if retrying {
                            ProgressView().controlSize(.mini).tint(Theme.danger)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        }
                        Text(retrying ? "Retrying…" : "Retry").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.danger.opacity(0.3), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(retrying)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.danger.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.danger.opacity(0.3), lineWidth: 1))
    }
}

/// Shown above the composer while the Mac shrinks a full context.
struct CompactionBar: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(Theme.info)
            Text("Compacting context…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.info.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.info.opacity(0.25), lineWidth: 1))
    }
}

/// A thread the coordinator started (a card that opens it) or wrote to (one
/// quiet line).
struct ThreadCardView: View {
    let card: ThreadCard
    @Environment(RemoteStore.self) private var store

    var body: some View {
        NavigationLink(value: Route.chat(card.id)) {
            if card.isStart {
                let working = store.running.contains(card.id)
                HStack(spacing: 10) {
                    RuntimeIcon(id: card.runtime, size: 16)
                    Text(card.title.isEmpty ? String(card.message.prefix(80)) : card.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Circle().fill(working ? Theme.warning : Theme.success).frame(width: 6, height: 6)
                    Text(working ? "Working" : "Done").font(Theme.meta)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                    Text(card.title.isEmpty ? card.id : card.title).font(Theme.meta).lineLimit(1)
                }
                .foregroundStyle(Theme.muted)
                .padding(.vertical, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A file the agent handed over. Images and text formats (Markdown, CSV,
/// HTML, code) preview in the card; a tap opens the in-app viewer, or Quick
/// Look for everything else.
struct ArtifactCard: View {
    let artifact: Artifact
    @Environment(RemoteStore.self) private var store
    @State private var preview: UIImage?
    @State private var local: URL?
    @State private var opening = false
    @State private var opened: URL?
    @State private var viewing = false
    @State private var failure: String?

    private static let previews = NSCache<NSString, UIImage>()
    /// Text previews download the whole file; past this the card stays an
    /// icon row (the Mac's uplink can be slow).
    private static let thumbnailLimit = 384 * 1024

    private var isImage: Bool { artifact.kind == "image" }
    private var format: ArtifactFormat { ArtifactFormat(artifact) }
    private var wantsThumbnail: Bool {
        format.isText && artifact.sizeBytes > 0 && artifact.sizeBytes <= Self.thumbnailLimit
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if isImage {
                    ZStack {
                        Theme.surface
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Theme.faint)
                        }
                    }
                    .frame(width: 280, height: 210)
                    .clipped()
                } else if wantsThumbnail {
                    Group {
                        if let local {
                            ArtifactThumbnail(artifact: artifact, format: format, url: local)
                        } else {
                            Theme.surface.frame(width: 280, height: ArtifactThumbnail.height)
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                HStack(spacing: 10) {
                    if !isImage && !wantsThumbnail {
                        Image(systemName: Self.symbol(artifact, format))
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 40, height: 40)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.caption ?? artifact.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(failure ?? meta)
                            .font(Theme.meta)
                            .foregroundStyle(failure == nil ? Theme.muted : Theme.danger)
                            .lineLimit(failure == nil ? 1 : 3)
                    }
                    Spacer(minLength: 0)
                    if opening { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: 280, alignment: .leading)
            .background(Theme.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(opening)
        .quickLookPreview($opened)
        .sheet(isPresented: $viewing) {
            ArtifactViewer(artifact: artifact, format: format)
        }
        .task(id: artifact.path) {
            #if DEBUG
            // `-demoOpenArtifact <name>` (with `-demoSnapshot`): open its viewer.
            if UserDefaults.standard.string(forKey: "demoOpenArtifact") == artifact.name { open() }
            #endif
            if wantsThumbnail {
                local = try? await ArtifactFiles.fetch(artifact, store: store)
                return
            }
            guard isImage, preview == nil else { return }
            if let hit = Self.previews.object(forKey: artifact.path as NSString) {
                preview = hit
                return
            }
            guard let data = try? await readPreview(), let image = UIImage(data: data) else { return }
            Self.previews.setObject(image, forKey: artifact.path as NSString)
            preview = image
        }
    }

    private var meta: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(artifact.sizeBytes), countStyle: .file)
        return (artifact.caption == nil ? "" : "\(artifact.name) · ") + "\(kindLabel) · \(size)"
    }

    private var kindLabel: String {
        switch format {
        case .table(let separator): separator == "," ? "CSV" : "TSV"
        case .code(let language?) where language == "json": "JSON"
        default: artifact.kindLabel
        }
    }

    private func readPreview() async throws -> Data {
        let reply = try await store.request("artifacts.read", ["path": .string(artifact.path), "preview": .bool(true)])
        guard let data = reply["data"].string.flatMap({ Data(base64Encoded: $0) }) else {
            throw RemoteError.server("The Mac sent no file.")
        }
        return data
    }

    private func open() {
        failure = nil
        if format.isText {
            viewing = true
            return
        }
        opening = true
        Task {
            defer { opening = false }
            do {
                opened = try await ArtifactFiles.fetch(artifact, store: store)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private static func symbol(_ artifact: Artifact, _ format: ArtifactFormat) -> String {
        switch format {
        case .table: return "tablecells"
        case .web: return "globe"
        case .markdown: return "doc.richtext"
        case .code(let language?) where language != "json": return "chevron.left.forwardslash.chevron.right"
        case .code: return "doc.text"
        case .native: break
        }
        switch artifact.kind {
        case "video": return "play.rectangle"
        case "audio": return "headphones"
        case "pdf": return "doc.text"
        default: return "doc"
        }
    }
}

extension SyntaxHighlighter {
    /// Code in the desktop's GitHub colors; plain when the language is unknown.
    static func attributed(_ code: String, language: String?) -> AttributedString {
        guard let language, knows(language) else { return AttributedString(code) }
        var out = AttributedString()
        for piece in pieces(code, language: language) {
            var run = AttributedString(piece.text)
            switch piece.kind {
            case .plain: break
            case .comment: run.foregroundColor = Theme.codeComment
            case .keyword: run.foregroundColor = Theme.codeKeyword
            case .literal: run.foregroundColor = Theme.codeLiteral
            case .string: run.foregroundColor = Theme.codeString
            case .title: run.foregroundColor = Theme.codeTitle
            }
            out += run
        }
        return out
    }
}
