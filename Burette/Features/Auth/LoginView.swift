import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var token = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "drop.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Burette")
                .font(.largeTitle.bold())

            Text("用 GitHub Personal Access Token 登录，开始用对话修改代码。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SecureField("ghp_...", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)

            Button {
                isWorking = true
                Task {
                    await env.signIn(token: token)
                    isWorking = false
                }
            } label: {
                Text(isWorking ? "验证中…" : "登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.isEmpty || isWorking)
            .padding(.horizontal, 32)

            Text("需要在 PAT 中勾选 repo 权限。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}
