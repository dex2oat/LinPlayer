import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        NavigationStack {
            List {
                Section("账户") {
                    if let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(AppTheme.brandColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.name)
                                    .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
                                if let server = serverManager.currentServer {
                                    Text(server.name)
                                        .font(.system(size: AppTheme.FontSize.caption))
                                        .foregroundColor(AppTheme.textSecondary)
                                }
                            }
                        }
                    }

                    Button(action: {
                        Task {
                            await authManager.logout()
                            serverManager.currentServer = nil
                        }
                    }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.red)
                            Text("退出登录")
                                .foregroundColor(.red)
                        }
                    }
                }

                Section("服务器") {
                    if let server = serverManager.currentServer {
                        HStack {
                            Text("当前服务器")
                            Spacer()
                            Text(server.name)
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        HStack {
                            Text("服务器地址")
                            Spacer()
                            Text(server.url)
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    }

                    Button("切换服务器") {
                        Task {
                            await authManager.logout()
                            serverManager.currentServer = nil
                        }
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    HStack {
                        Text("平台")
                        Spacer()
                        Text("Apple TV (tvOS)")
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
            }
            .background(AppTheme.background)
        }
    }
}
