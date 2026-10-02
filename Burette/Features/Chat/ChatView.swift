import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var input = ""

    var body: some View {
        Group {
            if let repository = env.selectedRepository {
                content(for: repository)
            } else {
                ContentUnavailableView(
                    "请先选择仓库",
                    systemImage: "square.stack.3d.up",
                    description: Text("在「仓库」里添加并选中一个仓库。")
                )
            }
        }
        .navigationTitle("对话")
    }

    @ViewBuilder
    private func content(for repository: Repository) -> some View {
        let messages = env.messages(for: repository)

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("描述你想怎么改这个仓库，AI 会返回 unified diff 供你预览和应用。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        ForEach(messages) { message in
                            MessageBubble(message: message) { patches in
                                env.apply(patches: patches, in: repository)
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("描述你想怎么改…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let text = input
                    input = ""
                    Task { await env.send(text, in: repository) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || env.isSending
                )
            }
            .padding()
        }
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
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14))

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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
