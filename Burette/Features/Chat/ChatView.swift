import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var input = ""
    @FocusState private var isInputFocused: Bool

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
        .navigationTitle(env.selectedRepository?.name ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RepositoryMenuButton()
            }
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
                            Text("描述你想怎么改，AI 会读取这个项目的文件并返回 unified diff 供你预览和应用。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                        }

                        ForEach(messages) { message in
                            MessageBubble(message: message) { patches in
                                env.apply(patches: patches, in: repository)
                            }
                            .id(message.id)
                        }

                        if env.isSending {
                            ThinkingBubble()
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
            }

            Divider()
            inputBar(for: repository)
        }
    }

    private static let thinkingID = "thinking-indicator"

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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .liquidGlass(cornerRadius: 20)

            Button {
                send(in: repository)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlassCapsule(tint: .accentColor, interactive: true)
            .opacity(canSend ? 1 : 0.5)
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func send(in repository: Repository) {
        let text = input
        input = ""
        isInputFocused = false
        Task { await env.send(text, in: repository) }
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

// MARK: - Bubbles

struct ThinkingBubble: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI 正在思考…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlass(cornerRadius: 14)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let onApply: ([FilePatch]) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .padding(12)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let patches = message.patches, !patches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(patches) { patch in
                        HStack(spacing: 6) {
                            Text(badge(patch.kind))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(badgeColor(patch.kind), in: RoundedRectangle(cornerRadius: 4))
                            Text(patch.path).font(.caption.monospaced())
                            Spacer()
                            Text("+\(patch.addedLineCount) -\(patch.removedLineCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("应用改动") { onApply(patches) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(10)
                .liquidGlass(cornerRadius: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
    }

    private func badge(_ kind: FilePatch.Kind) -> String {
        switch kind {
        case .added: return "A"
        case .deleted: return "D"
        case .modified: return "M"
        }
    }

    private func badgeColor(_ kind: FilePatch.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .orange
        }
    }
}
