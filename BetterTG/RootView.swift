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
                    .overlay(alignment: .top) {
                        VStack(spacing: 8) {
                            if let unconfirmedSession = rootVM.unconfirmedSession,
                               RootVM.deviceSessionId(unconfirmedSession) != nil
                            {
                                TelegramUnconfirmedSessionBannerView(
                                    session: unconfirmedSession,
                                    isProcessing: rootVM.isProcessingUnconfirmedSession,
                                    onConfirm: { rootVM.confirmUnconfirmedSession() },
                                    onDeny: { rootVM.denyUnconfirmedSession() },
                                )
                            }
                            TelegramInAppNotificationBannerView()
                        }
                    }
                    .animation(.default, value: rootVM.inAppNotificationBanner)
                    .animation(.default, value: rootVM.unconfirmedSession)
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
        // Applies everywhere in the subtree - link taps in message text, chat bios, link
        // previews, etc. - so `t.me`/`telegram.me`/`tg:` links resolve in-app instead of always
        // bouncing to Safari. Anything else keeps the system's own default handling.
        .environment(\.openURL, OpenURLAction { url in
            guard TelegramDeepLink.isTelegramLink(url) else { return .systemAction }
            rootVM.handleDeepLink(url)
            return .handled
        })
        .alert(
            "Join Chat?",
            isPresented: Binding(
                get: { rootVM.pendingDeepLinkJoin != nil },
                set: { isPresented in
                    if !isPresented {
                        rootVM.pendingDeepLinkJoin = nil
                    }
                },
            ),
            presenting: rootVM.pendingDeepLinkJoin,
        ) { _ in
            Button("Join") { rootVM.confirmPendingDeepLinkJoin() }
            Button("Cancel", role: .cancel) { rootVM.pendingDeepLinkJoin = nil }
        } message: { pending in
            Text(
                "\(pending.info.title) · \(pending.info.memberCount) member\(pending.info.memberCount == 1 ? "" : "s")",
            )
        }
        .alert(
            "Link Error",
            isPresented: Binding(
                get: { rootVM.deepLinkErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        rootVM.deepLinkErrorMessage = nil
                    }
                },
            ),
        ) {
            Button("OK") {}
        } message: {
            Text(rootVM.deepLinkErrorMessage ?? "")
        }
        .alert(
            "Couldn't Complete Request",
            isPresented: Binding(
                get: { rootVM.unconfirmedSessionActionError != nil },
                set: { isPresented in
                    if !isPresented {
                        rootVM.unconfirmedSessionActionError = nil
                    }
                },
            ),
        ) {
            Button("OK") {}
        } message: {
            Text(rootVM.unconfirmedSessionActionError ?? "")
        }
        .alert(
            "Login Denied",
            isPresented: Binding(
                get: { rootVM.showsDeniedSessionNotice },
                set: { rootVM.showsDeniedSessionNotice = $0 },
            ),
        ) {
            Button("OK") {}
        } message: {
            Text("The session was terminated. If this wasn't you, consider changing your password in Two-Step Verification.")
        }
    }

    // MARK: Private

    @State private var rootVM = RootVM.shared
    @State private var incomingCall = IncomingCallCoordinator.shared
    @State private var incomingCallMinimized = false
}
