// RootView.swift

import SwiftUI

struct RootView: View {
    // MARK: Internal

    var body: some View {
        ZStack {
            if rootVM.loggedIn {
                MainView()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TelegramLiveLocationBar()
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TelegramAudioPlayerBar()
                    }
            } else {
                LoginView()
            }
        }
        .overlay(alignment: .top) {
            if incomingCall.isPresented, incomingCallMinimized {
                Button {
                    incomingCallMinimized = false
                } label: {
                    Label("Return to call with \(incomingCall.callerName)", systemImage: "phone.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .shadow(radius: 6)
                }
                .padding(.top, 8)
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
                get: { incomingCall.isPresented && !incomingCallMinimized },
                set: { _ in }
            )
        ) {
            IncomingCallView(
                coordinator: incomingCall,
                onMinimize: { incomingCallMinimized = true }
            )
        }
        .onChange(of: incomingCall.isPresented) { _, isPresented in
            if !isPresented { incomingCallMinimized = false }
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
    @State private var incomingCallMinimized = false
}
