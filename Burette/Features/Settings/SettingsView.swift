import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editing: AIProviderConfig?

    var body: some View {
        List {
            Section("AI 配置") {
                ForEach(env.aiConfigs) { config in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.name)
                            Text("\(config.model) · \(config.baseURL)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if config.id == env.activeAIConfig?.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { env.selectedAIConfigID = config.id }
                    .swipeActions {
                        Button("删除", role: .destructive) { env.removeConfig(config) }
                        Button("编辑") { editing = config }
                            .tint(.blue)
                    }
                }

                Button {
                    let id = UUID()
                    editing = AIProviderConfig(
                        id: id,
                        name: "新配置",
                        baseURL: "https://api.openai.com/v1",
                        model: "gpt-4o-mini",
                        apiKeyID: KeychainStore.apiKeyID(for: id)
                    )
                } label: {
                    Label("添加配置", systemImage: "plus")
                }
            }

            Section("账户") {
                Button("退出登录", role: .destructive) { env.signOut() }
            }
        }
        .navigationTitle("设置")
        .sheet(item: $editing) { config in
            AIProviderEditorView(config: config)
        }
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
