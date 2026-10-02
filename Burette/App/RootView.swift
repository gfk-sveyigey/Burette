import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if env.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .task {
            await env.bootstrap()
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { env.lastError != nil },
                set: { if !$0 { env.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) { env.lastError = nil }
        } message: {
            Text(env.lastError ?? "")
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TabView {
            NavigationStack { RepositoriesView() }
                .tabItem { Label("仓库", systemImage: "square.stack.3d.up") }

            NavigationStack { ChatView() }
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack { ChangesView() }
                .tabItem { Label("改动", systemImage: "arrow.triangle.branch") }

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .overlay {
            if let message = env.busyMessage {
                BusyOverlay(message: message)
            }
        }
    }
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.footnote)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
