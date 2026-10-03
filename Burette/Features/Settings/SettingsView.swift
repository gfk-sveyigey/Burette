import SwiftUI

enum AccountSheet: String, Identifiable {
    case switchAccount
    case editAccount

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var avatars = AvatarStore.shared

    @State private var editing: AIProviderConfig?
    @State private var checking: UUID?
    @State private var checkResults: [UUID: String] = [:]
    @State private var accountSheet: AccountSheet?
    @State private var showingSignOut = false

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

                if !env.tokenScopes.isEmpty && !env.tokenScopes.contains("repo") {
                    Label("缺少 repo 权限，可能无法推送", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    accountSheet = .switchAccount
                } label: {
                    accountLabel("切换账户", systemImage: "arrow.left.arrow.right.circle")
                }
                .buttonStyle(.plain)

                Button {
                    accountSheet = .editAccount
                } label: {
                    accountLabel("修改账户信息", systemImage: "pencil")
                }
                .buttonStyle(.plain)

                Button {
                    showingSignOut = true
                } label: {
                    accountLabel("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.plain)
            }

            Section {
                NavigationLink {
                    LogsView()
                } label: {
                    accountLabel("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("诊断")
            } footer: {
                Text(versionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
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
        .alert("确定要退出登录吗？", isPresented: $showingSignOut) {
            Button("退出登录", role: .destructive) { env.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后会清空本地已添加的仓库列表（工作区文件仍保留在沙盒里）。")
        }
    }

    /// 页面底部显示的版本号，形如 “Burette v0.0.9”。
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Burette v\(version ?? "1.0.0")"
    }

    /// 账户 / 诊断区统一用的行样式：图标固定宽度、文字与图标都用主色（浅色下为黑色）。
    private func accountLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22, alignment: .center)
            Text(title)
            Spacer()
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
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

    /// 模型 + 强度 + 地址的副标题。
    private func subtitle(for config: AIProviderConfig) -> String {
        var parts = [config.model]
        if let effort = config.reasoningEffort, let label = AIProviderConfig.strengthLabel(for: effort) {
            parts.append("强度 \(label)")
        }
        parts.append(config.baseURL)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func configRow(_ config: AIProviderConfig) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(config.name)
                    .foregroundStyle(.primary)
                Text(subtitle(for: config))
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

            Spacer(minLength: 8)

            // 选中标记相对整行垂直居中（不跟随第一行文字）。
            if config.id == env.activeAIConfig?.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = env.currentUser?.avatarUrl {
            Group {
                // 命中缓存就直接显示，未命中才显示加载指示。
                if let image = avatars.cachedImage(for: url) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            // 每次进入页面都在后台刷新一次，有变化才更新。
            .task(id: url) { await avatars.refresh(url: url) }
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

    /// 模型强度（reasoning_effort）绑定，可空表示「默认」。
    private var strengthBinding: Binding<String?> {
        Binding(
            get: { draft.reasoningEffort },
            set: { draft.reasoningEffort = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("接口") {
                    TextField("名称", text: $draft.name)
                    TextField("Base URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型名", text: $draft.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key（留空表示不修改）", text: $apiKey)
                }

                Section {
                    Picker("模型强度", selection: strengthBinding) {
                        ForEach(AIProviderConfig.strengthOptions) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                } footer: {
                    Text("强度对应接口的 reasoning_effort 参数；「默认」表示不发送，兼容不支持该参数的模型。")
                }

                Section("补充说明（可选）") {
                    TextField(
                        "追加给模型的仓库级约定",
                        text: Binding(
                            get: { draft.extraInstructions ?? "" },
                            set: { draft.extraInstructions = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
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
