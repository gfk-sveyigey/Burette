import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var editing: AIProviderConfig?
    @State private var checking: UUID?
    @State private var checkResults: [UUID: String] = [:]
    @State private var showingAccountEditor = false

    var body: some View {
        List {
            Section("AI 配置") {
                ForEach(env.aiConfigs) { config in
                    configRow(config)
                        .contentShape(Rectangle())
                        .onTapGesture { env.selectedAIConfigID = config.id }
                        .contextMenu {
                            Button {
                                editing = config
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button {
                                env.selectedAIConfigID = config.id
                            } label: {
                                Label("设为当前", systemImage: "checkmark.circle")
                            }
                            Button {
                                Task { await check(config) }
                            } label: {
                                Label("检测可用性", systemImage: "bolt.horizontal.circle")
                            }
                        }
                        .circularDeleteSwipe { env.removeConfig(config) }
                }
            }

            Section("账户") {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.currentUser?.login ?? "已登录 GitHub")
                            .foregroundStyle(.primary)
                        Text(env.currentUser?.name ?? "管理当前登录的账户")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Button {
                    showingAccountEditor = true
                } label: {
                    Label("切换账户 / 修改信息", systemImage: "person.crop.circle")
                }

                Button("退出登录", role: .destructive) { env.signOut() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newConfig() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加配置")
            }
        }
        .sheet(item: $editing) { config in
            AIProviderEditorView(config: config)
        }
        .sheet(isPresented: $showingAccountEditor) {
            AccountEditorView()
        }
        .task { await env.refreshCurrentUser() }
    }

    @ViewBuilder
    private func configRow(_ config: AIProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(config.name)
                    .foregroundStyle(.primary)
                Spacer()
                if config.id == env.activeAIConfig?.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            Text("\(config.model) · \(config.baseURL)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if checking == config.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("检测中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let result = checkResults[config.id] {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(result.hasPrefix("可用") ? Color.green : Color.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = env.currentUser?.avatarUrl {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ProgressView()
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
        }
    }

    private func newConfig() {
        let id = UUID()
        editing = AIProviderConfig(
            id: id,
            name: "新配置",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKeyID: KeychainStore.apiKeyID(for: id)
        )
    }

    private func check(_ config: AIProviderConfig) async {
        checking = config.id
        checkResults[config.id] = nil
        let result = await env.checkAI(config)
        switch result {
        case .success:
            checkResults[config.id] = "可用"
        case .failure(let error):
            checkResults[config.id] = "不可用：\(error.localizedDescription)"
        }
        checking = nil
    }
}

struct AIProviderEditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AIProviderConfig
    @State private var apiKey = ""

    init(config: AIProviderConfig) {
        _draft = State(initialValue: config)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key（留空表示不修改）", text: $apiKey)
                TextField(
                    "补充说明（可选）",
                    text: Binding(
                        get: { draft.extraInstructions ?? "" },
                        set: { draft.extraInstructions = $0.isEmpty ? nil : $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...4)
            }
            .navigationTitle("AI 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.upsert(draft, apiKey: apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AccountEditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("新的 Personal Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("填入另一个账号的 token 即可切换账户；重新填入当前账号的 token 可更新信息。")
                }
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = token
                        isWorking = true
                        Task {
                            let ok = await env.updateAccount(token: value)
                            isWorking = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
        }
    }
}
