// RootView.swift

import SwiftUI

struct RootView: View {
    // MARK: Internal

    var body: some View {
        ZStack {
            if rootVM.loggedIn {
                MainView()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TelegramAudioPlayerBar()
                    }
            } else {
                LoginView()
            }
        }
        .transition(.opacity)
        .task(id: rootVM.loggedIn) {
            guard rootVM.loggedIn else { return }
            await TelegramKeepMediaPolicy.applyStoredPolicy(service: TDLib.shared.service)
            await PushNotificationsManager.shared.requestAuthorization()
            await PermissionsManager.shared.requestPostLoginPermissions()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { incomingCall.isPresented },
                set: { _ in }
            )
        ) {
            IncomingCallView(coordinator: incomingCall)
        }
        .alert(
            "Call Error",
            isPresented: Binding(
                get: { incomingCall.errorMessage != nil },
                set: { if !$0 { incomingCall.errorMessage = nil } }
            )
        ) {
            Button("OK") { incomingCall.errorMessage = nil }
        } message: {
            Text(incomingCall.errorMessage ?? "")
        }
    }

    // MARK: Private

    @State private var rootVM = RootVM.shared
    @State private var incomingCall = IncomingCallCoordinator.shared
}
