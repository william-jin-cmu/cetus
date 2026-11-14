import CetusRemoteKit
import SwiftUI
import UIKit
import WebKit

// MARK: - Files

/// Artifacts fetched from the Mac, kept in the temp folder so the card's
/// preview and the full viewer share one download.
@MainActor
enum ArtifactFiles {
    private static var inFlight: [String: Task<URL, Error>] = [:]

    static func localURL(_ artifact: Artifact) -> URL {
        // One folder per file so two artifacts may share a name.
        FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts/\(stableHash(artifact.path))-\(artifact.sizeBytes)", isDirectory: true)
            .appendingPathComponent(artifact.name)
    }

    static func cached(_ artifact: Artifact) -> URL? {
        let url = localURL(artifact)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func fetch(_ artifact: Artifact, store: RemoteStore) async throws -> URL {
        if let url = cached(artifact) { return url }
        if let running = inFlight[artifact.path] { return try await running.value }
        let task = Task<URL, Error> {
            #if DEBUG
            // `-demoSnapshot` has no Mac to ask; the simulator can read the
            // Mac's disk directly.
            if UserDefaults.standard.string(forKey: "demoSnapshot") != nil {
                let url = localURL(artifact)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: artifact.path), to: url)
                return url
            }
            #endif
            let reply = try await store.request("artifacts.read", ["path": .string(artifact.path), "preview": .bool(false)])
            guard let data = reply["data"].string.flatMap({ Data(base64Encoded: $0) }) else {
                throw RemoteError.server("The Mac sent no file.")
            }
            let url = localURL(artifact)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }
        inFlight[artifact.path] = task
        defer { inFlight[artifact.path] = nil }
        return try await task.value
    }

    static func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// `hashValue` changes between launches; the cache folder must not.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }
}

/// Minified JSON spread over lines, key order kept.
private func prettyJSON(_ text: String) -> String { JSONIndent.format(text) }

/// Long files are cut so SwiftUI text layout stays quick.
private let textViewLimit = 400_000

private func clipText(_ text: String, limit: Int = textViewLimit) -> (String, Bool) {
    guard text.utf8.count > limit else { return (text, false) }
    var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
    while !text.isCharacterBoundary(end) { end = text.utf8.index(before: end) }
    return (String(text[..<end]), true)
}

private extension String {
    func isCharacterBoundary(_ i: String.Index) -> Bool { i.samePosition(in: self) != nil }
}

// MARK: - Viewer

/// A full-screen reader for an artifact the app can draw itself.
struct ArtifactViewer: View {
    let artifact: Artifact
    let format: ArtifactFormat
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var text: String?
    @State private var failure: String?
    @State private var showSource = false
    @State private var copied = false

    /// Formats with a rendered view and a source view.
    private var hasSource: Bool {
        switch format {
        case .markdown, .table, .web: true
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle(artifact.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if text != nil {
                            Button(action: copy) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityLabel("Copy")
                        }
                        if let url {
                            Menu {
                                if hasSource {
                                    Button {
                                        showSource.toggle()
                                    } label: {
                                        Label(showSource ? "Show Preview" : "Show Source",
                                              systemImage: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                                    }
                                }
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                        }
                    }
                }
        }
        .tint(Theme.text)
        .task {
            #if DEBUG
            showSource = UserDefaults.standard.bool(forKey: "demoArtifactSource")
            #endif
            await load()
        }
    }

    @ViewBuilder private var content: some View {
        if let failure {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Theme.faint)
                Text(failure).font(Theme.label).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(32)
        } else if let url, let text {
            switch (format, showSource) {
            case (.markdown, false):
                MarkdownDocument(text: text)
            case (.table(let separator), false):
                TableDocument(text: text, separator: separator)
            case (.web, false):
                WebDocument(url: url).ignoresSafeArea(edges: .bottom)
            case (.code(let language), _):
                CodeDocument(text: language == "json" || language == "jsonc" ? prettyJSON(text) : text, language: language)
            case (.web, true):
                CodeDocument(text: text, language: "html")
            default:
                CodeDocument(text: text, language: nil)
            }
        } else {
            ProgressView()
        }
    }

    private func load() async {
        do {
            let url = try await ArtifactFiles.fetch(artifact, store: store)
            let text = try ArtifactFiles.text(at: url)
            self.url = url
            self.text = text
        } catch {
            failure = error.localizedDescription
        }
    }

    private func copy() {
        guard let text else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// A note under a document that was cut short.
private struct TruncatedNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

private struct MarkdownDocument: View {
    let text: String

    var body: some View {
        let (shown, cut) = clipText(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(text: shown, headings: true)
                if cut { TruncatedNote(text: "The rest of this file is too long to show here. Share it to read all of it.") }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }
}

/// Source with line numbers; long lines scroll sideways instead of wrapping.
private struct CodeDocument: View {
    let text: String
    let language: String?

    var body: some View {
        let (shown, cut) = clipText(text)
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).count
        let font = Font.system(size: 12.5, design: .monospaced)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        Text((1...max(lines, 1)).map(String.init).joined(separator: "\n"))
                            .font(font)
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(3)
                        Text(SyntaxHighlighter.attributed(shown, language: language))
                            .font(font)
                            .foregroundStyle(Theme.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                if cut {
                    TruncatedNote(text: "Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(textViewLimit), countStyle: .file)).")
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

/// CSV / TSV as a grid: header pinned, row numbers, columns sized to their
/// content.
private struct TableDocument: View {
    let text: String
    let separator: Character
    private static let rowLimit = 3000

    var body: some View {
        let parsed = DelimitedText.parse(text, separator: separator, limit: Self.rowLimit + 1)
        let all = parsed.rows
        let header = all.first ?? []
        let body = Array(all.dropFirst().prefix(Self.rowLimit))
        let columns = max(all.map(\.count).max() ?? 0, 1)
        let widths = Self.widths(Array(all.prefix(300)), columns: columns)
        let numberWidth = CGFloat(String(body.count).count) * 8 + 20
        let more = all.count > Self.rowLimit || !parsed.complete

        if all.isEmpty {
            Text("This file is empty.").font(Theme.label).foregroundStyle(Theme.muted)
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(body.enumerated()), id: \.offset) { i, row in
                            TableRow(number: "\(i + 1)", numberWidth: numberWidth, cells: row, widths: widths, header: false)
                                .background(i % 2 == 1 ? Theme.surface.opacity(0.55) : Color.clear)
                        }
                        if more {
                            TruncatedNote(text: "Showing the first \(Self.rowLimit) rows.").padding(.horizontal, 12)
                        }
                    } header: {
                        TableRow(number: "", numberWidth: numberWidth, cells: header, widths: widths, header: true)
                            .background(Theme.raised)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(body.count)\(more ? "+" : "") rows · \(columns) columns")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 4)
            }
        }
    }

    static func widths(_ rows: [[String]], columns: Int) -> [CGFloat] {
        (0..<columns).map { c in
            let longest = rows.map { c < $0.count ? min($0[c].count, 36) : 0 }.max() ?? 0
            return min(max(CGFloat(longest) * 7.6 + 24, 64), 300)
        }
    }
}

private struct TableRow: View {
    let number: String
    let numberWidth: CGFloat
    let cells: [String]
    let widths: [CGFloat]
    let header: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.vertical, 8)
                .padding(.trailing, 4)
            ForEach(Array(widths.enumerated()), id: \.offset) { c, width in
                Text(c < cells.count ? cells[c] : "")
                    .font(.system(size: 13, weight: header ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(header ? 2 : 4)
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 0.5) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

/// An HTML page or SVG from the Mac. Links leave for Safari; the page may
/// read files next to it (its own CSS and images, if they came along).
private struct WebDocument: UIViewRepresentable {
    let url: URL
    var interactive = true
    var onLoad: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onLoad: onLoad) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isUserInteractionEnabled = interactive
        view.backgroundColor = .white
        view.scrollView.backgroundColor = .white
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoad: ((WKWebView) -> Void)?
        init(onLoad: ((WKWebView) -> Void)?) { self.onLoad = onLoad }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
        {
            if action.navigationType == .linkActivated, let target = action.request.url,
               let scheme = target.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme)
            {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoad?(webView)
        }
    }
}

// MARK: - Card previews

/// The top of a text artifact's card: the first lines, drawn the way the
/// viewer will draw them. Web pages render once and keep a snapshot.
struct ArtifactThumbnail: View {
    let artifact: Artifact
    let format: ArtifactFormat
    let url: URL

    @State private var text: String?
    @State private var snapshot: UIImage?

    static let height: CGFloat = 150
    private static let snapshots = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.surface
            switch format {
            case .web:
                webThumb
            case .markdown:
                if let text {
                    MarkdownText(text: String(text.prefix(1200)), headings: true)
                        .padding(12)
                        .scaleEffect(0.78, anchor: .topLeading)
                        .frame(width: 280 / 0.78, alignment: .topLeading)
                }
            case .table(let separator):
                if let text { tableThumb(text, separator: separator) }
            case .code(let language):
                if let text {
                    let source = language == "json" ? prettyJSON(text) : String(text.prefix(4000))
                    let head = source.split(separator: "\n", maxSplits: 14, omittingEmptySubsequences: false)
                        .prefix(14).joined(separator: "\n")
                    Text(SyntaxHighlighter.attributed(head, language: language))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize()
                        .padding(12)
                }
            case .native:
                EmptyView()
            }
        }
        .frame(width: 280, height: Self.height, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .bottom) {
            if format != .web {
                LinearGradient(colors: [Theme.surface.opacity(0), Theme.surface], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
            }
        }
        .task(id: url) {
            if format == .web {
                snapshot = Self.snapshots.object(forKey: url.path as NSString)
            } else if text == nil {
                text = try? ArtifactFiles.text(at: url)
            }
        }
    }

    @ViewBuilder private var webThumb: some View {
        if let snapshot {
            Image(uiImage: snapshot).resizable().scaledToFill()
                .frame(width: 280, height: Self.height, alignment: .top)
        } else {
            // Laid out at twice the card's size, then halved, like a page
            // seen from a distance.
            WebDocument(url: url, interactive: false) { web in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    let config = WKSnapshotConfiguration()
                    if let image = try? await web.takeSnapshot(configuration: config) {
                        Self.snapshots.setObject(image, forKey: url.path as NSString)
                        snapshot = image
                    }
                }
            }
            .frame(width: 560, height: Self.height * 2)
            .scaleEffect(0.5, anchor: .topLeading)
            .frame(width: 280, height: Self.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private func tableThumb(_ text: String, separator: Character) -> some View {
        let rows = DelimitedText.parse(String(text.prefix(8000)), separator: separator, limit: 8).rows
        let columns = min(rows.map(\.count).max() ?? 0, 6)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(c < row.count ? row[c] : "")
                            .font(.system(size: 10.5, weight: r == 0 ? .semibold : .regular))
                            .foregroundStyle(Theme.text.opacity(r == 0 ? 1 : 0.85))
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4.5)
                    }
                }
                .background(r == 0 ? Theme.raised : Color.clear)
                Rectangle().fill(Theme.border).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
            }
        }
        .fixedSize()
    }
}
