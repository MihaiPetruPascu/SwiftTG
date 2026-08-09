// ChatInfoView.swift

import SwiftUI
import TDLibKit

private enum PrivateCallPhase: Equatable {
    case requesting
    case ringing
    case connecting
    case ready([String])
    case ending
    case ended

    var title: String {
        switch self {
        case .requesting: "Starting call…"
        case .ringing: "Ringing…"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .ending: "Ending call…"
        case .ended: "Call ended"
        }
    }
}
// MARK: - ChatInfoView

struct ChatInfoView: View {
    // MARK: Internal

    var body: some View {
        List {
            identitySection(info)

            if let info {
                profileInformationSection(info)
                notificationsSection(info)
                memberDetailsSection(info)
                sharedContentSection(info)
                unofficialAppWarningSection(info)
                actionsSection(info)
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading chat information…")
                        Spacer()
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Chat Information Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Telegram didn't return information for this chat."),
                    )
                }
            }
        }
        .navigationTitle("Chat Info")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ChatInfoDestination.self) { destination in
            destinationView(destination)
        }
        .navigationDestination(isPresented: $showsCommonGroups) {
            if let userId = info?.commonGroupsUserId {
                ChatInfoCommonGroupsView(
                    userId: userId,
                    expectedCount: info?.commonGroupCount ?? 0,
                    service: chatVM.service,
                )
            }
        }
        .task(id: chat.id) { await loadInfo() }
        .sheet(isPresented: $showsSharedMedia) {
            SharedMediaView(
                chatId: chat.id,
                chatTitle: chat.displayTitle,
                service: chatVM.service,
            ) { messageId in
                openSharedMediaMessage(messageId)
            }
        }
        .fullScreenCover(isPresented: $showsCall) {
            PrivateCallView(
                title: chat.chat.title,
                photo: chat.chat.photo,
                phase: callPhase,
                isVideo: activeCallIsVideo,
                mediaSession: callMediaSession,
                onMuteChanged: { callMediaSession?.setMuted($0) },
                onSpeakerChanged: { callMediaSession?.setSpeakerEnabled($0) },
                onVideoChanged: {
                    activeCallIsVideo = $0
                    callMediaSession?.setVideoEnabled($0)
                },
                onSwitchCamera: { callMediaSession?.switchCamera() },
                onHangUp: endCall,
            )
        }
        .onReceive(chatVM.service.updatePublisher) { update in
            switch update {
            case .updateCall(let value):
                receiveCallUpdate(value.call)
            case .updateNewCallSignalingData(let value):
                guard value.callId == activeCallId else { return }
                if let callMediaSession {
                    callMediaSession.addSignalingData(value.data)
                } else {
                    pendingCallSignalingData.append(value.data)
                }
            default:
                break
            }
        }
        .sheet(isPresented: $showsScheduledMessages) {
            ScheduledMessagesView()
        }
        .popover(isPresented: $showMuteOptions) {
            TelegramMutePresetPopoverContent { duration in
                setMuteDuration(duration)
                showMuteOptions = false
            }
            .presentationCompactAdaptation(.popover)
        }
        .alert(
            "Delete \(chat.displayTitle)?",
            isPresented: $showDeleteConfirmation,
        ) {
            if chat.actionPolicy.canDeleteCommunity {
                Button("Delete for everyone", role: .destructive) {
                    deleteChat(forAll: true)
                }
            } else {
                if chat.chat.canBeDeletedOnlyForSelf {
                    Button("Delete only for me", role: .destructive) {
                        deleteChat(forAll: false)
                    }
                }
                if chat.chat.canBeDeletedForAllUsers {
                    Button("Delete for everyone", role: .destructive) {
                        deleteChat(forAll: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                showDeleteConfirmation = false
            }
        }
        .alert(
            "Chat Info Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                },
            ),
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Private

    @Environment(ChatVM.self) private var chatVM
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var info: TelegramChatInfoData?
    @State private var isLoading = true
    @State private var muteOverride: Bool?
    @State private var showDeleteConfirmation = false
    @State private var showMuteOptions = false
    @State private var showsCommonGroups = false
    @State private var showsScheduledMessages = false
    @State private var showsSharedMedia = false
    @State private var showsCall = false
    @State private var activeCallId: Int?
    @State private var activeCallUserId: Int64?
    @State private var activeCallIsVideo = false
    @State private var callPhase = PrivateCallPhase.requesting
    @State private var callConnectedAt: Foundation.Date?
    @State private var callMediaSession: PrivateCallMediaSession?
    @State private var pendingCallSignalingData = [Data]()

    private var chat: CustomChat { chatVM.customChat }

    private var status: String {
        !chatVM.actionStatus.isEmpty ? chatVM.actionStatus : chatVM.onlineStatus
    }

    private func identitySection(_ info: TelegramChatInfoData?) -> some View {
        Section {
            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    ProfileImageView(
                        photo: chat.chat.photo?.big,
                        minithumbnail: chat.chat.photo?.minithumbnail,
                        title: chat.displayTitle,
                        userId: chat.chat.id,
                        fontSize: 36,
                        isSavedMessages: chat.isSavedMessages,
                    )
                    .frame(width: 96, height: 96)

                    Text(chat.displayTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    let identityStatus = status.isEmpty ? chat.kind.title : status
                    Text(identityStatus)
                        .font(.subheadline)
                        .foregroundStyle(identityStatus == "online" ? .blue : .secondary)
                }
                .accessibilityElement(children: .combine)

                if let info {
                    if info.canBeCalled, let userId = info.callUserId {
                        HStack(spacing: 12) {
                            callButton(
                                title: "Audio Call",
                                systemImage: "phone.fill",
                                isVideo: false,
                                userId: userId,
                            )

                            if info.supportsVideoCalls {
                                callButton(
                                    title: "Video Call",
                                    systemImage: "video.fill",
                                    isVideo: true,
                                    userId: userId,
                                )
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if isMuted(info) {
                                setMuteDuration(0)
                            } else {
                                showMuteOptions = true
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: isMuted(info) ? "bell.slash.fill" : "bell.fill")
                                Text(isMuted(info) ? "Unmute" : "Mute")
                                    .font(.caption)
                            }
                            .frame(minWidth: 88, minHeight: 44)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            openConversationSearch()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                Text("Search")
                                    .font(.caption)
                            }
                            .frame(minWidth: 88, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func callButton(title: String, systemImage: String, isVideo: Bool, userId: Int64) -> some View {
        Button {
            beginCall(userId: userId, isVideo: isVideo)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption)
            }
            .frame(minWidth: 110, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(showsCall)
        .accessibilityLabel(title)
    }

    private func beginCall(userId: Int64, isVideo: Bool) {
        callMediaSession?.stop()
        callMediaSession = nil
        pendingCallSignalingData.removeAll()
        activeCallId = nil
        activeCallUserId = userId
        activeCallIsVideo = isVideo
        callConnectedAt = nil
        callPhase = .requesting
        showsCall = true
        ServiceSoundManager.shared.startOutgoingCallTone()

        Task {
            do {
                let result = try await chatVM.service.createCall(
                    isVideo: isVideo,
                    protocol: PrivateCallMediaSession.supportedProtocol,
                    userId: userId,
                )
                activeCallId = result.id
            } catch {
                showsCall = false
                clearCallState()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func receiveCallUpdate(_ call: Call) {
        guard showsCall,
              call.userId == activeCallUserId,
              activeCallId == nil || call.id == activeCallId
        else { return }

        activeCallId = call.id
        activeCallIsVideo = call.isVideo
        switch call.state {
        case .callStatePending:
            callPhase = .ringing
        case .callStateExchangingKeys:
            ServiceSoundManager.shared.stopOutgoingCallTone()
            callPhase = .connecting
        case .callStateReady(let ready):
            ServiceSoundManager.shared.stopOutgoingCallTone()
            if callMediaSession == nil {
                guard let mediaSession = PrivateCallMediaSession(call: call, ready: ready, service: chatVM.service) else {
                    showsCall = false
                    clearCallState()
                    errorMessage = "The call media engine couldn't negotiate a compatible Telegram protocol."
                    return
                }
                callMediaSession = mediaSession
                pendingCallSignalingData.forEach(mediaSession.addSignalingData)
                pendingCallSignalingData.removeAll()
            }
            if callConnectedAt == nil { callConnectedAt = Foundation.Date() }
            callPhase = .ready(ready.emojis)
        case .callStateHangingUp:
            ServiceSoundManager.shared.stopOutgoingCallTone()
            callPhase = .ending
        case .callStateDiscarded:
            ServiceSoundManager.shared.stopOutgoingCallTone()
            callPhase = .ended
            finishCallPresentation()
        case .callStateError(let value):
            ServiceSoundManager.shared.stopOutgoingCallTone()
            showsCall = false
            clearCallState()
            errorMessage = value.error.message
        }
    }

    private func endCall() {
        ServiceSoundManager.shared.stopOutgoingCallTone()
        guard let callId = activeCallId else {
            showsCall = false
            clearCallState()
            return
        }
        callPhase = .ending
        let duration = callConnectedAt.map { max(0, Int(Foundation.Date().timeIntervalSince($0))) } ?? 0
        Task {
            do {
                _ = try await chatVM.service.discardCall(
                    callId: callId,
                    connectionId: 0,
                    duration: duration,
                    inviteLink: "",
                    isDisconnected: false,
                    isVideo: activeCallIsVideo,
                )
            } catch {
                showsCall = false
                clearCallState()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishCallPresentation() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            showsCall = false
            clearCallState()
        }
    }

    private func clearCallState() {
        ServiceSoundManager.shared.stopOutgoingCallTone()
        callMediaSession?.stop()
        callMediaSession = nil
        pendingCallSignalingData.removeAll()
        activeCallId = nil
        activeCallUserId = nil
        callConnectedAt = nil
        callPhase = .requesting
    }

    private func notificationsSection(_ info: TelegramChatInfoData) -> some View {
        Section("Notifications") {
            Button {
                if isMuted(info) {
                    setMuteDuration(0)
                } else {
                    showMuteOptions = true
                }
            } label: {
                Text(isMuted(info) ? "Unmute" : "Mute")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TelegramChatSoundRow(service: chatVM.service, chatId: chat.id, settings: chat.notificationSettings)
        }
    }

    private func sharedContentSection(_ info: TelegramChatInfoData) -> some View {
        Section {
            Button {
                showsSharedMedia = true
            } label: {
                Label("Shared Media", systemImage: "photo.on.rectangle")
            }

            Button {
                showsScheduledMessages = true
            } label: {
                Label("Scheduled Messages", systemImage: "clock")
            }

            if let commonGroupCount = info.commonGroupCount,
               commonGroupCount > 0,
               info.commonGroupsUserId != nil
            {
                Button {
                    showsCommonGroups = true
                } label: {
                    LabeledContent("Groups in common", value: commonGroupCount.formatted())
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func profileInformationSection(_ info: TelegramChatInfoData) -> some View {
        if !info.usernames.isEmpty || info.phoneNumber != nil || info.birthdate != nil || info.about != nil {
            Section {
                if let phoneNumber = info.phoneNumber {
                    LabeledContent("Phone", value: phoneNumber)
                        .textSelection(.enabled)
                }

                if let username = info.usernames.first,
                   let url = URL(string: "https://t.me/\(username)")
                {
                    profileLinkRow(username: username, usernames: info.usernames, url: url)
                }

                if let birthdate = info.birthdate {
                    LabeledContent("Birthdate", value: birthdate)
                }

                if let about = info.about, !about.text.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profileInformationLabel(info))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(getAttributedString(from: about, .primary))
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func memberDetailsSection(_ info: TelegramChatInfoData) -> some View {
        if info.memberCount != nil
            || info.administratorCount != nil
            || info.restrictedCount != nil
            || info.bannedCount != nil
        {
            Section {
                if let memberCount = info.memberCount {
                    let title = chat.kind == .channel ? "Subscribers" : "Members"
                    if info.canBrowseMembers {
                        NavigationLink(value: ChatInfoDestination.members(.members)) {
                            LabeledContent(title, value: memberCount.formatted())
                        }
                    } else {
                        LabeledContent(title, value: memberCount.formatted())
                    }
                }

                if let administratorCount = info.administratorCount, administratorCount > 0 {
                    NavigationLink(value: ChatInfoDestination.members(.administrators)) {
                        LabeledContent("Administrators", value: administratorCount.formatted())
                    }
                }

                if let restrictedCount = info.restrictedCount, restrictedCount > 0 {
                    NavigationLink(value: ChatInfoDestination.members(.restricted)) {
                        LabeledContent("Restricted", value: restrictedCount.formatted())
                    }
                }

                if let bannedCount = info.bannedCount, bannedCount > 0 {
                    NavigationLink(value: ChatInfoDestination.members(.banned)) {
                        LabeledContent("Banned", value: bannedCount.formatted())
                    }
                }
            }
        }
    }

    @ViewBuilder private func unofficialAppWarningSection(_ info: TelegramChatInfoData) -> some View {
        if info.usesUnofficialApp {
            Section {
                Label(
                    "Telegram reports that this user uses an unofficial app that may pose a security risk.",
                    systemImage: "exclamationmark.triangle",
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private func profileLinkRow(
        username: String,
        usernames: [String],
        url: URL,
    ) -> some View {
        let isPublicChat = chat.kind == .group || chat.kind == .channel
        let title = isPublicChat ? url.absoluteString : "@\(username)"
        let subtitle = profileLinkSubtitle(usernames, isPublicChat: isPublicChat)
        let copyValue = isPublicChat ? url.absoluteString : "@\(username)"

        return Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: isPublicChat ? "link" : "at")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if copyValue != url.absoluteString {
                Button("Copy") { UIPasteboard.general.string = copyValue }
            }
            Button("Copy Link") { UIPasteboard.general.string = url.absoluteString }
        }
    }

    @ViewBuilder private func destinationView(_ destination: ChatInfoDestination) -> some View {
        switch destination {
        case .members(let filter):
            ChatInfoMembersView(
                chatId: chat.id,
                isChannel: chat.kind == .channel,
                filter: filter,
                service: chatVM.service,
            )
        }
    }

    @ViewBuilder private func actionsSection(_ info: TelegramChatInfoData) -> some View {
        let policy = chat.actionPolicy
        if info.blockableUserId != nil
            || policy.canLeave
            || policy.canClearHistory
            || policy.canDeleteChat
        {
            Section {
                if info.blockableUserId != nil {
                    Button(
                        blockActionTitle(info),
                        role: info.isBlocked ? nil : .destructive,
                    ) {
                        toggleBlocked()
                    }
                }

                if let leaveTitle = policy.leaveActionTitle {
                    Button(leaveTitle, role: .destructive) {
                        dismissThenRequest { RootVM.shared.requestLeave(chat) }
                    }
                }

                if policy.canClearHistory {
                    Button("Clear History", role: .destructive) {
                        dismissThenRequest { RootVM.shared.requestClearHistory(chat) }
                    }
                }

                if policy.canDeleteChat, policy.leaveActionTitle == nil {
                    Button(policy.deleteActionTitle, role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
    }

    private func isMuted(_ info: TelegramChatInfoData) -> Bool {
        if let muteOverride {
            return muteOverride
        }
        let settings = chat.notificationSettings
        return settings.useDefaultMuteFor ? info.defaultMuteFor > 0 : settings.muteFor > 0
    }

    private func setMuteDuration(_ duration: Int) {
        muteOverride = duration > 0
        RootVM.shared.setMuteDuration(duration, for: chat)
    }

    private func deleteChat(forAll: Bool) {
        RootVM.shared.deleteChat(chat, forAll: forAll)
        dismiss()
    }

    private func openSharedMediaMessage(_ messageId: Int64) {
        showsSharedMedia = false
        Task { @MainActor in
            await Task.yield()
            dismiss()
            await Task.yield()
            chatVM.navigateToMessage(id: messageId)
        }
    }

    private func openConversationSearch() {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            chatVM.beginConversationSearch()
        }
    }

    private func blockActionTitle(_ info: TelegramChatInfoData) -> String {
        if info.isBot {
            return info.isBlocked ? "Restart Bot" : "Stop Bot"
        }
        return info.isBlocked ? "Unblock User" : "Block User"
    }

    private func profileInformationLabel(_ info: TelegramChatInfoData) -> String {
        if info.isBot {
            return "Bot Info"
        }
        return chat.kind == .group || chat.kind == .channel ? "Description" : "Bio"
    }

    private func toggleBlocked() {
        guard let current = info, let userId = current.blockableUserId else { return }
        Task {
            do {
                let blocked = !current.isBlocked
                _ = try await chatVM.service.setMessageSenderBlockList(
                    blockList: blocked ? .blockListMain : nil,
                    senderId: .messageSenderUser(.init(userId: userId)),
                )
                guard !Task.isCancelled else { return }
                info?.isBlocked = blocked
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func profileLinkSubtitle(_ usernames: [String], isPublicChat: Bool) -> String {
        let label = isPublicChat ? "Link" : "Username"
        guard usernames.count > 1 else { return label }
        return "\(label). Also: \(usernames.dropFirst().map { "@\($0)" }.joined(separator: ", "))"
    }

    private func dismissThenRequest(_ request: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            request()
        }
    }

    private func loadInfo() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await TelegramChatInfoLoader(service: chatVM.service).load(chatId: chat.id)
            guard !Task.isCancelled else { return }
            info = loaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            info = nil
        }
    }

}

private struct PrivateCallView: View {
    let title: String
    let photo: ChatPhotoInfo?
    let phase: PrivateCallPhase
    let isVideo: Bool
    let mediaSession: PrivateCallMediaSession?
    let onMuteChanged: (Bool) -> Void
    let onSpeakerChanged: (Bool) -> Void
    let onVideoChanged: (Bool) -> Void
    let onSwitchCamera: () -> Void
    let onHangUp: () -> Void

    @State private var isMuted = false
    @State private var isSpeakerEnabled = true
    @State private var isCameraEnabled: Bool

    init(
        title: String,
        photo: ChatPhotoInfo?,
        phase: PrivateCallPhase,
        isVideo: Bool,
        mediaSession: PrivateCallMediaSession?,
        onMuteChanged: @escaping (Bool) -> Void,
        onSpeakerChanged: @escaping (Bool) -> Void,
        onVideoChanged: @escaping (Bool) -> Void,
        onSwitchCamera: @escaping () -> Void,
        onHangUp: @escaping () -> Void
    ) {
        self.title = title
        self.photo = photo
        self.phase = phase
        self.isVideo = isVideo
        self.mediaSession = mediaSession
        self.onMuteChanged = onMuteChanged
        self.onSpeakerChanged = onSpeakerChanged
        self.onVideoChanged = onVideoChanged
        self.onSwitchCamera = onSwitchCamera
        self.onHangUp = onHangUp
        _isCameraEnabled = State(initialValue: isVideo)
    }

    private var controlsEnabled: Bool {
        if case .ready = phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.85), .indigo, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            .ignoresSafeArea()

            if isVideo, let mediaSession, case .ready = phase {
                RemoteCallVideoView(mediaSession: mediaSession)
                    .ignoresSafeArea()
            }

            VStack(spacing: 22) {
                Spacer()

                if !isVideo || mediaSession == nil {
                    ProfileImageView(
                        photo: photo?.big,
                        minithumbnail: photo?.minithumbnail,
                        title: title,
                        userId: Int64(title.hashValue),
                        fontSize: 52,
                    )
                    .frame(width: 144, height: 144)
                    .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 3))
                    .shadow(radius: 24)
                }

                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                if case .ready(let emojis) = phase, !emojis.isEmpty {
                    CallVerificationEmojiView(emojis: emojis, peerName: title)
                } else {
                    Label(phase.title, systemImage: isVideo ? "video.fill" : "phone.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()
            }
            .padding()
        }
        .interactiveDismissDisabled()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 14) {
                cameraButton(size: 60)
                muteButton(size: 60)

                speakerButton(size: 60)

                if isCameraEnabled {
                    callControlButton(
                        title: "Flip",
                        systemImage: "camera.rotate.fill",
                        isSelected: false,
                        size: 60,
                        action: onSwitchCamera
                    )
                    .disabled(!controlsEnabled)
                }

                endCallButton(size: 60)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.black.opacity(0.22))
        }
    }

    private func callControlButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: size, height: size)
                    .foregroundStyle(isSelected ? .black : .white)
                    .background(isSelected ? .white : .white.opacity(0.18), in: Circle())
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: max(72, size))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func cameraButton(size: CGFloat) -> some View {
        callControlButton(
            title: "Camera",
            systemImage: isCameraEnabled ? "video.fill" : "video.slash.fill",
            isSelected: isCameraEnabled,
            size: size
        ) {
            isCameraEnabled.toggle()
            onVideoChanged(isCameraEnabled)
        }
        .disabled(!controlsEnabled)
    }

    private func muteButton(size: CGFloat) -> some View {
        callControlButton(
            title: "Mute",
            systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
            isSelected: isMuted,
            size: size
        ) {
            isMuted.toggle()
            onMuteChanged(isMuted)
        }
        .disabled(!controlsEnabled)
    }

    private func speakerButton(size: CGFloat) -> some View {
        callControlButton(
            title: "Speaker",
            systemImage: "speaker.wave.2.fill",
            isSelected: isSpeakerEnabled,
            size: size
        ) {
            isSpeakerEnabled.toggle()
            onSpeakerChanged(isSpeakerEnabled)
        }
        .disabled(!controlsEnabled)
    }

    private func endCallButton(size: CGFloat) -> some View {
        Button(action: onHangUp) {
            VStack(spacing: 8) {
                Image(systemName: "phone.down.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.red, in: Circle())
                Text("End")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(width: max(72, size))
        }
        .buttonStyle(.plain)
        .disabled(phase == .ending || phase == .ended)
        .accessibilityLabel("End Call")
    }
}

private func notificationScope(for type: ChatType) -> NotificationSettingsScope {
    switch type {
    case .chatTypePrivate, .chatTypeSecret:
        .notificationSettingsScopePrivateChats
    case .chatTypeBasicGroup:
        .notificationSettingsScopeGroupChats
    case .chatTypeSupergroup(let value):
        value.isChannel ? .notificationSettingsScopeChannelChats : .notificationSettingsScopeGroupChats
    }
}

private func chatInfoCanManageMembers(_ status: ChatMemberStatus) -> Bool {
    switch status {
    case .chatMemberStatusAdministrator, .chatMemberStatusCreator:
        true
    case .chatMemberStatusBanned, .chatMemberStatusLeft, .chatMemberStatusMember,
         .chatMemberStatusRestricted:
        false
    }
}

private func chatInfoCanRestrictMembers(_ status: ChatMemberStatus) -> Bool {
    switch status {
    case .chatMemberStatusCreator:
        true
    case .chatMemberStatusAdministrator(let value):
        value.rights.canRestrictMembers
    case .chatMemberStatusBanned, .chatMemberStatusLeft, .chatMemberStatusMember,
         .chatMemberStatusRestricted:
        false
    }
}

private func chatInfoIsAdministrator(_ status: ChatMemberStatus) -> Bool {
    switch status {
    case .chatMemberStatusAdministrator, .chatMemberStatusCreator:
        true
    case .chatMemberStatusBanned, .chatMemberStatusLeft, .chatMemberStatusMember,
         .chatMemberStatusRestricted:
        false
    }
}

private func chatInfoBirthdateDescription(_ birthdate: Birthdate) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let now = Date()
    var components = DateComponents()
    components.calendar = calendar
    components.day = birthdate.day
    components.month = birthdate.month
    components.year = birthdate.year == 0 ? 2000 : birthdate.year
    guard let date = components.date else { return "\(birthdate.day)/\(birthdate.month)" }

    var description = date.formatted(
        Date.FormatStyle()
            .month(.wide)
            .day()
            .year(birthdate.year == 0 ? .omitted : .defaultDigits),
    )
    if birthdate.year > 0 {
        let age = calendar.dateComponents([.year], from: date, to: now).year ?? 0
        if age >= 0 {
            description += ", \(age) years old"
        }
    }
    let today = calendar.dateComponents([.day, .month], from: now)
    if today.day == birthdate.day, today.month == birthdate.month {
        description += ", birthday today"
    }
    return description
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
