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
                            AgentRunView(status: env.agentStatus)
                                .id(Self.thinkingID)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { isInputFocused = false }
                }
                .scrollDismissesKeyboard(.interactively)
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
            Text("描述你想怎么改。Agent 会读取整个项目的文件、请求模型，并把改动自动应用到工作区，完成后通知你。")
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

/// 对话进行中展示的 agent 步骤卡片，让过程看起来像一次任务执行而不是单纯聊天。
struct AgentRunView: View {
    let status: String?

    private static let steps = ["整理仓库上下文", "请求 AI 模型", "解析改动"]

    private var currentStep: Int {
        guard let status else { return 0 }
        if status.contains("模型") { return 1 }
        if status.contains("解析") { return 2 }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Burette Agent")
                    .font(.caption.bold())
                Spacer()
                ProgressView().controlSize(.mini)
            }
            .foregroundStyle(.secondary)

            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    Group {
                        if index < currentStep {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                        } else if index == currentStep {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .font(.footnote)

                    Text(step)
                        .font(.footnote)
                        .foregroundStyle(index <= currentStep ? Color.primary : Color.secondary)
                }
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

            if !isUser, let patches = message.patches, !patches.isEmpty {
                Label("已自动应用 \(patches.count) 个文件的改动", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
    }
}
