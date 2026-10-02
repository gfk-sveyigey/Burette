import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var token = ""
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.accentColor.opacity(0.28), .clear, .accentColor.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)

                Text("Burette")
                    .font(.largeTitle.bold())

                Text("用 GitHub Personal Access Token 登录，开始用对话修改代码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("ghp_...", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .liquidGlass(cornerRadius: 14)

                Button {
                    isFocused = false
                    isWorking = true
                    Task {
                        await env.signIn(token: token)
                        isWorking = false
                    }
                } label: {
                    Text(isWorking ? "验证中…" : "登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlass(cornerRadius: 14, tint: .accentColor, interactive: true)
                .opacity(token.isEmpty || isWorking ? 0.5 : 1)
                .disabled(token.isEmpty || isWorking)

                Text("需要在 PAT 中勾选 repo 权限。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .liquidGlass(cornerRadius: 28)
            .padding(24)
        }
        .onTapGesture { isFocused = false }
    }
}
