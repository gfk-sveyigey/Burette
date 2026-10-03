import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var input = ""
    @State private var toast: String?
    @State private var showingConversations = false
    @FocusState private var isInputFocused: Bool

    private var navigationTitle: String {
        guard let repository = env.selectedRepository else { return "对话" }
        return env.currentConversation(for: repository)?.displayTitle ?? repository.name
    }

    var body: some View {
        Group {
            if let repository = env.selectedRepository {
                content(for: repository)
            } else {
                ContentUnavailableView(
                    "请先选择仓库",
                    systemImage: "square.stack.3d.up",
                    description: Text("点右上角切换仓库，或去「仓库」页添加。")
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingConversations = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel("对话列表")
            }
            ToolbarItem(placement: .topBarTrailing) {
                RepositoryMenuButton()
            }
        }
        .sheet(isPresented: $showingConversations) {
            if let repository = env.selectedRepository {
                ConversationListView(repository: repository)
            }
        }
        .task(id: env.selectedRepositoryID) {
            if let repository = env.selectedRepository {
                env.ensureConversation(for: repository)
            }
        }
        .onChange(of: env.applyNotice) { _, notice in
            guard let notice else { return }
            showToast(notice)
            env.applyNotice = nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for repository: Repository) -> some View {
        let messages = env.messages(for: repository)

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                // 用 GeometryReader 让内容至少撑满整个可视区域，
                // 这样点击最后一条消息下方的空白处也能收回键盘。
                GeometryReader { geo in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty && !env.isSending {
                                emptyState
                            }

                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            if env.isSending {
                                AgentRunView(status: env.agentStatus, steps: env.agentSteps, stream: env.agentStream, startedAt: env.agentStartedAt)
                                    .id(Self.thinkingID)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { isInputFocused = false }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // 进入页面时从最底部开始显示。原来只有 messages.count 变化才滚动，
                    // 进入时消息已经存在，不会触发任何滚动，于是停在顶部看不到最新消息。
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: env.selectedRepositoryID) { _, _ in
                        // 切换仓库后消息整体替换；两个仓库消息数相同时
                        // messages.count 不会变化，需要单独滚一次。
                        scrollToBottom(proxy, messages: messages)
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottom(proxy, messages: messages)
                    }
                    .onChange(of: env.isSending) { _, _ in
                        scrollToBottom(proxy, messages: messages)
                    }
                    .onChange(of: env.agentStatus) { _, _ in
                        if env.isSending { scrollToBottom(proxy, messages: messages) }
                    }
                }
            }

            inputBar(for: repository)
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.92), in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Burette Agent")
                .font(.headline)
            Text("描述你想怎么改。Agent 会先拿到文件树，再按需读取相关文件，并把改动自动应用到工作区，完成后通知你。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }

    private static let thinkingID = "agent-run-indicator"

    private func scrollToBottom(_ proxy: ScrollViewProxy, messages: [ChatMessage]) {
        withAnimation(.easeOut(duration: 0.2)) {
            if env.isSending {
                proxy.scrollTo(Self.thinkingID, anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !env.isSending
    }

    @ViewBuilder
    private func inputBar(for repository: Repository) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("描述你想怎么改…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .disabled(env.isSending)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .liquidGlass(cornerRadius: 20)

            if env.isSending {
                Button {
                    env.cancelSend()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(tint: .red, interactive: true)
                .accessibilityLabel("中断对话")
            } else {
                Button {
                    send(in: repository)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(tint: .accentColor, interactive: true)
                .opacity(canSend ? 1 : 0.5)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send(in repository: Repository) {
        let text = input
        input = ""
        isInputFocused = false
        env.send(text, in: repository)
    }
}

// MARK: - Repository switching

struct RepositoryMenuButton: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Menu {
            if env.repositories.isEmpty {
                Text("还没有仓库")
            } else {
                ForEach(env.repositories) { repository in
                    Button {
                        env.selectedRepositoryID = repository.id
                    } label: {
                        if repository.id == env.selectedRepositoryID {
                            Label(repository.fullName, systemImage: "checkmark")
                        } else {
                            Text(repository.fullName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .accessibilityLabel("切换仓库")
    }
}

// MARK: - 对话管理

struct ConversationListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(env.conversations(for: repository)) { conversation in
                    Button {
                        env.selectConversation(conversation, in: repository)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.displayTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(conversation.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if conversation.id == env.currentConversation(for: repository)?.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            beginRename(conversation)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            env.deleteConversation(conversation, in: repository)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .circularDeleteSwipe {
                        env.deleteConversation(conversation, in: repository)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        env.newConversation(in: repository)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建对话")
                }
            }
            .alert("重命名对话", isPresented: isRenaming, presenting: renaming) { conversation in
                TextField("名称", text: $renameText)
                Button("保存") {
                    env.renameConversation(conversation, in: repository, title: renameText)
                }
                Button("取消", role: .cancel) {}
            } message: { conversation in
                Text(conversation.displayTitle)
            }
        }
    }

    private func beginRename(_ conversation: Conversation) {
        renameText = conversation.title
        renaming = conversation
    }
}

// MARK: - Agent 运行状态

/// 对话进行中展示的 agent 执行卡片：像 Codex 一样列出正在做/已完成的每一步。
struct AgentRunView: View {
    let status: String?
    let steps: [String]
    let stream: String
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(elapsed: elapsed(at: context.date))
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }

    private struct Step: Identifiable {
        let id: Int
        let text: String
        let isCurrent: Bool
    }

    private var visibleSteps: [Step] {
        let total = steps.count
        return Array(steps.enumerated()).suffix(8).map {
            Step(id: $0.offset, text: $0.element, isCurrent: $0.offset == total - 1)
        }
    }

    private func card(elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Burette Agent")
                    .font(.caption.bold())
                Spacer()
                Text(DurationFormat.short(elapsed))
                    .font(.caption.monospacedDigit())
                ProgressView().controlSize(.mini)
            }
            .foregroundStyle(.secondary)

            if visibleSteps.isEmpty {
                Text(status ?? "准备中…")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleSteps) { item in
                        HStack(alignment: .center, spacing: 8) {
                            Group {
                                if item.isCurrent {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 16, alignment: .center)

                            Text(item.text)
                                .font(.footnote)
                                .foregroundStyle(item.isCurrent ? Color.primary : Color.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            // 模型实时输出（像 Codex 一样边生成边显示）。
            if !stream.isEmpty {
                Text(stream)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14)
    }
}

// MARK: - Bubbles

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !isUser {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("Burette Agent")
                }
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            }

            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .padding(12)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !isUser, message.duration != nil || (message.patches?.isEmpty == false) {
                HStack(spacing: 10) {
                    if let patches = message.patches, !patches.isEmpty {
                        applyBadge(count: patches.count)
                    }
                    if let duration = message.duration {
                        Label("用时 \(DurationFormat.short(duration))", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// 改动应用结果徽标：只有真正写入工作区才显示「已应用」。
    @ViewBuilder
    private func applyBadge(count: Int) -> some View {
        if let state = message.applyState {
            switch state {
            case .applied:
                Label("已应用 \(count) 个文件的改动", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .partial:
                Label("部分改动未能应用", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Label("改动未能应用", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Label("尚未应用", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private var bubbleBackground: Color {
        isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
    }
}
