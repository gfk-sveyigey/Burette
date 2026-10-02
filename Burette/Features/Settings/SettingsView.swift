import SwiftUI

enum AccountSheet: String, Identifiable {
    case switchAccount
    case editAccount

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var editing: AIProviderConfig?
    @State private var checking: UUID?
    @State private var checkResults: [UUID: String] = [:]
    @State private var accountSheet: AccountSheet?

    var body: some View {
        List {
            Section {
                if env.aiConfigs.isEmpty {
                    Text("还没有 AI 配置，点右上角的加号添加。")
                        .foregroundStyle(.secondary)
                }

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
            } header: {
                HStack {
                    Text("AI 配置")
                    Spacer()
                    Button {
                        newConfig()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("添加配置")
                }
            }

            Section("账户") {
                accountRow

                HStack {
                    Label("令牌权限", systemImage: "key.horizontal")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(env.tokenScopes.isEmpty ? "未知" : env.tokenScopes.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !env.tokenScopes.isEmpty && !env.tokenScopes.contains("repo") {
                    Label("缺少 repo 权限，可能无法推送", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    accountSheet = .switchAccount
                } label: {
                    Label("切换账户", systemImage: "person.crop.circle.badge.arrow.left")
                }

                Button {
                    accountSheet = .editAccount
                } label: {
                    Label("修改账户信息", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    env.signOut()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section("诊断") {
                NavigationLink {
                    LogsView()
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { config in
            AIProviderEditorView(config: config)
        }
        .sheet(item: $accountSheet) { sheet in
            switch sheet {
            case .switchAccount:
                SwitchAccountView()
            case .editAccount:
                EditAccountView()
            }
        }
        .task { await env.refreshCurrentUser() }
    }

    private var accountRow: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(env.currentUser?.login ?? "已登录 GitHub")
                    .foregroundStyle(.primary)
                Text(env.currentUser?.name ?? "GitHub 账户")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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
        Log.info("检测 AI 配置可用性：\(config.name)", .ai)
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

/// 切换到另一个 GitHub 账户。
struct SwitchAccountView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("另一个账号的 Personal Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("登录到另一个 GitHub 账号。切换成功后，当前账号的仓库列表会被清空。")
                }
            }
            .navigationTitle("切换账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("切换") {
                        let value = token
                        isWorking = true
                        Task {
                            let ok = await env.switchAccount(token: value)
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

/// 修改当前账户的登录凭据（同一账号）。
struct EditAccountView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("当前账户") {
                    LabeledContent("账号", value: env.currentUser?.login ?? "未知")
                    if let name = env.currentUser?.name {
                        LabeledContent("名称", value: name)
                    }
                }

                Section {
                    SecureField("当前账号的新 Personal Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("用于更新或续期当前账号的凭据，必须是同一账号的 token。要换成别的账号请使用「切换账户」。")
                }
            }
            .navigationTitle("修改账户信息")
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
                            let ok = await env.updateAccountToken(token: value)
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
