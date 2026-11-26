import CetusRemoteKit
import SwiftUI

enum Route: Hashable {
    case chat(String)
    case newChat(folder: String?)
}

/// The home screen: chats grouped by folder, exactly like the Mac sidebar.
struct ConversationListView: View {
    @Environment(RemoteStore.self) private var store
    @State private var createdChat: ChatModel?
    @State private var path: [Route] = []
    @State private var pairing = false
    @State private var showUsage = false
    @State private var showSettings = false
    @State private var addingFolder = false
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String>?

    private static let previewCount = 7

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            // A List rather than a ScrollView for the native swipe actions.
            List {
                topActions.plainRow()
                Rectangle().fill(Theme.border).frame(height: 0.5).padding(.vertical, 8).plainRow()
                if store.showArchived {
                    archivedList
                } else {
                    sectionHeader.plainRow()
                    ForEach(store.groups) { group in
                        groupView(group)
                    }
                    if store.groups.isEmpty && store.hasLoadedList {
                        Text("No chats yet")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .plainRow()
                    }
                }
                Color.clear.frame(height: 24).plainRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollIndicators(.hidden)
            .refreshable { await store.refreshList() }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let id): ChatView(conversationId: id, initialModel: createdChat?.conversationId == id ? createdChat : nil)
                case .newChat(let folder):
                    NewChatView(initialFolder: folder) { chat in
                        guard path.last == .newChat(folder: folder) else { return }
                        store.activeChat = chat
                        createdChat = chat
                        path.removeLast()
                        path.append(.chat(chat.conversationId))
                    }
                }
            }
        }
        .tint(Theme.text)
        .onAppear {
            if path.isEmpty, let host = store.selectedHostId,
               let openChatId = UserDefaults.standard.string(forKey: "openChat.\(host)"),
               store.conversations.contains(where: { $0.id == openChatId }) {
                path = [.chat(openChatId)]
            }
        }
        .onChange(of: path) { _, routes in
            if let createdChat, routes.last != .chat(createdChat.conversationId) { self.createdChat = nil }
            guard let host = store.selectedHostId else { return }
            if case .chat(let id) = routes.last {
                UserDefaults.standard.set(id, forKey: "openChat.\(host)")
            } else {
                UserDefaults.standard.removeObject(forKey: "openChat.\(host)")
            }
        }
        #if DEBUG
        .onChange(of: store.conversations.isEmpty, initial: true) { _, empty in
            if !empty, path.isEmpty, let id = UserDefaults.standard.string(forKey: "openChat") {
                path.append(.chat(id))
            }
            if !empty, path.isEmpty, UserDefaults.standard.bool(forKey: "openNewChat") {
                path.append(.newChat(folder: nil))
            }
        }
        #endif
        .onChange(of: store.sidebar.collapsed) { _, now in
            if collapsed == nil { collapsed = now }
        }
        .sheet(isPresented: $pairing) { NavigationStack { PairView() } }
        .sheet(isPresented: $showUsage) { UsageView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $addingFolder) {
            AddFolderSheet { _ in addingFolder = false }
                .presentationDetents([.large])
        }
    }

    // MARK: Sections

    private var topActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            HostHeader(onPair: { pairing = true })
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ActionRow(title: "New chat", systemImage: "plus") {
                path.append(.newChat(folder: nil))
            }
            ActionRow(title: store.showArchived ? "Back to chats" : "Archived", systemImage: store.showArchived ? "arrow.uturn.backward" : "archivebox") {
                store.showArchived.toggle()
            }
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text("Folders")
                .font(Theme.meta)
                .foregroundStyle(Theme.muted)
            Spacer()
            Button {
                addingFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(store.state != .connected)
        }
        .padding(.leading, 8)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func groupView(_ group: ChatGroup) -> some View {
        let isCollapsed = (collapsed ?? store.sidebar.collapsed).contains(group.dir)
        let showAll = expanded.contains(group.dir)
        GroupHeader(group: group, collapsed: isCollapsed) {
            withAnimation(.snappy(duration: 0.2)) {
                var set = collapsed ?? store.sidebar.collapsed
                if !set.insert(group.dir).inserted { set.remove(group.dir) }
                collapsed = set
            }
        } onNew: {
            path.append(.newChat(folder: group.dir))
        }
        .padding(.top, 10)
        .plainRow()
        if !isCollapsed {
            let items = showAll ? group.items : Array(group.items.prefix(Self.previewCount))
            ForEach(items) { c in
                chatRow(c)
            }
            if group.items.count > Self.previewCount {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if showAll { expanded.remove(group.dir) } else { expanded.insert(group.dir) }
                    }
                } label: {
                    Text(showAll ? "Show less" : "Show \(group.items.count - Self.previewCount) more")
                        .font(Theme.label)
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 40)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .plainRow()
            }
            if group.items.isEmpty && !group.isPinned {
                Text("No chats")
                    .font(.subheadline)
                    .foregroundStyle(Theme.faint)
                    .padding(.leading, 40)
                    .frame(minHeight: 36)
                    .plainRow()
            }
        }
    }

    @ViewBuilder
    private var archivedList: some View {
        Text("Archived")
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .padding(.leading, 8)
            .padding(.vertical, 8)
            .plainRow()
        ForEach(store.conversations.filter(\.archived)) { c in
            chatRow(c, subtitle: store.folderName(c.workspaceDir))
        }
        if !store.conversations.contains(where: \.archived) && store.hasLoadedList {
            Text("No archived chats")
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .plainRow()
        }
    }

    private func chatRow(_ c: Conversation, subtitle: String? = nil) -> some View {
        // A Button, not a NavigationLink: a List would add a disclosure chevron.
        Button {
            path.append(.chat(c.id))
        } label: {
            ChatRow(conversation: c, running: store.running.contains(c.id), subtitle: subtitle)
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { archiveButton(c) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            archiveButton(c).tint(c.archived ? Theme.success : .indigo)
        }
        .plainRow()
    }

    private func archiveButton(_ c: Conversation) -> some View {
        Button(c.archived ? "Unarchive" : "Archive", systemImage: c.archived ? "tray.and.arrow.up" : "archivebox") {
            Task { try? await store.update(c.id, ["archived": .bool(!c.archived)]) }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            BarButton(label: "Add folder", systemImage: "folder.badge.plus") { addingFolder = true }
                .disabled(store.state != .connected)
            BarButton(label: "Usage", systemImage: "gauge.with.dots.needle.33percent") { showUsage = true }
            Menu {
                Section("Macs") {
                    ForEach(store.hosts) { host in
                        Button {
                            store.selectedHostId = host.sid
                        } label: {
                            if host.sid == store.selectedHostId {
                                Label(host.macName, systemImage: "checkmark")
                            } else {
                                Text(host.macName)
                            }
                        }
                    }
                }
                Button("Pair Another Mac…", systemImage: "qrcode.viewfinder") { pairing = true }
            } label: {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            BarButton(label: "Settings", systemImage: "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

// MARK: - Pieces

private extension View {
    /// A List row that looks like the old stacked layout: no inset, separator
    /// or highlight of its own.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
    }
}

/// Mac name with its connection state, at the top of the list.
private struct HostHeader: View {
    let onPair: () -> Void
    @Environment(RemoteStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.selectedHost?.macName ?? "Mac")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label)
                        .lineLimit(1)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            if case .failed = store.state {
                Button("Retry") { store.reconnect() }
            } else if store.state == .unpaired {
                Button("Pair", action: onPair)
            }
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }

    private var label: String {
        switch store.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed(let message): "Offline · \(message)"
        case .unpaired: "Not paired"
        default: "Offline"
        }
    }

    private var color: Color {
        switch store.state {
        case .connected: Theme.success
        case .connecting: .orange
        default: .red
        }
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24)
                Text(title)
                    .font(Theme.row)
                Spacer()
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct GroupHeader: View {
    let group: ChatGroup
    let collapsed: Bool
    let onToggle: () -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    if group.isPinned {
                        Image(systemName: "pin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 22, height: 22)
                    } else {
                        FolderAvatar(dir: group.dir, name: group.name, isDefault: group.isDefault)
                    }
                    Text(group.name)
                        .font(Theme.label.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !group.isPinned {
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, 8)
        .frame(minHeight: 40)
    }
}

struct ChatRow: View {
    let conversation: Conversation
    let running: Bool
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(running: running, unread: conversation.unread)
                .padding(.leading, 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(Theme.row.weight(conversation.unread ? .semibold : .regular))
                    .foregroundStyle(conversation.unread ? Theme.text : Theme.text.opacity(0.82))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            Text(conversation.updatedAt.shortAgo)
                .font(Theme.meta.monospacedDigit())
                .foregroundStyle(Theme.faint)
        }
        .padding(.trailing, 10)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// Rows highlight in a rounded rect while pressed, like the Mac list, and
/// settle back with a little give.
struct RowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surface : .clear)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Theme.spring, value: configuration.isPressed)
    }
}

private struct BarButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

extension Date {
    /// "now", "5m", "3h", "2d", then a short date.
    var shortAgo: String {
        let s = max(0, -timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
